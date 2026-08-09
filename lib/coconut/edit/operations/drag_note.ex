defmodule Coconut.Edit.Operations.DragNote do
  @moduledoc """
  Lowers and validates a drag-note gesture into a batch of operations.
  """
  import Coconut.Edit.Operations.CoreComponents

  alias Coconut.Edit.{Operation, Track, Workspace}
  alias Coconut.Score.Note

  @behaviour Coconut.Edit.Operation

  @type t :: %__MODULE__{
          track_id: Track.track_id(),
          note_id: Note.note_id(),
          after_id: Note.note_id() | :head,
          old_span: Operation.span(),
          new_span: Operation.span()
        }
  defstruct [:track_id, :note_id, :after_id, :old_span, :new_span]

  @impl true
  @spec validate(t(), Workspace.t()) :: :ok | {:error, term()}
  def validate(
        %__MODULE__{
          track_id: track_id,
          note_id: id,
          after_id: new_after,
          old_span: old_span,
          new_span: {new_s, new_e} = new_span
        },
        ws
      ) do
    with {:ok, %Track{} = track} <- track_context(ws, track_id),
         :ok <- ensure_id_live(track, id),
         :ok <- ensure_id_in_space(track.space, id),
         :ok <- check_valid(track.space, new_after),
         :ok <- ensure_not_self(id, new_after),
         :ok <- validate_span(new_s, new_e) do
      Track.validate_gesture(track, :drag, %{id: id, old_span: old_span, new_span: new_span})
    end
  end

  @impl true
  @spec lower(t(), Workspace.t(), Operation.Config.t()) ::
          {:ok, [Tamale.Op.t()], Operation.side_changes()} | {:error, term()}
  def lower(
        %__MODULE__{
          note_id: id,
          after_id: new_after,
          old_span: old_span,
          new_span: new_span
        },
        _ws,
        _cfg
      ) do
    ops = [
      %Tamale.Op.Move{id: id, after_id: new_after},
      %Tamale.Op.Retime{id: id, old_span: old_span, new_span: new_span}
    ]

    changes =
      empty_side_changes()
      |> Map.merge(%{span_snapshot: %{id => new_span}})

    {:ok, ops, changes}
  end
end
