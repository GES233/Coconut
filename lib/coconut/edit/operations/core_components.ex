defmodule Coconut.Edit.Operations.CoreComponents do
  @moduledoc """
  Shared geometry/sequence checks for edit gestures.

  Generic legality predicates for the per-gesture structs under
  `Coconut.Edit.Operations.*`: shape/order/span checks live here, while
  element casting and track-type policy stay on the track modules
  (`Coconut.Edit.Track` behaviour).
  """

  require Coconut.Score.Tick
  alias Coconut.Edit.{Operation, Track, Workspace}
  alias Coconut.Score.Tick

  @empty_side_changes %{
    elements: %{},
    span_snapshot: %{},
    patches_add: [],
    patches_remove: []
  }

  @doc "An empty `Coconut.Edit.Operation.side_changes()` map; gesture lowerings merge their deltas into it."
  @spec empty_side_changes() :: Operation.side_changes()
  def empty_side_changes, do: @empty_side_changes

  # ---- Track / element lookup ----

  @doc """
  Fetches a track by id (`Coconut.Edit.Workspace.fetch_track/2`;
  `"global:"`-prefixed ids route to the workspace's `globals`).
  """
  @spec track_context(Workspace.t(), Track.track_id()) ::
          {:ok, Track.t()} | {:error, {:unknown_track, Track.track_id()}}
  def track_context(%Workspace{} = ws, track_id), do: Workspace.fetch_track(ws, track_id)

  @doc """
  Fetches an element's payload. A miss is `{:error, :unreachable}` —
  validate-level checks (`ensure_id_live/2`) guard existence before lowering.
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
  @spec check_id(Tamale.Space.t(), Tamale.id()) :: :ok | {:error, {:id_conflict, Tamale.id()}}
  def check_id(%Tamale.Space{} = space, id) do
    if id in space.ids or MapSet.member?(space.seen, id) do
      {:error, {:id_conflict, id}}
    else
      :ok
    end
  end

  @doc "The id must own live element data."
  @spec ensure_id_live(Track.t(), Tamale.id()) :: :ok | {:error, {:unknown_id, Tamale.id()}}
  def ensure_id_live(track, id) do
    if Map.has_key?(track.elements_by_id, id) do
      :ok
    else
      {:error, {:unknown_id, id}}
    end
  end

  @doc "The id must sit in the Space's sequence."
  @spec ensure_id_in_space(Tamale.Space.t(), Tamale.id()) ::
          :ok | {:error, {:id_not_in_space, Tamale.id()}}
  def ensure_id_in_space(space, id) do
    if id in space.ids do
      :ok
    else
      {:error, {:id_not_in_space, id}}
    end
  end

  @doc "Every id must own live element data; returns the first failure, `:ok` otherwise."
  @spec ensure_all_live(Track.t(), [Tamale.id()]) :: :ok | {:error, term()}
  def ensure_all_live(track, ids) do
    Enum.find_value(ids, :ok, fn id ->
      case ensure_id_live(track, id) do
        :ok -> nil
        err -> err
      end
    end)
  end

  # Only merge_note
  @doc "Every id must sit in the Space's sequence; returns the first failure, `:ok` otherwise."
  @spec all_in_space?(Tamale.Space.t(), [Tamale.id()]) :: :ok | {:error, term()}
  def all_in_space?(space, ids) do
    Enum.find_value(ids, :ok, fn id ->
      case ensure_id_in_space(space, id) do
        :ok -> nil
        err -> err
      end
    end)
  end

  # ---- Sequence checks ----

  @doc "The insertion anchor must be `:head` or an id in the sequence."
  @spec check_valid(Tamale.Space.t(), Tamale.id() | :head) ::
          :ok | {:error, {:unknown_after_id, Tamale.id()}}
  def check_valid(_space, :head), do: :ok

  def check_valid(%Tamale.Space{} = space, after_id) do
    if after_id in space.ids do
      :ok
    else
      {:error, {:unknown_after_id, after_id}}
    end
  end

  @doc "A node cannot be its own insertion anchor."
  @spec ensure_not_self(Tamale.id(), Tamale.id() | :head) ::
          :ok | {:error, {:self_referential, Tamale.id()}}
  def ensure_not_self(id, id), do: {:error, {:self_referential, id}}
  def ensure_not_self(_id, _after), do: :ok

  @doc "The ids must appear consecutively in the Space's sequence, in the given order."
  @spec ensure_adjacent(Tamale.Space.t(), [Tamale.id(), ...]) ::
          :ok
          | {:error, {:ids_not_in_space, [Tamale.id()]}}
          | {:error, {:ids_not_adjacent, [Tamale.id()]}}
  def ensure_adjacent(space, ids) do
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
  @spec validate_span(Tick.numeric_tick() | term(), Tick.numeric_tick() | term()) ::
          :ok | {:error, {:invalid_span, {any(), any()}}}
  def validate_span(start_t, end_t)
      when Tick.is_numeric_tick(start_t) and Tick.is_numeric_tick(end_t) and
             start_t >= 0 and end_t > start_t,
      do: :ok

  def validate_span(start_t, end_t),
    do: {:error, {:invalid_span, {start_t, end_t}}}

  # Only split_note will use
  @doc """
  `at_tick` must fall strictly inside the id's HEAD span.

  Split is the only validate that back-reads span data, and only for the
  Split identity case (no warp involved).
  """
  @spec within_span?(Workspace.t(), Track.track_id(), Tamale.id(), Tick.numeric_tick()) ::
          :ok
          | {:error,
             {:split_out_of_bounds,
              {Tick.numeric_tick(), Tick.numeric_tick(), Tick.numeric_tick()}}}
          | {:error, {:missing_span_for_id, Tamale.id()}}
  def within_span?(ws, track, id, at_tick) do
    with {:ok, track} <- Workspace.fetch_track(ws, track) do
      case Track.latest_span(track, id) do
        {s, e} when at_tick > s and at_tick < e -> :ok
        {s, e} -> {:error, {:split_out_of_bounds, {s, e, at_tick}}}
        nil -> {:error, {:missing_span_for_id, id}}
      end
    end
  end
end
