defmodule Coconut.Edit.Operations.DeleteNote do
  @moduledoc """
  Lowers and validates a delete-note gesture into a batch of operations.
  """
  import Coconut.Edit.Operations.CoreComponents

  alias Coconut.Edit.{Operation, Track, Workspace}
  alias Coconut.Score.Note

  @behaviour Coconut.Edit.Operation

  @type t :: %__MODULE__{
          track_id: Track.track_id(),
          note_id: Note.note_id()
        }
  defstruct [:track_id, :note_id]

  @impl true
  @spec validate(t(), Workspace.t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{track_id: track_id, note_id: id}, ws) do
    with {:ok, %Track{} = track} <- track_context(ws, track_id),
         :ok <- ensure_id_live(track, id),
         :ok <- ensure_id_in_space(track.space, id) do
      Track.validate_gesture(track, :delete, %{id: id})
    end
  end

  @impl true
  @spec lower(t(), Workspace.t(), Operation.Config.t()) ::
          {:ok, [Tamale.Op.t()], Operation.side_changes()} | {:error, term()}
  def lower(%__MODULE__{note_id: id}, _ws, _cfg) do
    ops = [%Tamale.Op.Delete{id: id}]

    changes =
      empty_side_changes()
      |> Map.merge(%{elements: %{id => :delete}, span_snapshot: %{id => :delete}})

    {:ok, ops, changes}
  end
end
