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

  alias Coconut.Track
  alias Coconut.Util.ID
  alias Tamale.Op.{Delete, Insert, Merge, Move, Retime, Split}

  # Shared geometry/sequence checks (with the per-gesture structs).
  import Coconut.Operations.CoreComponents

  # ---- Config ----

  defmodule Config do
    @moduledoc """
    Knobs that influence lowering behaviour.
    """
    defstruct ripple: false

    @type t :: %__MODULE__{
            ripple: boolean()
          }
  end

  # ---- Request ----

  @typedoc "Track identity within a workspace."
  @type track_id :: ID.t(Coconut.Track.t())

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
  | edit_note   | — (no op)             | id → re-cast element |

  `old_span` in `drag_note` is the span captured by the caller at drag-start;
  Retime needs both ends to keep the op log self-contained for warp construction.

  For `:tempo` inserts, `attrs.bpm` is a plain bpm number (floats allowed),
  normalized to exact milli-bpm by the tempo track module's `cast_element/3`
  (the single rounding point). Element casting in general is the track
  module's business; Operate only shapes ops and span entries.
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
    Removes land before write-time transport; additions are minted at the
    post-batch head and join after it, untransported by their own batch.
  """
  @type side_changes :: %{
          elements: %{Tamale.id() => map() | :delete},
          span_snapshot: %{Tamale.id() => span() | :delete},
          patches_add: [Coconut.Patch.t()],
          patches_remove: [term()]
        }

  # ---- Public API ----

  @doc """
  Validate a request against the current workspace state.

  Checks: track exists, ids are live, span bounds are correct, merge ids are
  adjacent, etc. Returns `:ok` or `{:error, reason}`.
  """
  @spec validate(request(), Coconut.Workspace.t()) :: :ok | {:error, term()}
  # Element casting (Note for vocal, bpm normalization for tempo) and
  # track-type-specific legality (e.g. tempo's first-element protection)
  # live on the track module — Operate owns only generic geometry and
  # sequence checks.
  def validate({:insert_note, track_id, id, after_id, {start_t, end_t}, attrs}, ws) do
    with {:ok, track} <- track_context(ws, track_id),
         :ok <- id_fresh?(track.space, id),
         :ok <- after_valid?(track.space, after_id),
         :ok <- note_span_valid?(start_t, end_t),
         {:ok, _element} <- track.module.cast_element(id, {start_t, end_t}, attrs),
         :ok <- track.module.validate_gesture(:insert, track, %{id: id, span: {start_t, end_t}}) do
      :ok
    end
  end

  def validate({:delete_note, track_id, id}, ws) do
    with {:ok, track} <- track_context(ws, track_id),
         :ok <- id_live?(track, id),
         :ok <- id_in_space?(track.space, id),
         :ok <- track.module.validate_gesture(:delete, track, %{id: id}) do
      :ok
    end
  end

  def validate({:move_note, track_id, id, new_after}, ws) do
    with {:ok, track} <- track_context(ws, track_id),
         :ok <- id_live?(track, id),
         :ok <- id_in_space?(track.space, id),
         :ok <- after_valid?(track.space, new_after),
         :ok <- not_self?(id, new_after) do
      :ok
    end
  end

  def validate({:drag_note, track_id, id, new_after, _old_span, {new_s, new_e}}, ws) do
    with {:ok, track} <- track_context(ws, track_id),
         :ok <- id_live?(track, id),
         :ok <- id_in_space?(track.space, id),
         :ok <- after_valid?(track.space, new_after),
         :ok <- not_self?(id, new_after),
         :ok <- note_span_valid?(new_s, new_e) do
      :ok
    end
  end

  def validate({:split_note, track_id, id, at_tick, new_id}, ws) do
    with {:ok, track} <- track_context(ws, track_id),
         :ok <- id_live?(track, id),
         :ok <- id_in_space?(track.space, id),
         :ok <- id_fresh?(track.space, new_id),
         :ok <- within_span?(ws, track_id, id, at_tick) do
      :ok
    end
  end

  def validate({:merge_notes, track_id, ids}, ws) do
    with {:ok, track} <- track_context(ws, track_id),
         [_ | _] = ids,
         :ok <- all_live?(track, ids),
         :ok <- all_in_space?(track.space, ids),
         :ok <- adjacent?(track.space, ids) do
      :ok
    end
  end

  def validate({:edit_note, track_id, id, changes}, ws) do
    with {:ok, track} <- track_context(ws, track_id),
         :ok <- id_live?(track, id),
         {:ok, _element} <-
           track.module.edit_element(Map.fetch!(track.elements_by_id, id), changes) do
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
  def lower({:insert_note, track_id, id, after_id, span, attrs}, ws, _cfg) do
    # The track module casts the element (Note for vocal, milli-bpm map
    # for tempo); Operate only shapes the op and the span entry.
    with {:ok, track} <- track_context(ws, track_id),
         {:ok, element} <- track.module.cast_element(id, span, attrs) do
      ops = [%Insert{id: id, after_id: after_id}]

      changes = %{
        empty_side_changes()
        | elements: %{id => element},
          span_snapshot: %{id => span}
      }

      {:ok, ops, changes}
    end
  end

  def lower({:delete_note, _track, id}, _ws, _cfg) do
    ops = [%Delete{id: id}]

    changes = %{
      empty_side_changes()
      | elements: %{id => :delete},
        span_snapshot: %{id => :delete}
    }

    {:ok, ops, changes}
  end

  def lower({:move_note, _track, id, new_after}, _ws, _cfg) do
    ops = [%Move{id: id, after_id: new_after}]
    # Move only changes order — span_snapshot & elements are identity.
    {:ok, ops, empty_side_changes()}
  end

  def lower({:drag_note, _track, id, new_after, old_span, new_span}, _ws, _cfg) do
    ops = [
      %Move{id: id, after_id: new_after},
      %Retime{id: id, old_span: old_span, new_span: new_span}
    ]

    changes = %{
      empty_side_changes()
      | span_snapshot: %{id => new_span}
    }

    {:ok, ops, changes}
  end

  def lower({:split_note, track_id, id, at_tick, new_id}, ws, _cfg) do
    ops = [%Split{id: id, children: [id, new_id]}]

    # Split reads the old span from track state — this is NOT the same
    # as back-reading for Retime. Split is identity-shaped (no warp), so
    # the span cut is pure geometry, not a warp ingredient.
    with {:ok, track} <- track_context(ws, track_id) do
      case Track.latest_span(track, id) do
        {s, e} when s < at_tick and at_tick < e ->
          # The right half's payload policy belongs to the track module
          # (vocal inherits the parent's content; lyric/tuning after a
          # split is the caller's business, see :edit_note).
          parent = Map.get(track.elements_by_id, id)

          changes = %{
            empty_side_changes()
            | elements: %{new_id => track.module.split_inherit(parent, new_id)},
              span_snapshot: %{id => {s, at_tick}, new_id => {at_tick, e}}
          }

          {:ok, ops, changes}

        _ ->
          {:error, :unreachable}
      end
    end
  end

  def lower({:merge_notes, track_id, ids}, ws, _cfg) do
    [into | rest] = ids
    ops = [%Merge{ids: ids, into: into}]

    with {:ok, track} <- track_context(ws, track_id) do
      spans = Enum.map(ids, &Track.latest_span(track, &1))

      if Enum.any?(spans, &is_nil/1) do
        {:error, :unreachable}
      else
        # Composite span runs from the earliest start to the latest end.
        # `into` keeps its own element payload — merging content (lyrics
        # etc.) is domain policy, see `Coconut.Score.Note.merge/6`.
        {starts, ends} = Enum.unzip(spans)
        deletable = Map.new(rest, &{&1, :delete})

        changes = %{
          empty_side_changes()
          | elements: deletable,
            span_snapshot: Map.put(deletable, into, {Enum.min(starts), Enum.max(ends)})
        }

        {:ok, ops, changes}
      end
    end
  end

  def lower({:edit_note, track_id, id, changes}, ws, _cfg) do
    # Content edits produce no ops: the track module merges the changes
    # onto the current element and re-casts it, and the result is written
    # back via the elements side table. Patch/digest semantics around the
    # edit (base_digest refresh) remain the caller's business.
    with {:ok, track} <- track_context(ws, track_id),
         {:ok, element} <- fetch_element(track, id),
         {:ok, new_element} <- track.module.edit_element(element, changes) do
      side = %{empty_side_changes() | elements: %{id => new_element}}
      {:ok, [], side}
    end
  end
end
