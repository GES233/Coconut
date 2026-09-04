defmodule Coconut.Edit.History do
  @moduledoc """
  Undo/redo history: an Op tree with sparse checkpoints (design doc §12).

  The tree nodes are states; each node carries the **resolved write
  command** that produced it (§12.4 discipline 1 — records are
  post-resolution: lowered ops, post-mint patches, constructed tracks,
  full new values), so replaying a path is deterministic by construction.
  Execution lives in `Coconut.Edit.Command.execute/3`: live writes and
  replay share that single dispatch table (§12.4 discipline 3 — no
  replay-only implementation). `present` is maintained incrementally on
  writes (O(1), no refold); cursor jumps (undo/redo, `state_at/2`)
  re-materialize from the nearest checkpoint behind the target, folding
  at most `checkpoint_interval` edges.

  Traversal is by **global seq order** (Vim `g-`/`g+` semantics, §12.2):
  `undo/1` moves to the next-lower live seq, `redo/1` to the next-higher —
  the tree structure is not consulted for navigation, only for
  materialization. Undoing across a branch point therefore "teleports" to
  the other branch, and a full undo sweep visits every live state exactly
  once.

  Checkpoints: the root always has one; every `checkpoint_interval`-th node
  gets one at write time; a fork point gets one when a write branches off it
  (§12.3). Since parent seqs strictly decrease along any path, a checkpoint
  is always within `checkpoint_interval` tree edges above any node.

  Squash: when the edge count exceeds `max_edges`, the oldest states are
  dropped by seq window — the newest `max_edges` nodes are kept (a dense
  suffix), and each kept node whose parent fell out of the window (a
  *frontier* node) first receives a materialized checkpoint, so replay
  within the window stays self-sufficient. Age-based, branch-neutral
  (§12.3).

  Version pin: the pin is the cursor node id (§12.2). Write entries accept
  `:pin` in opts — a pin not equal to the current cursor is rejected with
  `{:error, {:stale_pin, _}}`, which is how the shell refuses writes
  lowered against a state the cursor has since left.

  `Workspace` itself stays a pure value with zero history-specific fields.
  """

  alias Coconut.Edit.{Command, Operation, Patch, Workspace}

  @default_checkpoint_interval 100
  @default_max_edges 5000

  @typedoc "Node identity: the node's creation seq (monotonically increasing)."
  @type node_id :: non_neg_integer()

  @typedoc "A tree node. `record`/`label` are nil on roots (initial and squashed)."
  @type tree_node :: %{
          parent: node_id | nil,
          record: Command.t() | nil,
          checkpoint: Workspace.t() | nil,
          label: String.t() | nil,
          timestamp: integer()
        }

  @type t :: %__MODULE__{
          nodes: %{node_id() => tree_node()},
          cursor: node_id(),
          seq: non_neg_integer(),
          base_seq: node_id(),
          present: Workspace.t(),
          checkpoint_interval: pos_integer(),
          max_edges: pos_integer()
        }

  defstruct nodes: %{},
            cursor: 0,
            seq: 0,
            base_seq: 0,
            present: nil,
            checkpoint_interval: @default_checkpoint_interval,
            max_edges: @default_max_edges

  @doc """
  Wrap an existing workspace as the root of a fresh history.

  Options (module constants by default; overridable mainly for tests):

  - `:checkpoint_interval` — a checkpoint every N edges (default #{@default_checkpoint_interval});
  - `:max_edges` — squash keeps the newest N nodes (default #{@default_max_edges}).
  """
  @spec new(Workspace.t(), keyword()) :: t()
  def new(%Workspace{} = ws, opts \\ []) do
    %__MODULE__{
      nodes: %{0 => %{parent: nil, record: nil, checkpoint: ws, label: nil, timestamp: now()}},
      cursor: 0,
      seq: 0,
      base_seq: 0,
      present: ws,
      checkpoint_interval: Keyword.get(opts, :checkpoint_interval, @default_checkpoint_interval),
      max_edges: Keyword.get(opts, :max_edges, @default_max_edges)
    }
  end

  @doc "The current state: `workspace` plus the cursor node id (the version pin, §12.2)."
  @spec current(t()) :: %{workspace: Workspace.t(), node_id: node_id()}
  def current(hist), do: %{workspace: hist.present, node_id: hist.cursor}

  @doc """
  The workspace at any live node (`{:error, {:unknown_node, _}}` for
  squashed-away or never-existing ids). Materializes from the nearest
  checkpoint behind the target.
  """
  @spec state_at(t(), node_id()) :: {:ok, Workspace.t()} | {:error, {:unknown_node, node_id()}}
  def state_at(%__MODULE__{} = hist, node_id) when is_integer(node_id) do
    if Map.has_key?(hist.nodes, node_id) do
      {:ok, materialize(hist, node_id)}
    else
      {:error, {:unknown_node, node_id}}
    end
  end

  # ---- Restore (the load endpoint of `Coconut.Pickle.History`) ----

  @doc """
  Rebuild a history from deserialized fields.

  `present` is not archived; it is re-derived here by folding from the
  nearest checkpoint at or behind `cursor` (the same `materialize/2` path as
  cursor jumps, so replay shares `Command.execute/3` with live writes,
  §12.4). Invariants re-checked: window ordering (`base_seq <= cursor <=
  seq`), dense node coverage of `base_seq..seq`, and a checkpoint on the
  window root (initial root or squash frontier, §12.3).
  """
  @spec restore(map()) :: {:ok, t()} | {:error, term()}
  def restore(attrs) when is_map(attrs) do
    with {:ok, hist} <- build_restored(attrs),
         :ok <- validate_window(hist) do
      # 窗口稠密性已复检，cursor 必在册；直接走 materialize（state_at 的
      # 契约要求 present 已就位，restore 期间尚未填充）。
      {:ok, %{hist | present: materialize(hist, hist.cursor)}}
    end
  end

  def restore(other), do: {:error, {:invalid_history_attrs, other}}

  defp build_restored(attrs) do
    with {:ok, nodes} <- fetch_field(attrs, :nodes),
         {:ok, cursor} <- fetch_field(attrs, :cursor),
         {:ok, seq} <- fetch_field(attrs, :seq),
         {:ok, base_seq} <- fetch_field(attrs, :base_seq),
         {:ok, interval} <- fetch_field(attrs, :checkpoint_interval),
         {:ok, max_edges} <- fetch_field(attrs, :max_edges),
         true <- is_map(nodes) and Enum.all?(nodes, fn {k, v} -> is_integer(k) and is_map(v) end),
         true <- Enum.all?([cursor, seq, base_seq], &(is_integer(&1) and &1 >= 0)),
         true <- is_integer(interval) and interval > 0,
         true <- is_integer(max_edges) and max_edges > 0 do
      {:ok,
       %__MODULE__{
         nodes: nodes,
         cursor: cursor,
         seq: seq,
         base_seq: base_seq,
         present: nil,
         checkpoint_interval: interval,
         max_edges: max_edges
       }}
    else
      _ -> {:error, {:invalid_history_attrs, attrs}}
    end
  end

  defp fetch_field(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_history_field, key}}
    end
  end

  defp validate_window(hist) do
    expected = MapSet.new(hist.base_seq..hist.seq)
    actual = MapSet.new(Map.keys(hist.nodes))

    cond do
      not (hist.base_seq <= hist.cursor and hist.cursor <= hist.seq) ->
        {:error, {:invalid_history_window, {hist.base_seq, hist.cursor, hist.seq}}}

      not MapSet.equal?(expected, actual) ->
        {:error, {:non_dense_history_window, {hist.base_seq, hist.seq}}}

      is_nil(Map.fetch!(hist.nodes, hist.base_seq).checkpoint) ->
        {:error, {:missing_root_checkpoint, hist.base_seq}}

      true ->
        :ok
    end
  end

  # ---- Write entries (each records one edge; §12.4) ----

  @doc """
  The composed gesture write path (§12.3): validate → lower to per-track
  batches → execute the batch command → record the edge → update present.
  Multi-track gestures (e.g. `DragNoteAcrossTracks`) commit as one edge.

  `expected_version` is the aggregate optimistic lock (`:current` or an
  integer; see `Workspace.apply_batches/3`). Options: `:pin`, `:config`
  (`Coconut.Edit.Operation.Config`).
  """
  @spec apply(t(), Operation.request(), :current | Tamale.version(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def apply(hist, %_mod{} = req, expected_version \\ :current, opts \\ []) do
    with :ok <- check_pin(hist, opts),
         :ok <- Operation.validate(req, hist.present),
         {:ok, batches} <-
           Operation.lower_batches(
             req,
             hist.present,
             Keyword.get(opts, :config, %Operation.Config{})
           ),
         {:ok, new_ws, command} <-
           Command.execute(
             hist.present,
             Command.batch(batches, label_of(req)),
             expected_version: resolve_expected(expected_version, hist)
           ) do
      {:ok, commit(hist, command, new_ws)}
    end
  end

  @doc """
  The command write path: execute a `Coconut.Edit.Command` and record the
  **resolved** command as one edge (§12.4). Patch mounts and structural /
  light field writes all go through here; `Command.execute/3` returning
  the resolved form is what keeps replay deterministic (post-mint patch
  ids, the constructed track). Options: `:pin`, `:expected_version`.
  """
  @spec run(t(), Command.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def run(hist, %Command{} = command, opts \\ []) do
    with :ok <- check_pin(hist, opts),
         {:ok, new_ws, resolved} <-
           Command.execute(hist.present, command, Keyword.drop(opts, [:pin])) do
      {:ok, commit(hist, resolved, new_ws)}
    end
  end

  @doc """
  Drain the graveyards as a `consume_dead` edge (§12.4 — clearing is a
  mutation, so it must be replayable). Returns `{dead, hist}`; an empty
  drain records no edge.
  """
  @spec take_dead_patches(t()) :: {[{Patch.t(), term()}], t()}
  def take_dead_patches(hist) do
    {:ok, new_ws, resolved} = Command.execute(hist.present, Command.consume_dead())

    case resolved.payload do
      [] -> {[], hist}
      dead -> {dead, commit(hist, resolved, new_ws)}
    end
  end

  # ---- Traversal (global seq order, §12.2) ----

  @doc "Move to the next-lower live seq (Vim `g-` semantics)."
  @spec undo(t()) :: {:ok, t()} | {:error, :nothing_to_undo}
  def undo(hist) do
    if hist.cursor > hist.base_seq do
      {:ok, move_cursor(hist, hist.cursor - 1)}
    else
      {:error, :nothing_to_undo}
    end
  end

  @doc "Move to the next-higher live seq (Vim `g+` semantics)."
  @spec redo(t()) :: {:ok, t()} | {:error, :nothing_to_redo}
  def redo(hist) do
    if hist.cursor < hist.seq do
      {:ok, move_cursor(hist, hist.cursor + 1)}
    else
      {:error, :nothing_to_redo}
    end
  end

  # ---- Internals ----

  defp move_cursor(hist, target), do: %{hist | cursor: target, present: materialize(hist, target)}

  defp check_pin(hist, opts) do
    case Keyword.get(opts, :pin) do
      nil -> :ok
      pin when pin == hist.cursor -> :ok
      stale -> {:error, {:stale_pin, pin: stale, current: hist.cursor}}
    end
  end

  defp resolve_expected(:current, hist), do: hist.present.edit_version
  defp resolve_expected(version, _hist) when is_integer(version), do: version

  defp label_of(%mod{}), do: mod |> Module.split() |> List.last()

  # Append one edge at the cursor and advance present. A write made while
  # the cursor is not at the tip forks the tree; the fork point receives a
  # checkpoint (§12.3) — free here, since the pre-write present *is* the
  # workspace at the fork.
  defp commit(hist, %Command{} = command, new_present) do
    new_seq = hist.seq + 1

    nodes =
      if hist.cursor != hist.seq do
        Map.update!(hist.nodes, hist.cursor, &Map.put_new(&1, :checkpoint, hist.present))
      else
        hist.nodes
      end

    checkpoint = if rem(new_seq, hist.checkpoint_interval) == 0, do: new_present

    node = %{
      parent: hist.cursor,
      record: command,
      checkpoint: checkpoint,
      label: command.label,
      timestamp: now()
    }

    %{
      hist
      | nodes: Map.put(nodes, new_seq, node),
        cursor: new_seq,
        seq: new_seq,
        present: new_present
    }
    |> squash()
  end

  # Age-based window squash (§12.3): keep the newest `max_edges` nodes (a
  # dense seq suffix); every kept node whose parent fell out of the window
  # first gets a materialized checkpoint, then the old nodes are dropped.
  defp squash(hist) do
    if hist.seq - hist.base_seq <= hist.max_edges do
      hist
    else
      new_base = hist.seq - hist.max_edges + 1

      nodes =
        Enum.reduce(new_base..hist.seq, hist.nodes, fn seq, acc ->
          fix_frontier(%{hist | nodes: acc}, seq, new_base)
        end)

      nodes = Map.drop(nodes, Enum.to_list(hist.base_seq..(new_base - 1)))
      %{hist | nodes: nodes, base_seq: new_base}
    end
  end

  # A kept node whose parent fell out of the window becomes a root of the
  # window: give it a materialized checkpoint first (§12.3).
  defp fix_frontier(hist, seq, new_base) do
    node = Map.fetch!(hist.nodes, seq)

    if is_nil(node.parent) or node.parent < new_base do
      ws = node.checkpoint || materialize(hist, seq)
      Map.put(hist.nodes, seq, %{node | parent: nil, record: nil, checkpoint: ws})
    else
      hist.nodes
    end
  end

  # The workspace at `target`: fold commands from the nearest checkpoint at
  # or behind it along the parent chain — the same `Command.execute/3` as
  # live writes, so replay needs no implementation of its own (§12.4).
  defp materialize(hist, target) do
    path = path_to_root(hist.nodes, target, [])

    checkpoint_index =
      path
      |> Enum.with_index()
      |> Enum.reduce(0, fn {{_seq, node}, index}, latest ->
        if is_nil(node.checkpoint), do: latest, else: index
      end)

    {_seq, checkpoint_node} = Enum.at(path, checkpoint_index)

    path
    |> Enum.drop(checkpoint_index + 1)
    |> Enum.reduce(checkpoint_node.checkpoint, fn {_seq, node}, ws ->
      {:ok, new_ws, _resolved} = Command.execute(ws, node.record)
      new_ws
    end)
  end

  defp path_to_root(nodes, seq, acc) do
    node = Map.fetch!(nodes, seq)
    acc = [{seq, node} | acc]
    if is_nil(node.parent), do: acc, else: path_to_root(nodes, node.parent, acc)
  end

  defp now, do: System.system_time(:second)
end
