defmodule Coconut.Operate do
  @moduledoc """
  Lowering layer: translates edit requests into Tamale op batches and side-table
  change instructions.

  Design contract:

  - `validate/2` checks legality against current workspace state (pure, read-only).
  - `lower/3` produces `{:ok, ops, side_changes}` for a *validated* request.
  - Caller captures `old_span` at drag-start and passes it in — Retime stays
    self-contained; lowering never back-reads `spans_by_version` for warp
    ingredients. Split/Merge do read the latest span snapshot, but only for
    pure geometry — both are identity-shaped ops with no warp.
  - lowering does NOT apply anything; `Workspace.apply_batch/2` is the writer.
  """

  alias Coconut.Score.Tempo
  alias Tamale.Op.{Delete, Insert, Merge, Move, Retime, Split}

  # ---- Config ----

  defmodule Config do
    @moduledoc """
    Knobs that influence lowering behaviour.
    """
    defstruct ripple: false, tpqn: 480

    @type t :: %__MODULE__{
            ripple: boolean(),
            tpqn: pos_integer()
          }
  end

  # ---- Request ----

  @typedoc "Track identity within a workspace."
  @type track_id :: term()

  @typedoc "A tick span `{start, end}`. Both are non-negative integers, `end > start`."
  @type span :: {non_neg_integer(), non_neg_integer()}

  @typedoc """
  Edit request — a tagged tuple carrying a track key and operation-specific data.

  | gesture     | ops produced          | span_snapshot touched |
  |-------------|-----------------------|-----------------------|
  | insert_note | Insert                | new id → span        |
  | delete_note | Delete                | id → :delete         |
  | move_note   | Move                  | — (order only)       |
  | drag_note   | Move + Retime (同批)  | id → new_span        |
  | split_note  | Split                 | parent→left, new→right|
  | merge_notes | Merge                 | into→merged, rest→del|
  | edit_note   | — (no op)             | via patches_add      |

  `old_span` in `drag_note` is the span captured by the caller at drag-start;
  Retime needs both ends to keep the op log self-contained for warp construction.

  For `:tempo` inserts, `attrs.bpm` is a plain bpm number (floats allowed) and
  is normalized to exact milli-bpm during lowering (`Coconut.Score.Tempo.cast_bpm/1`).
  """
  @type request ::
          {:insert_note, track_id, Tamale.id(), Tamale.id() | :head, span(), attrs :: map()}
          | {:delete_note, track_id, Tamale.id()}
          | {:move_note, track_id, Tamale.id(), Tamale.id() | :head}
          | {:drag_note, track_id, Tamale.id(), Tamale.id() | :head, old_span :: span(),
             new_span :: span()}
          | {:split_note, track_id, Tamale.id(), at_tick :: non_neg_integer(),
             new_id :: Tamale.id()}
          | {:merge_notes, track_id, ids :: [Tamale.id(), ...]}
          | {:edit_note, track_id, Tamale.id(), changes :: map()}

  # ---- Side changes ----

  @typedoc """
  Instructions for the apply layer — what to write into the side tables
  after the op batch is committed.

  - `elements`: upsert element data (`map()`) or tombstone (`:delete`).
  - `span_snapshot`: the new version's span table entries for affected ids.
  - `patches_add` / `patches_remove`: patch lifecycle from content edits.
  """
  @type side_changes :: %{
          elements: %{Tamale.id() => map() | :delete},
          span_snapshot: %{Tamale.id() => span() | :delete},
          patches_add: [Coconut.Patch.t()],
          patches_remove: [term()]
        }

  @empty_side_changes %{
    elements: %{},
    span_snapshot: %{},
    patches_add: [],
    patches_remove: []
  }

  # ---- Public API ----

  @doc """
  Validate a request against the current workspace state.

  Checks: track exists, ids are live, span bounds are correct, merge ids are
  adjacent, etc. Returns `:ok` or `{:error, reason}`.
  """
  @spec validate(request(), Coconut.Workspace.t()) :: :ok | {:error, term()}
  # Tempo inserts additionally require a castable bpm (normalized at lower time).
  def validate({:insert_note, :tempo, id, after_id, {start_t, end_t}, attrs}, ws) do
    with {:ok, _milli_bpm} <- Tempo.cast_bpm(Map.get(attrs, :bpm)),
         {:ok, space, _side} <- track_context(ws, :tempo),
         :ok <- id_fresh?(space, id),
         :ok <- after_valid?(space, after_id),
         :ok <- span_valid?(start_t, end_t) do
      :ok
    end
  end

  def validate({:insert_note, track, id, after_id, {start_t, end_t}, _attrs}, ws) do
    with {:ok, space, _side} <- track_context(ws, track),
         :ok <- id_fresh?(space, id),
         :ok <- after_valid?(space, after_id),
         :ok <- span_valid?(start_t, end_t) do
      :ok
    end
  end

  def validate({:delete_note, :tempo, id}, ws) do
    with {:ok, space, side} <- track_context(ws, :tempo),
         :ok <- id_live?(side, id),
         :ok <- id_in_space?(space, id),
         :ok <- not_first?(space, id) do
      :ok
    end
  end

  def validate({:delete_note, track, id}, ws) do
    with {:ok, space, side} <- track_context(ws, track),
         :ok <- id_live?(side, id),
         :ok <- id_in_space?(space, id) do
      :ok
    end
  end

  def validate({:move_note, track, id, new_after}, ws) do
    with {:ok, space, side} <- track_context(ws, track),
         :ok <- id_live?(side, id),
         :ok <- id_in_space?(space, id),
         :ok <- after_valid?(space, new_after),
         :ok <- not_self?(id, new_after) do
      :ok
    end
  end

  def validate({:drag_note, track, id, new_after, _old_span, {new_s, new_e}}, ws) do
    with {:ok, space, side} <- track_context(ws, track),
         :ok <- id_live?(side, id),
         :ok <- id_in_space?(space, id),
         :ok <- after_valid?(space, new_after),
         :ok <- not_self?(id, new_after),
         :ok <- span_valid?(new_s, new_e) do
      :ok
    end
  end

  def validate({:split_note, track, id, at_tick, new_id}, ws) do
    with {:ok, space, side} <- track_context(ws, track),
         :ok <- id_live?(side, id),
         :ok <- id_in_space?(space, id),
         :ok <- id_fresh?(space, new_id),
         :ok <- within_span?(ws, track, id, at_tick) do
      :ok
    end
  end

  def validate({:merge_notes, track, ids}, ws) do
    with {:ok, space, side} <- track_context(ws, track),
         [_ | _] = ids,
         :ok <- all_live?(side, ids),
         :ok <- all_in_space?(space, ids),
         :ok <- adjacent?(space, ids) do
      :ok
    end
  end

  def validate({:edit_note, track, id, _changes}, ws) do
    with {:ok, _space, side} <- track_context(ws, track),
         :ok <- id_live?(side, id) do
      :ok
    end
  end

  @doc """
  Lower a *validated* request into ops + side_changes.

  Reads `spans_by_version` only for Split/Merge geometry — both are
  identity-shaped ops with no warp, so this never feeds warp construction.
  `Retime` stays self-contained: all its span data comes from the request
  itself. Returns `{:error, :unreachable}` for requests that should have
  been caught by `validate/2`.
  """
  @spec lower(request(), Coconut.Workspace.t(), Config.t()) ::
          {:ok, [Tamale.Op.t()], side_changes()} | {:error, term()}
  def lower({:insert_note, :tempo, id, after_id, span, attrs}, _ws, _cfg) do
    # bpm enters as a plain number and is stored as exact milli-bpm.
    with {:ok, milli_bpm} <- Tempo.cast_bpm(Map.get(attrs, :bpm)) do
      ops = [%Insert{id: id, after_id: after_id}]

      changes = %{
        @empty_side_changes
        | elements: %{id => Map.put(attrs, :bpm, milli_bpm)},
          span_snapshot: %{id => span}
      }

      {:ok, ops, changes}
    end
  end

  def lower({:insert_note, _track, id, after_id, span, attrs}, _ws, _cfg) do
    ops = [%Insert{id: id, after_id: after_id}]

    changes = %{
      @empty_side_changes
      | elements: %{id => attrs},
        span_snapshot: %{id => span}
    }

    {:ok, ops, changes}
  end

  def lower({:delete_note, _track, id}, _ws, _cfg) do
    ops = [%Delete{id: id}]

    changes = %{
      @empty_side_changes
      | elements: %{id => :delete},
        span_snapshot: %{id => :delete}
    }

    {:ok, ops, changes}
  end

  def lower({:move_note, _track, id, new_after}, _ws, _cfg) do
    ops = [%Move{id: id, after_id: new_after}]
    # Move only changes order — span_snapshot & elements are identity.
    {:ok, ops, @empty_side_changes}
  end

  def lower({:drag_note, _track, id, new_after, old_span, new_span}, _ws, _cfg) do
    ops = [
      %Move{id: id, after_id: new_after},
      %Retime{id: id, old_span: old_span, new_span: new_span}
    ]

    changes = %{
      @empty_side_changes
      | span_snapshot: %{id => new_span}
    }

    {:ok, ops, changes}
  end

  def lower({:split_note, track, id, at_tick, new_id}, ws, _cfg) do
    ops = [%Split{id: id, children: [id, new_id]}]

    # Split reads the old span from workspace state — this is NOT the same
    # as back-reading for Retime. Split is identity-shaped (no warp), so
    # the span cut is pure geometry, not a warp ingredient.
    case Coconut.Workspace.latest_span(ws, track, id) do
      {s, e} when s < at_tick and at_tick < e ->
        # The right half inherits the parent's payload; lyric/tuning policy
        # after a split is the caller's business (see :edit_note).
        changes = %{
          @empty_side_changes
          | elements: %{new_id => Map.get(ws.side.elements_by_id, id, %{})},
            span_snapshot: %{id => {s, at_tick}, new_id => {at_tick, e}}
        }

        {:ok, ops, changes}

      _ ->
        {:error, :unreachable}
    end
  end

  def lower({:merge_notes, track, ids}, ws, _cfg) do
    [into | rest] = ids
    ops = [%Merge{ids: ids, into: into}]

    spans = Enum.map(ids, &Coconut.Workspace.latest_span(ws, track, &1))

    if Enum.any?(spans, &is_nil/1) do
      {:error, :unreachable}
    else
      # Composite span runs from the earliest start to the latest end.
      # `into` keeps its own element payload — merging content (lyrics
      # etc.) is domain policy, see `Coconut.Score.Note.merge/4`.
      {starts, ends} = Enum.unzip(spans)
      deletable = Map.new(rest, &{&1, :delete})

      changes = %{
        @empty_side_changes
        | elements: deletable,
          span_snapshot: Map.put(deletable, into, {Enum.min(starts), Enum.max(ends)})
      }

      {:ok, ops, changes}
    end
  end

  def lower({:edit_note, _track, id, _changes}, _ws, _cfg) do
    # Content edits do not produce ops. The caller is responsible for
    # building a Patch with the correct base_digest and adding it via
    # patches_add. We return an empty stub; the real patch construction
    # is domain-specific (digest slices, etc.).
    changes = %{
      @empty_side_changes
      | elements: %{id => :touch}
    }

    {:ok, [], changes}
  end

  # ---- Helpers ----

  defp track_context(ws, :tempo) do
    case ws.tempo_space do
      nil -> {:error, :no_tempo_track}
      space -> {:ok, space, ws.side}
    end
  end

  defp track_context(ws, track_id) do
    case Map.fetch(ws.tracks, track_id) do
      {:ok, space} -> {:ok, space, ws.side}
      :error -> {:error, {:unknown_track, track_id}}
    end
  end

  defp id_fresh?(space, id) do
    if id in space.ids or MapSet.member?(space.seen, id) do
      {:error, {:id_conflict, id}}
    else
      :ok
    end
  end

  defp id_live?(side, id) do
    if Map.has_key?(side.elements_by_id, id) do
      :ok
    else
      {:error, {:unknown_id, id}}
    end
  end

  defp id_in_space?(space, id) do
    if id in space.ids do
      :ok
    else
      {:error, {:id_not_in_space, id}}
    end
  end

  defp after_valid?(_space, :head), do: :ok

  defp after_valid?(space, after_id) do
    if after_id in space.ids do
      :ok
    else
      {:error, {:unknown_after_id, after_id}}
    end
  end

  defp not_self?(id, id), do: {:error, {:self_referential, id}}
  defp not_self?(_id, _after), do: :ok

  defp not_first?(space, id) do
    if space.ids == [] or hd(space.ids) != id do
      :ok
    else
      {:error, {:tempo_first_protected, id}}
    end
  end

  defp span_valid?(start_t, end_t)
       when is_integer(start_t) and is_integer(end_t) and
              start_t >= 0 and end_t > start_t,
       do: :ok

  defp span_valid?(start_t, end_t),
    do: {:error, {:invalid_span, {start_t, end_t}}}

  defp within_span?(ws, track, id, at_tick) do
    # Split is the only validate that back-reads span data, and only for the
    # Split identity case (no warp involved).
    case Coconut.Workspace.latest_span(ws, track, id) do
      {s, e} when at_tick > s and at_tick < e -> :ok
      {s, e} -> {:error, {:split_out_of_bounds, {s, e, at_tick}}}
      nil -> {:error, {:no_span_for_id, id}}
    end
  end

  defp all_live?(side, ids) do
    Enum.find_value(ids, :ok, fn id ->
      case id_live?(side, id) do
        :ok -> nil
        err -> err
      end
    end)
  end

  defp all_in_space?(space, ids) do
    Enum.find_value(ids, :ok, fn id ->
      case id_in_space?(space, id) do
        :ok -> nil
        err -> err
      end
    end)
  end

  defp adjacent?(space, ids) do
    # ids must appear consecutively in space.ids in the same order.
    idxs =
      ids
      |> Enum.map(&Enum.find_index(space.ids, fn x -> x == &1 end))

    if Enum.any?(idxs, &is_nil/1) do
      {:error, {:ids_not_in_space, ids}}
    else
      consecutive? =
        idxs |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> b == a + 1 end)

      if consecutive?, do: :ok, else: {:error, {:ids_not_adjacent, ids}}
    end
  end
end
