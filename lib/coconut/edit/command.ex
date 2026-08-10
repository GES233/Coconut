defmodule Coconut.Edit.Command do
  @moduledoc """
  A resolved workspace write, in recordable form (design doc §12.4).

  A command is the *only* write record `Coconut.Edit.History` understands:
  write entries lower user-level input to a command, `execute/3` performs
  it against a workspace and returns the **resolved** command (post-mint,
  post-construction), and replay folds stored commands back through the
  same `execute/3` — live writes and replay share this single dispatch
  table (§12.4 discipline 3, no replay-only implementation).

  `payload` shape per `op`:

  - `:batch` — `{track_id, ops, side_changes}` (the output of
    `Coconut.Edit.Operation.lower/3`; normally produced via
    `Coconut.Edit.History.apply/4`, not built by hand);
  - `:attach_patches` — `[Patch.t()]`; execution mints patch ids, so the
    resolved command can differ from the input one;
  - `:add_track` — a fully constructed `Coconut.Edit.Track.t()`;
  - `:remove_track` — `track_id`;
  - `:rename_track` — `{track_id, name}`;
  - `:set_time_sigs` — `[time_sig_event]`;
  - `:consume_dead` — execution drains the graveyards and fills the
    payload with the drained `{patch, reason}` tuples (replay re-drains,
    ignoring the stored payload).
  """

  alias Coconut.Edit.{Operation, Patch, Track, Workspace}
  alias Coconut.Util.ID

  @type op ::
          :batch
          | :attach_patches
          | :add_track
          | :remove_track
          | :rename_track
          | :set_time_sigs
          | :consume_dead

  @typedoc """
  A workspace write record. `label` is the display annotation History
  stores on the tree node; `payload` is post-resolution by the time a
  command reaches the tree (see `execute/3`).
  """
  @type t :: %__MODULE__{
          op: op(),
          payload: term(),
          label: String.t()
        }

  defstruct [:op, :payload, label: "Edit"]

  # ---- Constructors ----

  @doc "An op batch lowered from an edit gesture (`Operation.lower/3` output)."
  @spec batch(Track.track_id(), [Tamale.Op.t()], Operation.side_changes(), String.t()) :: t()
  def batch(track_id, ops, side_changes, label),
    do: %__MODULE__{op: :batch, payload: {track_id, ops, side_changes}, label: label}

  @doc "Mount a list of patches; ids are minted at execution (see `execute/3`)."
  @spec attach_patches([Patch.t()]) :: t()
  def attach_patches(patches) when is_list(patches),
    do: %__MODULE__{op: :attach_patches, payload: patches, label: "AttachPatches"}

  @doc """
  Build an add-track command from `Track.new/1` attrs; `:id` is minted
  when absent. The constructed track rides in the payload, so replay
  never re-mints (§12.4 discipline 1).
  """
  @spec add_track(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def add_track(attrs) do
    attrs = attrs |> Map.new() |> Map.put_new_lazy(:id, fn -> ID.generate_id("Track_") end)

    case Track.new(attrs) do
      {:ok, track} -> {:ok, %__MODULE__{op: :add_track, payload: track, label: "AddTrack"}}
      {:error, _} = err -> err
    end
  end

  @doc "Remove a track by id (a structural edge)."
  @spec remove_track(Track.track_id()) :: t()
  def remove_track(track_id),
    do: %__MODULE__{op: :remove_track, payload: track_id, label: "RemoveTrack"}

  @doc "Rename a track (a light field edge; `name` is an annotation, §11.8)."
  @spec rename_track(Track.track_id(), String.t() | nil) :: t()
  def rename_track(track_id, name),
    do: %__MODULE__{op: :rename_track, payload: {track_id, name}, label: "RenameTrack"}

  @doc "Replace the time signature events (a light field edge, §6)."
  @spec set_time_sigs([Coconut.Score.TimeSig.time_sig_event()]) :: t()
  def set_time_sigs(events),
    do: %__MODULE__{op: :set_time_sigs, payload: events, label: "SetTimeSigs"}

  @doc "Drain the patch graveyards; the resolved payload carries the drained tuples."
  @spec consume_dead() :: t()
  def consume_dead, do: %__MODULE__{op: :consume_dead, payload: [], label: "ConsumeDead"}

  # ---- Execution ----

  @doc """
  Execute a command against a workspace.

  Returns `{:ok, new_workspace, resolved}` where `resolved` is the
  recordable form — identical to the input for every op except
  `:attach_patches` (patch ids minted) and `:consume_dead` (payload
  filled with the drained tuples).

  Options: `:expected_version` — the aggregate optimistic lock for
  `:batch`, defaulting to the workspace's own version (replay is
  sequential, so the lock always sees the current version, §12.4).
  """
  @spec execute(Workspace.t(), t(), keyword()) ::
          {:ok, Workspace.t(), t()} | {:error, term()}
  def execute(ws, command, opts \\ [])

  def execute(ws, %__MODULE__{op: :batch, payload: {track_id, ops, changes}} = command, opts) do
    expected = Keyword.get(opts, :expected_version, ws.edit_version)
    run(command, fn -> Workspace.apply_batch(ws, track_id, expected, ops, changes) end)
  end

  def execute(ws, %__MODULE__{op: :attach_patches, payload: patches} = command, _opts) do
    case Workspace.attach_patches(ws, patches) do
      {:ok, new_ws, minted} -> {:ok, new_ws, %{command | payload: minted}}
      {:error, _} = err -> err
    end
  end

  def execute(ws, %__MODULE__{op: :add_track, payload: %Track{} = track} = command, _opts),
    do: run(command, fn -> Workspace.add_track(ws, track) end)

  def execute(ws, %__MODULE__{op: :remove_track, payload: track_id} = command, _opts),
    do: run(command, fn -> Workspace.remove_track(ws, track_id) end)

  def execute(ws, %__MODULE__{op: :rename_track, payload: {track_id, name}} = command, _opts),
    do: run(command, fn -> Workspace.rename_track(ws, track_id, name) end)

  def execute(ws, %__MODULE__{op: :set_time_sigs, payload: events} = command, _opts),
    do: run(command, fn -> Workspace.set_time_sigs(ws, events) end)

  def execute(ws, %__MODULE__{op: :consume_dead} = command, _opts) do
    {dead, new_ws} = Workspace.take_dead_patches(ws)
    {:ok, new_ws, %{command | payload: dead}}
  end

  defp run(command, fun) do
    case fun.() do
      {:ok, new_ws} -> {:ok, new_ws, command}
      {:error, _} = err -> err
    end
  end
end
