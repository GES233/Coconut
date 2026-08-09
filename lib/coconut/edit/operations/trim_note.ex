defmodule Coconut.Edit.Operations.TrimNote do
  @moduledoc """
  Lowers and validates a trim gesture (span-edge drag) into a Retime batch.

  Unlike `DragNote` (whole-element move, extent unchanged), trim changes the
  span's extent and asks the track module to compensate the element payload
  via `Coconut.Edit.Track.retime_element/3` — audio clips shift their source
  offset, content carriers keep the element unchanged (design doc §11.8).
  `old_span` follows the same caller-captured, self-contained Retime
  discipline as `DragNote`.
  """
  import Coconut.Edit.Operations.CoreComponents

  alias Coconut.Edit.{Operation, Track, Workspace}
  alias Coconut.Score.Note

  @behaviour Coconut.Edit.Operation

  @type t :: %__MODULE__{
          track_id: Track.track_id(),
          note_id: Note.note_id(),
          old_span: Operation.span(),
          new_span: Operation.span()
        }
  defstruct [:track_id, :note_id, :old_span, :new_span]

  @impl true
  @spec validate(t(), Workspace.t()) :: :ok | {:error, term()}
  def validate(
        %__MODULE__{
          track_id: track_id,
          note_id: id,
          old_span: old_span,
          new_span: {new_s, new_e} = new_span
        },
        ws
      ) do
    with {:ok, %Track{} = track} <- track_context(ws, track_id),
         :ok <- ensure_id_live(track, id),
         :ok <- ensure_id_in_space(track.space, id),
         :ok <- validate_span(new_s, new_e),
         {:ok, element} <- fetch_element(track, id),
         {:ok, _compensated} <- Track.retime_element(track, element, old_span, new_span) do
      Track.validate_gesture(track, :trim, %{id: id, old_span: old_span, new_span: new_span})
    end
  end

  @impl true
  @spec lower(t(), Workspace.t(), Operation.Config.t()) ::
          {:ok, [Tamale.Op.t()], Operation.side_changes()} | {:error, term()}
  def lower(
        %__MODULE__{track_id: track_id, note_id: id, old_span: old_span, new_span: new_span},
        ws,
        _cfg
      ) do
    with {:ok, track} <- track_context(ws, track_id),
         {:ok, element} <- fetch_element(track, id),
         {:ok, compensated} <- Track.retime_element(track, element, old_span, new_span) do
      ops = [%Tamale.Op.Retime{id: id, old_span: old_span, new_span: new_span}]

      changes =
        empty_side_changes()
        |> Map.merge(%{elements: %{id => compensated}, span_snapshot: %{id => new_span}})

      {:ok, ops, changes}
    end
  end
end
