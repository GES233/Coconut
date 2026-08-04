defmodule Coconut.Operations.MergeNotes do
  import Coconut.Operations.CoreComponents

  alias Coconut.{Operate, Track, Workspace}
  alias Coconut.Score.Note

  @behaviour Coconut.Operate

  @type t :: %__MODULE__{
          track_id: Track.track_id(),
          note_ids: [Note.note_id(), ...]
        }
  use Coconut.Util.Object, keys: [:track_id, :note_ids]

  @impl true
  @spec validate(t(), Workspace.t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{track_id: track_id, note_ids: ids}, ws) do
    with {:ok, track} <- track_context(ws, track_id),
         :ok <- non_empty(ids),
         :ok <- ensure_all_live(track, ids),
         :ok <- all_in_space?(track.space, ids),
         :ok <- ensure_adjacent(track.space, ids) do
      :ok
    end
  end

  @impl true
  @spec lower(t(), Workspace.t(), Operate.Config.t()) ::
          {:ok, [Tamale.Op.t()], Operate.side_changes()} | {:error, term()}
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
        # etc.) is domain policy, see `Coconut.Score.Note.merge/6`.
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
