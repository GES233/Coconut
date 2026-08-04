defmodule Coconut.Operations.SplitNote do
  import Coconut.Operations.CoreComponents

  alias Coconut.{Operate, Track, Workspace}
  alias Coconut.Score.Note

  @behaviour Coconut.Operate

  @type t :: %__MODULE__{
          track_id: Track.track_id(),
          note_id: Note.note_id(),
          at_tick: non_neg_integer(),
          new_id: Note.note_id()
        }
  defstruct [:track_id, :note_id, :at_tick, :new_id]

  @impl true
  @spec validate(t(), Workspace.t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{track_id: track_id, note_id: id, at_tick: at_tick, new_id: new_id}, ws) do
    with {:ok, %Track{} = track} <- track_context(ws, track_id),
         :ok <- ensure_id_live(track, id),
         :ok <- ensure_id_in_space(track.space, id),
         :ok <- check_id(track.space, new_id),
         :ok <- within_span?(ws, track_id, id, at_tick) do
      :ok
    end
  end

  @impl true
  @spec lower(t(), Workspace.t(), Operate.Config.t()) ::
          {:ok, [Tamale.Op.t()], Operate.side_changes()} | {:error, term()}
  def lower(
        %__MODULE__{track_id: track_id, note_id: id, at_tick: at_tick, new_id: new_id},
        ws,
        _cfg
      ) do
    ops = [%Tamale.Op.Split{id: id, children: [id, new_id]}]

    # Split reads the old span from track state — this is NOT the same
    # as back-reading for Retime. Split is identity-shaped (no warp), so
    # the span cut is pure geometry, not a warp ingredient.
    with {:ok, track} <- track_context(ws, track_id) do
      case Track.latest_span(track, id) do
        {s, e} when s < at_tick and at_tick < e ->
          # The right half's payload policy belongs to the track module
          # (vocal inherits the parent's content; lyric/tuning after a
          # split is the caller's business, see EditNote).
          parent = Map.get(track.elements_by_id, id)

          changes =
            empty_side_changes()
            |> Map.merge(%{
              elements: %{new_id => Track.split_inherit(track, parent, new_id)},
              span_snapshot: %{id => {s, at_tick}, new_id => {at_tick, e}}
            })

          {:ok, ops, changes}

        _ ->
          {:error, :unreachable}
      end
    end
  end
end
