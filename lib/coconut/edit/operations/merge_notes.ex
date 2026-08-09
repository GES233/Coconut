defmodule Coconut.Edit.Operations.MergeNotes do
  @moduledoc """
  Lowers and validates a merge-notes gesture into a batch of operations.
  """
  import Coconut.Edit.Operations.CoreComponents

  alias Coconut.Edit.{Operation, Track, Workspace}
  alias Coconut.Score.Note

  @behaviour Coconut.Edit.Operation

  @type t :: %__MODULE__{
          track_id: Track.track_id(),
          note_ids: [Note.note_id(), ...]
        }
  defstruct [:track_id, :note_ids]

  @impl true
  @spec validate(t(), Workspace.t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{track_id: track_id, note_ids: ids}, ws) do
    with {:ok, track} <- track_context(ws, track_id),
         :ok <- non_empty(ids),
         :ok <- ensure_all_live(track, ids),
         :ok <- all_in_space?(track.space, ids),
         :ok <- ensure_adjacent(track.space, ids) do
      Track.validate_gesture(track, :merge, %{ids: ids})
    end
  end

  @impl true
  @spec lower(t(), Workspace.t(), Operation.Config.t()) ::
          {:ok, [Tamale.Op.t()], Operation.side_changes()} | {:error, term()}
  def lower(%__MODULE__{track_id: track_id, note_ids: ids}, ws, _cfg) do
    [into | rest] = ids
    ops = [%Tamale.Op.Merge{ids: ids, into: into}]

    with {:ok, track} <- track_context(ws, track_id) do
      spans = Enum.map(ids, &Track.latest_span(track, &1))

      if Enum.any?(spans, &is_nil/1) do
        {:error, :unreachable}
      else
        # Composite span runs from the earliest start to the latest end.
        # `into` keeps its own element payload — merging content (lyrics
        # etc.) is the caller's business, see `Coconut.Edit.Operations.EditNote`.
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

  defp non_empty([]), do: {:error, :empty_selection}
  defp non_empty([_ | _]), do: :ok
end
