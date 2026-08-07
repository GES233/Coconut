defmodule Coconut.Edit.Operations.EditNote do
  @moduledoc """
  Lowers and validates an edit-note gesture into a batch of operations.
  """
  import Coconut.Edit.Operations.CoreComponents

  alias Coconut.Edit.{Operation, Track, Workspace}
  alias Coconut.Score.Note

  @behaviour Coconut.Edit.Operation

  @type t :: %__MODULE__{
          track_id: Track.track_id(),
          note_id: Note.note_id(),
          changes: map()
        }
  defstruct [:track_id, :note_id, :changes]

  @impl true
  @spec validate(t(), Workspace.t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{track_id: track_id, note_id: id, changes: changes}, ws) do
    with {:ok, %Track{} = track} <- track_context(ws, track_id),
         :ok <- ensure_id_live(track, id),
         {:ok, _element} <-
           Track.edit_element(track, Map.fetch!(track.elements_by_id, id), changes) do
      :ok
    end
  end

  @impl true
  @spec lower(t(), Workspace.t(), Operation.Config.t()) ::
          {:ok, [Tamale.Op.t()], Operation.side_changes()} | {:error, term()}
  def lower(%__MODULE__{track_id: track_id, note_id: id, changes: changes}, ws, _cfg) do
    # Content edits produce no ops: the track module merges the changes
    # onto the current element and re-casts it, and the result is written
    # back via the elements side table. Patch/digest semantics around the
    # edit (base_digest refresh) remain the caller's business.
    with {:ok, track} <- track_context(ws, track_id),
         {:ok, element} <- fetch_element(track, id),
         {:ok, new_element} <- Track.edit_element(track, element, changes) do
      side = %{empty_side_changes() | elements: %{id => new_element}}
      {:ok, [], side}
    end
  end
end
