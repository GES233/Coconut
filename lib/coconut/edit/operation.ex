defmodule Coconut.Edit.Operation do
  @moduledoc """
  Lowering layer: translates edit requests into Tamale op batches and side-table
  change instructions.

  A request is one of the per-gesture structs under `Coconut.Edit.Operations.*`
  (e.g. `Coconut.Edit.Operations.InsertNote`). This module defines the behaviour
  they implement and dispatches `validate/2` / `lower/3` to them.

  Design contract:

  - `validate/2` checks legality against current workspace state (pure, read-only).
  - `lower/3` produces `{:ok, ops, side_changes}` for a *validated* request.
  - Caller captures `old_span` at drag-start and passes it in — Retime stays
    self-contained; lowering never back-reads `spans_by_version` for warp
    ingredients. Split/Merge do read the latest span snapshot, but only for
    pure geometry — both are identity-shaped ops with no warp.
  - lowering does NOT apply anything; `Workspace.apply_batch/2` is the writer.
  """

  alias Coconut.Edit.Operations.{
    DeleteNote,
    DragNote,
    DragNoteAcrossTracks,
    EditNote,
    InsertNote,
    MergeNotes,
    MoveNote,
    SplitNote,
    TrimNote
  }

  alias Coconut.Edit.Workspace
  alias Coconut.Util.ID

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
  @type track_id :: ID.t(Coconut.Edit.Track.t())

  @typedoc "A span `{start, end}` in the track's coordinate domain (ticks for score tracks, frames for audio). Both are non-negative integers, `end > start`."
  @type span :: {non_neg_integer(), non_neg_integer()}

  @typedoc """
  Edit request — a per-gesture struct carrying a track key and operation-specific data.

  | gesture     | module                         | ops produced          | span_snapshot touched |
  |-------------|--------------------------------|-----------------------|-----------------------|
  | insert_note | `Edit.Operations.InsertNote`        | Insert                | new id → span        |
  | delete_note | `Edit.Operations.DeleteNote`        | Delete                | id → :delete         |
  | move_note   | `Edit.Operations.MoveNote`          | Move                  | — (order only)       |
  | drag_note   | `Edit.Operations.DragNote`          | Move + Retime (同批)  | id → new_span        |
  | split_note  | `Edit.Operations.SplitNote`         | Split                 | parent→left, new→right|
  | merge_notes | `Edit.Operations.MergeNotes`        | Merge                 | into→merged, rest→del|
  | edit_note   | `Edit.Operations.EditNote`          | — (no op)             | id → re-cast element |
  | trim_note   | `Edit.Operations.TrimNote`          | Retime                | id → new_span        |
  | drag_note_across_tracks | `Edit.Operations.DragNoteAcrossTracks` | 源轨 Delete + 目标轨 Insert（双轨同批） | 源 id → :delete,新 id → span |

  多数手势是单轨的：`lower/3` 产出一组 ops + side_changes，经
  `lower_batches/3` 包装为单元素批次列表。跨轨手势（目前仅
  `DragNoteAcrossTracks`）不实现 `lower/3`，改为实现可选回调
  `lower_batches/3`，直接产出多条按轨批次（design doc §8 跨 Space
  重挂：新 id + patch 不迁移）。

  `old_span` in `DragNote`/`TrimNote` is the span captured by the caller at
  gesture-start; Retime needs both ends to keep the op log self-contained
  for warp construction. Trim additionally writes the track module's
  compensated element (`Coconut.Edit.Track.retime_element/3`).

  For `:tempo` inserts, `attrs.bpm` is a plain bpm number (floats allowed),
  normalized to exact milli-bpm by the tempo track module's `cast_element/3`
  (the single rounding point). Element casting in general is the track
  module's business; Edit.Operation only shapes ops and span entries.
  """
  @type request ::
          InsertNote.t()
          | DeleteNote.t()
          | MoveNote.t()
          | DragNote.t()
          | SplitNote.t()
          | MergeNotes.t()
          | EditNote.t()
          | TrimNote.t()
          | DragNoteAcrossTracks.t()
          | struct()

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
          patches_add: [Coconut.Edit.Patch.t()],
          patches_remove: [term()]
        }

  # ---- Callbacks ----

  @callback validate(request(), Workspace.t()) :: :ok | {:error, term()}

  @callback lower(request(), Workspace.t(), Config.t()) ::
              {:ok, [Tamale.Op.t()], side_changes()} | {:error, term()}

  @callback lower_batches(request(), Workspace.t(), Config.t()) ::
              {:ok, [{track_id(), [Tamale.Op.t()], side_changes()}]} | {:error, term()}

  # 单轨手势实现 lower/3；跨轨手势实现 lower_batches/3（二者必居其一）
  @optional_callbacks lower: 3, lower_batches: 3

  # ---- Public API ----

  @doc """
  Validate a request against the current workspace state.

  Dispatches to the request struct's module. Checks: track exists, ids are
  live, span bounds are correct, merge ids are adjacent, etc. Returns `:ok`
  or `{:error, reason}`.
  """
  @spec validate(request(), Workspace.t()) :: :ok | {:error, term()}
  def validate(%mod{} = req, ws), do: mod.validate(req, ws)

  @doc """
  Lower a *validated* request into ops + side_changes.

  Dispatches to the request struct's module. Reads `spans_by_version` only
  for Split/Merge geometry — both are identity-shaped ops with no warp, so
  this never feeds warp construction. `Retime` stays self-contained: all
  its span data comes from the request itself.

  Multi-track requests do not implement `lower/3`; calling this on one
  returns `{:error, {:multi_track_request, _}}` — use `lower_batches/3`.

  This is a low-level adapter API and does not call `validate/2`. Host
  applications should normally write through `Coconut.Edit.History.apply/4`.
  """
  @spec lower(request(), Workspace.t(), Config.t()) ::
          {:ok, [Tamale.Op.t()], side_changes()} | {:error, term()}
  def lower(%mod{} = req, ws, cfg) do
    if function_exported?(mod, :lower, 3) do
      mod.lower(req, ws, cfg)
    else
      {:error, {:multi_track_request, mod}}
    end
  end

  @doc """
  Lower a *validated* request into per-track batches.

  Single-track gestures wrap `lower/3` into a one-element
  `[{track_id, ops, side_changes}]`; multi-track gestures implement the
  optional `lower_batches/3` callback and produce one batch per touched
  track, in application order. This is the lowering entry the write path
  (`Coconut.Edit.History.apply/4`) uses.
  """
  @spec lower_batches(request(), Workspace.t(), Config.t()) ::
          {:ok, [{track_id(), [Tamale.Op.t()], side_changes()}]} | {:error, term()}
  def lower_batches(%mod{} = req, ws, cfg) do
    if function_exported?(mod, :lower_batches, 3) do
      mod.lower_batches(req, ws, cfg)
    else
      with {:ok, ops, changes} <- lower(req, ws, cfg) do
        {:ok, [{req.track_id, ops, changes}]}
      end
    end
  end
end
