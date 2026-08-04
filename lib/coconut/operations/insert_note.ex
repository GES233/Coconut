defmodule Coconut.Operations.InsertNote do
  import Coconut.Operations.CoreComponents

  alias Coconut.{Operate, Track, Workspace}
  alias Coconut.Score.Note

  @behaviour Coconut.Operate

  @type t :: %__MODULE__{
          track_id: Track.track_id(),
          note_id: Note.note_id(),
          after_id: Note.note_id() | :head,
          span: Operate.span(),
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
         {:ok, _element} <- Track.cast_element(track, id, {start_t, end_t}, attrs),
         :ok <- Track.validate_gesture(track, :insert, %{id: id, span: {start_t, end_t}}) do
      :ok
    end
  end

  @impl true
  @spec lower(t(), Workspace.t(), Operate.Config.t()) ::
          {:ok, [Tamale.Op.t()], Operate.side_changes()} | {:error, term()}
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
