defmodule Coconut.Track do
  @moduledoc """
  A track: one `Tamale.Space` plus its side tables, typed by a track module.

  Tracks own everything that used to live in the workspace `Side` drawer
  (design doc §11.3): the versioned span table (the timing authority,
  §11.2), the element payloads, and the track's patches — interventions
  transport per track, so they are stored per track.

  ## Track modules (behaviour)

  The module types the track's element shape and policy:

  - `coord_domain/0` — the coordinate system spans live in (`:tick` for
    score tracks; `:frame` for audio tracks, design doc §11.8).
  - `cast_element/3` — raw insert attrs → element payload (`Note` for
    vocal, bpm map for tempo).
  - `validate_gesture/3` — track-type-specific legality beyond the generic
    geometry/sequence checks (e.g. tempo's first-element protection).
  - `split_inherit/2` — the right half of a split's element payload.
  - `view/1` — the flattened score view for `Coconut.Engine.Snapshot`:
    `[{id, element, span}]` ordered by `{start, id}`.

  `use Coconut.Track` supplies a permissive `validate_gesture/3` default.
  """

  alias Coconut.Score.Tick

  @typedoc "A span `{start, end}` in the track's coordinate domain."
  @type span :: {Tick.numeric_tick(), Tick.numeric_tick()}

  @typedoc "The flattened score view: `[{id, element, span}]` ordered by `{start, id}`."
  @type view :: [{Tamale.id(), element :: term(), span()}]

  @type t :: %__MODULE__{
          id: term(),
          module: module(),
          space: Tamale.Space.t(),
          spans_by_version: %{Tamale.version() => %{Tamale.id() => span()}},
          elements_by_id: %{Tamale.id() => term()},
          patches: [Coconut.Patch.t()],
          dead_patches: [{Coconut.Patch.t(), term()}]
        }

  defstruct [
    :id,
    :module,
    space: %Tamale.Space{},
    spans_by_version: %{},
    elements_by_id: %{},
    patches: [],
    dead_patches: []
  ]

  # ---- Behaviour ----

  @doc "Coordinate system this track's spans live in."
  @callback coord_domain() :: :tick | :frame

  @doc """
  Cast raw insert attrs into the track's element payload.

  `span` is the insert span in the track's coordinate domain — content
  carriers like `Note` ignore it (timing lives in the spans table); audio
  clips derive content addressing from it.
  """
  @callback cast_element(Tamale.id(), span(), attrs :: map()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Track-type-specific legality, consulted after the generic checks.

  `info` carries gesture-specific data (e.g. `%{id: id}` for `:delete`).
  The default (`use Coconut.Track`) accepts everything.
  """
  @callback validate_gesture(gesture :: atom(), t(), info :: map()) :: :ok | {:error, term()}

  @doc "Element payload for the right half of a split."
  @callback split_inherit(parent_element :: term(), new_id :: Tamale.id()) :: term()

  @doc "Flattened score view for `Coconut.Engine.Snapshot`."
  @callback view(t()) :: view()

  defmacro __using__(_opts) do
    quote do
      @behaviour Coconut.Track

      @impl true
      def validate_gesture(_gesture, _track, _info), do: :ok

      defoverridable validate_gesture: 3
    end
  end

  # ---- Constructor ----

  @doc "Create a track of the given module, wrapping a fresh `Tamale.Space`."
  @spec new(term(), module(), keyword()) :: t()
  def new(id, module, opts \\ []) do
    %__MODULE__{
      id: id,
      module: module,
      space: Keyword.get(opts, :space, %Tamale.Space{})
    }
  end

  # ---- Span table ----

  @doc "The track's versioned span table, for `Coconut.WarpProvider.tick/2`."
  @spec spans(t()) :: %{Tamale.version() => %{Tamale.id() => span()}}
  def spans(track), do: track.spans_by_version

  @doc """
  The latest recorded span table.

  "Latest recorded" means the newest version that actually has a snapshot —
  Move-only batches write no span snapshot, so this may lag behind the
  Space's head version.
  """
  @spec latest_spans(t()) :: %{Tamale.id() => span()}
  def latest_spans(track) do
    case Enum.max(Map.keys(track.spans_by_version), fn -> nil end) do
      nil -> %{}
      version -> Map.fetch!(track.spans_by_version, version)
    end
  end

  @doc "The latest recorded span for a single element, or `nil`."
  @spec latest_span(t(), Tamale.id()) :: span() | nil
  def latest_span(track, id) do
    track |> latest_spans() |> Map.get(id)
  end

  # ---- Sync (the write side of `Workspace.apply_batch/5`) ----

  @doc """
  Sync the side tables after an op batch commits.

  `changes` is `Coconut.Operate`'s side_changes: element upserts/tombstones,
  span deltas, and patch removals. `patches_add` is *not* handled here —
  additions join after write-time transport, minted at the new head (see
  `Coconut.Workspace.apply_batch/5`).
  """
  @spec sync(t(), Tamale.version(), Coconut.Operate.side_changes()) :: t()
  def sync(track, new_version, changes) do
    track
    |> sync_elements(changes.elements)
    |> sync_spans(new_version, changes.span_snapshot)
    |> drop_patches(changes.patches_remove)
  end

  defp sync_elements(track, elements) when map_size(elements) == 0, do: track

  defp sync_elements(track, elements) do
    # `:delete` tombstones remove the element; `:touch` / `:pending` are
    # markers only (no data change) — same convention as apply_span_deltas/2.
    by_id =
      Enum.reduce(elements, track.elements_by_id, fn
        {id, :delete}, acc ->
          Map.delete(acc, id)

        {_id, marker}, acc when marker in [:touch, :pending] ->
          acc

        {id, data}, acc ->
          Map.put(acc, id, data)
      end)

    %{track | elements_by_id: by_id}
  end

  defp sync_spans(track, _new_version, span_changes) when map_size(span_changes) == 0,
    do: track

  defp sync_spans(track, new_version, span_changes) do
    new = track |> latest_spans() |> apply_span_deltas(span_changes)

    %{track | spans_by_version: Map.put(track.spans_by_version, new_version, new)}
  end

  defp apply_span_deltas(prev, deltas) do
    {upserts, tombstones} =
      Enum.split_with(deltas, fn {_id, v} ->
        v != :delete and v != :pending and v != :touch
      end)

    result = Map.merge(prev, Map.new(upserts))

    Enum.reduce(tombstones, result, fn
      {id, :delete}, acc -> Map.delete(acc, id)
      {_id, _other}, acc -> acc
    end)
  end

  # Removes land before write-time transport; additions land after it (see
  # Workspace.apply_batch/5), so a batch never transports the patches it mints.
  defp drop_patches(track, []), do: track
  defp drop_patches(track, removes), do: %{track | patches: track.patches -- removes}
end
