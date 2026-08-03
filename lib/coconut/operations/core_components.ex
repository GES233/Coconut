defmodule Coconut.Operations.CoreComponents do
  require Coconut.Score.Tick
  alias Coconut.{Operate, Workspace, Track}
  alias Coconut.Score.Tick

  @empty_side_changes %{
    elements: %{},
    span_snapshot: %{},
    patches_add: [],
    patches_remove: []
  }

  @spec empty_side_changes() :: Operate.side_changes()
  def empty_side_changes, do: @empty_side_changes

  # ---- Helpers ----

  @spec track_context(Coconut.Workspace.t(), Track.track_id()) ::
          {:error, {:unknown_track, Track.track_id()}} | {:ok, Coconut.Track.t()}
  def track_context(%Workspace{} = ws, track_id), do: Workspace.fetch_track(ws, track_id)

  def id_fresh?(%Tamale.Space{} = space, id) do
    if id in space.ids or MapSet.member?(space.seen, id) do
      {:error, {:id_conflict, id}}
    else
      :ok
    end
  end

  def after_valid?(_space, :head), do: :ok

  def after_valid?(%Tamale.Space{} = space, after_id) do
    if after_id in space.ids do
      :ok
    else
      {:error, {:unknown_after_id, after_id}}
    end
  end

  @spec note_span_valid?(Tick.numeric_tick() | term(), Tick.numeric_tick() | term()) ::
          :ok | {:error, {:invalid_span, {any(), any()}}}
  def note_span_valid?(start_t, end_t)
      when Tick.is_numeric_tick(start_t) and Tick.is_numeric_tick(end_t) and
             start_t >= 0 and end_t > start_t,
      do: :ok

  def note_span_valid?(start_t, end_t),
    do: {:error, {:invalid_span, {start_t, end_t}}}
end
