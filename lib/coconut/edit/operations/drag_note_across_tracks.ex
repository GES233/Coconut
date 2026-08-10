defmodule Coconut.Edit.Operations.DragNoteAcrossTracks do
  @moduledoc """
  Lowers and validates a cross-track drag gesture (design doc §8 跨 Space
  重挂, option a): delete the note on the source track, insert a fresh
  copy on the target track — lowered as one atomic two-track batch so it
  commits as a single History edge (one undo step).

  Option a consequences: the copy gets a **fresh id** (`new_id` — an id is
  Space-level identity, so reusing the source id would strand every patch
  anchored to it), and patches do not migrate — anchors on the source note
  die into the source track's graveyard at write-time transport, where the
  policy layer decides re-mount or discard.

  `attrs` is the target-track element payload: the target module's
  `cast_element/3` applies, so cross-module drags (vocal → audio) are
  possible when the target accepts the attrs. The caller decides what
  content carries over (e.g. the shell copies the source note's fields).
  """

  alias Coconut.Edit.{Operation, Track, Workspace}
  alias Coconut.Edit.Operations.{DeleteNote, InsertNote}
  alias Coconut.Score.Note

  @behaviour Coconut.Edit.Operation

  @type t :: %__MODULE__{
          from_track: Track.track_id(),
          note_id: Note.note_id(),
          to_track: Track.track_id(),
          new_id: Note.note_id(),
          after_id: Note.note_id() | :head,
          span: Operation.span(),
          attrs: map()
        }
  defstruct [:from_track, :note_id, :to_track, :new_id, :after_id, :span, :attrs]

  @impl true
  @spec validate(t(), Workspace.t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{from_track: same, to_track: same}, _ws),
    do: {:error, {:same_track, same}}

  def validate(%__MODULE__{} = req, ws) do
    with :ok <- DeleteNote.validate(delete_req(req), ws),
         do: InsertNote.validate(insert_req(req), ws)
  end

  # 多轨手势：实现可选回调 lower_batches/3 而非 lower/3。两半的合法性
  # 与 lowering 完全委托给 DeleteNote / InsertNote——本模块只做编排。
  @impl true
  @spec lower_batches(t(), Workspace.t(), Operation.Config.t()) ::
          {:ok, [{Track.track_id(), [Tamale.Op.t()], Operation.side_changes()}]}
          | {:error, term()}
  def lower_batches(%__MODULE__{} = req, ws, cfg) do
    with {:ok, del_ops, del_changes} <- DeleteNote.lower(delete_req(req), ws, cfg),
         {:ok, ins_ops, ins_changes} <- InsertNote.lower(insert_req(req), ws, cfg) do
      {:ok, [{req.from_track, del_ops, del_changes}, {req.to_track, ins_ops, ins_changes}]}
    end
  end

  defp delete_req(req), do: %DeleteNote{track_id: req.from_track, note_id: req.note_id}

  defp insert_req(req) do
    %InsertNote{
      track_id: req.to_track,
      note_id: req.new_id,
      after_id: req.after_id,
      span: req.span,
      attrs: req.attrs
    }
  end
end
