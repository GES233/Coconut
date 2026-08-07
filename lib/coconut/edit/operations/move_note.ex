defmodule Coconut.Edit.Operations.MoveNote do
  @moduledoc """
  Lowers and validates a move-note gesture into a batch of operations.
  """
  import Coconut.Edit.Operations.CoreComponents

  alias Coconut.Edit.{Operation, Track, Workspace}
  alias Coconut.Score.Note

  @behaviour Coconut.Edit.Operation

  @type t :: %__MODULE__{
          track_id: Track.track_id(),
          note_id: Note.note_id(),
          after_id: Note.note_id() | :head
        }
  defstruct [:track_id, :note_id, :after_id]

  @impl true
  @spec validate(t(), Workspace.t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{track_id: track_id, note_id: id, after_id: new_after}, ws) do
    with {:ok, %Track{} = track} <- track_context(ws, track_id),
         :ok <- ensure_id_live(track, id),
         :ok <- ensure_id_in_space(track.space, id),
         :ok <- check_valid(track.space, new_after) do
      ensure_not_self(id, new_after)
    end
  end

  @impl true
  @spec lower(t(), Workspace.t(), Operation.Config.t()) ::
          {:ok, [Tamale.Op.t()], Operation.side_changes()} | {:error, term()}
  def lower(%__MODULE__{note_id: id, after_id: new_after}, _ws, _cfg) do
    ops = [%Tamale.Op.Move{id: id, after_id: new_after}]
    # Move only changes order — span_snapshot & elements are identity.
    {:ok, ops, empty_side_changes()}
  end
end
