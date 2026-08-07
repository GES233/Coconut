defmodule Coconut.Edit.Operations.InsertNote do
  @moduledoc """
  Lowers and validates an insert-note gesture into a batch of operations.
  """
  import Coconut.Edit.Operations.CoreComponents

  alias Coconut.Edit.{Operation, Track, Workspace}
  alias Coconut.Score.Note

  @behaviour Coconut.Edit.Operation

  @type t :: %__MODULE__{
          track_id: Track.track_id(),
          note_id: Note.note_id(),
          after_id: Note.note_id() | :head,
          span: Operation.span(),
          attrs: map()
        }
  defstruct [:track_id, :note_id, :after_id, :span, :attrs]

  @impl true
  @spec validate(t(), Workspace.t()) :: :ok | {:error, term()}
  def validate(
        %__MODULE__{
          track_id: track_id,
          note_id: id,
          after_id: after_id,
          span: {start_t, end_t},
          attrs: attrs
        },
        ws
      ) do
    with {:ok, %Track{} = track} <- track_context(ws, track_id),
         :ok <- check_id(track.space, id),
         :ok <- check_valid(track.space, after_id),
         :ok <- validate_span(start_t, end_t),
         {:ok, _element} <- Track.cast_element(track, id, {start_t, end_t}, attrs) do
      Track.validate_gesture(track, :insert, %{id: id, span: {start_t, end_t}})
    end
  end

  @impl true
  @spec lower(t(), Workspace.t(), Operation.Config.t()) ::
          {:ok, [Tamale.Op.t()], Operation.side_changes()} | {:error, term()}
  def lower(
        %__MODULE__{
          track_id: track_id,
          note_id: id,
          after_id: after_id,
          span: span,
          attrs: attrs
        },
        ws,
        _cfg
      ) do
    with {:ok, track} <- track_context(ws, track_id),
         {:ok, element} <- Track.cast_element(track, id, span, attrs) do
      ops = [%Tamale.Op.Insert{id: id, after_id: after_id}]

      changes =
        empty_side_changes()
        |> Map.merge(%{elements: %{id => element}, span_snapshot: %{id => span}})

      {:ok, ops, changes}
    end
  end
end
