defmodule Coconut.Operations.CoreComponents do
  @moduledoc """
  Shared geometry/sequence checks for edit gestures.

  Generic legality predicates shared by the legacy tuple-dispatch
  `Coconut.Operate` clauses and the per-gesture structs under
  `Coconut.Operations.*`: shape/order/span checks live here, while
  element casting and track-type policy stay on the track modules
  (`Coconut.Track` behaviour).
  """

  require Coconut.Score.Tick
  alias Coconut.{Operate, Track, Workspace}
  alias Coconut.Score.Tick

  @empty_side_changes %{
    elements: %{},
    span_snapshot: %{},
    patches_add: [],
    patches_remove: []
  }

  @doc "An empty `Coconut.Operate.side_changes()` map; gesture lowerings merge their deltas into it."
  @spec empty_side_changes() :: Operate.side_changes()
  def empty_side_changes, do: @empty_side_changes

  # ---- Track / element lookup ----

  @doc """
  Fetches a track by id (`Coconut.Workspace.fetch_track/2`; the tempo
  track's id routes to its dedicated field).
  """
  @spec track_context(Workspace.t(), Track.track_id()) ::
          {:ok, Track.t()} | {:error, {:unknown_track, Track.track_id()}}
  def track_context(%Workspace{} = ws, track_id), do: Workspace.fetch_track(ws, track_id)

  @doc """
  Fetches an element's payload. A miss is `{:error, :unreachable}` —
  validate-level checks (`id_live?/2`) guard existence before lowering.
  """
  @spec fetch_element(Track.t(), Tamale.id()) :: {:ok, term()} | {:error, :unreachable}
  def fetch_element(track, id) do
    case Map.fetch(track.elements_by_id, id) do
      {:ok, element} -> {:ok, element}
      :error -> {:error, :unreachable}
    end
  end

  # ---- Id checks ----

  @doc "The id must be unused: neither live in the sequence nor tombstoned in `seen`."
  @spec id_fresh?(Tamale.Space.t(), Tamale.id()) :: :ok | {:error, {:id_conflict, Tamale.id()}}
  def id_fresh?(%Tamale.Space{} = space, id) do
    if id in space.ids or MapSet.member?(space.seen, id) do
      {:error, {:id_conflict, id}}
    else
      :ok
    end
  end

  @doc "The id must own live element data."
  @spec id_live?(Track.t(), Tamale.id()) :: :ok | {:error, {:unknown_id, Tamale.id()}}
  def id_live?(track, id) do
    if Map.has_key?(track.elements_by_id, id) do
      :ok
    else
      {:error, {:unknown_id, id}}
    end
  end

  @doc "The id must sit in the Space's sequence."
  @spec id_in_space?(Tamale.Space.t(), Tamale.id()) ::
          :ok | {:error, {:id_not_in_space, Tamale.id()}}
  def id_in_space?(space, id) do
    if id in space.ids do
      :ok
    else
      {:error, {:id_not_in_space, id}}
    end
  end

  @doc "Every id must own live element data; returns the first failure, `:ok` otherwise."
  @spec all_live?(Track.t(), [Tamale.id()]) :: :ok | {:error, term()}
  def all_live?(track, ids) do
    Enum.find_value(ids, :ok, fn id ->
      case id_live?(track, id) do
        :ok -> nil
        err -> err
      end
    end)
  end

  @doc "Every id must sit in the Space's sequence; returns the first failure, `:ok` otherwise."
  @spec all_in_space?(Tamale.Space.t(), [Tamale.id()]) :: :ok | {:error, term()}
  def all_in_space?(space, ids) do
    Enum.find_value(ids, :ok, fn id ->
      case id_in_space?(space, id) do
        :ok -> nil
        err -> err
      end
    end)
  end

  # ---- Sequence checks ----

  @doc "The insertion anchor must be `:head` or an id in the sequence."
  @spec after_valid?(Tamale.Space.t(), Tamale.id() | :head) ::
          :ok | {:error, {:unknown_after_id, Tamale.id()}}
  def after_valid?(_space, :head), do: :ok

  def after_valid?(%Tamale.Space{} = space, after_id) do
    if after_id in space.ids do
      :ok
    else
      {:error, {:unknown_after_id, after_id}}
    end
  end

  @doc "A node cannot be its own insertion anchor."
  @spec not_self?(Tamale.id(), Tamale.id() | :head) ::
          :ok | {:error, {:self_referential, Tamale.id()}}
  def not_self?(id, id), do: {:error, {:self_referential, id}}
  def not_self?(_id, _after), do: :ok

  @doc "The ids must appear consecutively in the Space's sequence, in the given order."
  @spec adjacent?(Tamale.Space.t(), [Tamale.id(), ...]) ::
          :ok
          | {:error, {:ids_not_in_space, [Tamale.id()]}}
          | {:error, {:ids_not_adjacent, [Tamale.id()]}}
  def adjacent?(space, ids) do
    idxs =
      ids
      |> Enum.map(&Enum.find_index(space.ids, fn x -> x == &1 end))

    if Enum.any?(idxs, &is_nil/1) do
      {:error, {:ids_not_in_space, ids}}
    else
      consecutive? =
        idxs |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> b == a + 1 end)

      if consecutive?, do: :ok, else: {:error, {:ids_not_adjacent, ids}}
    end
  end

  # ---- Span checks ----

  @doc "A span must be two numeric ticks with `0 <= start < end`."
  @spec note_span_valid?(Tick.numeric_tick() | term(), Tick.numeric_tick() | term()) ::
          :ok | {:error, {:invalid_span, {any(), any()}}}
  def note_span_valid?(start_t, end_t)
      when Tick.is_numeric_tick(start_t) and Tick.is_numeric_tick(end_t) and
             start_t >= 0 and end_t > start_t,
      do: :ok

  def note_span_valid?(start_t, end_t),
    do: {:error, {:invalid_span, {start_t, end_t}}}

  @doc """
  `at_tick` must fall strictly inside the id's HEAD span.

  Split is the only validate that back-reads span data, and only for the
  Split identity case (no warp involved).
  """
  @spec within_span?(Workspace.t(), Track.track_id(), Tamale.id(), Tick.numeric_tick()) ::
          :ok
          | {:error, {:split_out_of_bounds, {Tick.numeric_tick(), Tick.numeric_tick(),
                      Tick.numeric_tick()}}}
          | {:error, {:no_span_for_id, Tamale.id()}}
  def within_span?(ws, track, id, at_tick) do
    case Coconut.Workspace.latest_span(ws, track, id) do
      {s, e} when at_tick > s and at_tick < e -> :ok
      {s, e} -> {:error, {:split_out_of_bounds, {s, e, at_tick}}}
      nil -> {:error, {:no_span_for_id, id}}
    end
  end
end
