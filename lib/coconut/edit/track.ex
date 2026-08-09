defmodule Coconut.Edit.Track do
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
  - `edit_element/2` — content edit: merge `changes` onto the current
    element and re-cast (`Coconut.Edit.Operations.EditNote`'s lowering writes
    the result back as the element upsert).
  - `validate_gesture/3` — track-type-specific legality beyond the generic
    geometry/sequence checks (e.g. tempo's first-element protection).
  - `split_elements/2` — a split's two element payloads (`{left, right}`),
    derived from the parent and the cut geometry (audio re-addresses source
    offsets; content carriers keep both halves equal to the parent).
  - `retime_element/3` — element compensation for a span-edge change
    (trim): audio shifts the clip's source offset; content carriers return
    the element unchanged (the `use` default).
  - `view/1` — the flattened score view for `Coconut.Render.Engine.Snapshot`:
    `[{id, element, span}]` ordered by `{start, id}`.

  ## Optional capabilities

  A track module may additionally export optional capability callbacks,
  sniffed by `supports?/2` (export-based, not behaviour-enforced — they
  are opt-in, so required-callback enforcement cannot apply):

  - `:tempo_derive` — `tempo_events/1` (see `TempoDerive`): the tempo-map
    projection; `Coconut.Edit.Workspace` binds (and reserves) its `tempo`
    field by it.
  - `:element_codec` — `dump_element/1` + `load_element/1` (see
    `ElementCodec`), sniffed as a pair: per-element archive codec for
    `Coconut.Pickle.Track`.

  `use Coconut.Edit.Track` supplies permissive defaults for
  `validate_gesture/3` (accepts everything) and `retime_element/3`
  (returns the element unchanged).
  """

  alias Coconut.Score.Tick
  alias Coconut.Util.ID

  import Coconut.Util.Helpers, only: [normalize_attrs: 2]

  @typedoc "A span `{start, end}` in the track's coordinate domain."
  @type span :: {Tick.numeric_tick(), Tick.numeric_tick()}

  @typedoc "The flattened score view: `[{id, element, span}]` ordered by `{start, id}`."
  @type view :: [{Tamale.id(), element :: term(), span()}]

  @type track_id :: ID.t(__MODULE__)

  # `name` is a display annotation (design doc §11.8): mutable, non-unique,
  # nilable — never an identity. Routing, anchors and version pins use `id`.
  @type t :: %__MODULE__{
          id: track_id(),
          name: String.t() | nil,
          module: module(),
          space: Tamale.Space.t(),
          spans_by_version: %{Tamale.version() => %{Tamale.id() => span()}},
          elements_by_id: %{Tamale.id() => term()},
          patches: [Coconut.Edit.Patch.t()],
          dead_patches: [{Coconut.Edit.Patch.t(), term()}]
        }

  @enforce_keys [:module]
  @keys [
    :id,
    :module,
    name: nil,
    space: %Tamale.Space{},
    spans_by_version: %{},
    elements_by_id: %{},
    patches: [],
    dead_patches: []
  ]
  defstruct @keys

  @doc "Create a new track based on the attributes. `:id` must be provided explicitly."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs, @keys) do
      case Map.fetch(normalized, :id) do
        :error -> {:error, {:missing_id, "Track_"}}
        {:ok, id} -> {:ok, struct(__MODULE__, Map.put(normalized, :id, id))}
      end
    end
  end

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
  Merge a content edit onto the current element and re-cast it.

  `changes` is a partial attrs map (same vocabulary as `cast_element/3`'s
  attrs); untouched fields carry over.
  """
  @callback edit_element(element :: term(), changes :: map()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Track-type-specific legality, consulted after the generic checks.

  `info` carries gesture-specific data (e.g. `%{id: id}` for `:delete`).
  The default (`use Coconut.Edit.Track`) accepts everything.
  """
  @callback validate_gesture(gesture :: atom(), t(), info :: map()) :: :ok | {:error, term()}

  @doc """
  Element payloads for both halves of a split, `{left, right}`.

  `context` carries the cut geometry: `:span` (the parent's pre-split
  span), `:at` (the cut coordinate), and `:new_id` (the right half's id).
  Content carriers (vocal, tempo) keep both halves equal to the parent;
  audio clips re-address source offsets — left half shrinks its duration
  to `at - start`, right half shifts `source_offset` by the same amount
  (design doc §11.8).
  """
  @callback split_elements(
              parent_element :: term(),
              context :: %{span: span(), at: Tick.numeric_tick(), new_id: Tamale.id()}
            ) :: {term(), term()}

  @doc """
  Element compensation for a span-edge change (trim, design doc §11.8).

  Content carriers ignore span geometry and return the element unchanged
  (the `use` default). Audio clips shift `source_offset_frames` by the
  start delta and re-derive `duration_frames` from the new span, rejecting
  a negative source offset.
  """
  @callback retime_element(element :: term(), old_span :: span(), new_span :: span()) ::
              {:ok, term()} | {:error, term()}

  @doc "Flattened score view for `Coconut.Render.Engine.Snapshot`."
  @callback view(t()) :: view()

  defmacro __using__(_opts) do
    quote do
      @behaviour Coconut.Edit.Track

      @impl true
      def validate_gesture(_gesture, _track, _info), do: :ok

      @impl true
      def retime_element(element, _old_span, _new_span), do: {:ok, element}

      defoverridable validate_gesture: 3, retime_element: 3
    end
  end

  # ---- Facade ----

  # Call sites delegate through these rather than touching `track.module`
  # directly (same convention as `Coconut.Score.Key`'s Facade API).
  # `tempo_events/1` is deliberately absent: it is a tempo-track capability
  # (see the Capabilities section), not a behaviour callback, and stays a
  # composition-root concern (`Coconut.Edit.Workspace.tempo_map/1`).

  @doc "The track's coordinate domain (`:tick` | `:frame`)."
  @spec coord_domain(t()) :: :tick | :frame
  def coord_domain(%__MODULE__{module: module}), do: module.coord_domain()

  @doc "Cast raw insert attrs into the track's element payload."
  @spec cast_element(t(), Tamale.id(), span(), attrs :: map()) :: {:ok, term()} | {:error, term()}
  def cast_element(%__MODULE__{module: module}, id, span, attrs),
    do: module.cast_element(id, span, attrs)

  @doc "Merge a content edit onto `element` and re-cast it."
  @spec edit_element(t(), element :: term(), changes :: map()) :: {:ok, term()} | {:error, term()}
  def edit_element(%__MODULE__{module: module}, element, changes),
    do: module.edit_element(element, changes)

  @doc "Track-type-specific gesture legality (default: accept everything)."
  @spec validate_gesture(t(), gesture :: atom(), info :: map()) :: :ok | {:error, term()}
  def validate_gesture(%__MODULE__{module: module} = track, gesture, info),
    do: module.validate_gesture(gesture, track, info)

  @doc "Element payloads for both halves of a split (`{left, right}`)."
  @spec split_elements(t(), parent_element :: term(), context :: map()) :: {term(), term()}
  def split_elements(%__MODULE__{module: module}, parent, context),
    do: module.split_elements(parent, context)

  @doc "Element compensation for a span-edge change (trim)."
  @spec retime_element(t(), element :: term(), old_span :: span(), new_span :: span()) ::
          {:ok, term()} | {:error, term()}
  def retime_element(%__MODULE__{module: module}, element, old_span, new_span),
    do: module.retime_element(element, old_span, new_span)

  @doc "The flattened score view (see `Coconut.Edit.Track.view/1` in the behaviour docs)."
  @spec view(t()) :: view()
  def view(%__MODULE__{module: module} = track), do: module.view(track)

  # ---- Capabilities ----

  # Optional capabilities are sniffed by export, not declared in the
  # behaviour above (they are opt-in, so required-callback enforcement
  # cannot apply). This table is the single place that names their
  # callbacks; call sites ask supports?/2 instead of hardcoding function
  # names, so a new track type (e.g. a plugin module) is discovered
  # automatically once it exports the callbacks.

  @typedoc """
  Optional track-module capabilities (see `supports?/2`).

  - `:tempo_derive` — `tempo_events/1` (`TempoDerive`): the tempo-map
    projection; `Coconut.Edit.Workspace.validate/1` binds (and reserves) the
    `tempo` field by it.
  - `:element_codec` — `dump_element/1` + `load_element/1`
    (`ElementCodec`), sniffed as a pair: per-element archive codec for
    `Coconut.Pickle.Track`.
  """
  @type capability :: :tempo_derive | :element_codec

  @capabilities %{
    tempo_derive: [tempo_events: 1],
    element_codec: [dump_element: 1, load_element: 1]
  }

  @doc """
  Whether `module` exports every callback of the optional `capability`.

  The single sniffing point (`Code.ensure_loaded?` + `function_exported?`
  per callback), keeping capability callback names out of call sites. A
  multi-callback capability (`:element_codec`) counts only when the full
  set is exported — a module exporting half of it is treated as not
  supporting it at all (no half-broken dump/load).

  Declaring the matching `@behaviour` (`TempoDerive` / `ElementCodec`)
  buys compile-time warnings but is not required: binding stays by
  export, not by declaration.
  """
  @spec supports?(module(), capability()) :: boolean()
  def supports?(module, capability) when is_atom(module) do
    Code.ensure_loaded?(module) and
      Enum.all?(Map.fetch!(@capabilities, capability), fn {fun, arity} ->
        function_exported?(module, fun, arity)
      end)
  end

  # ---- Span table ----

  @doc "The track's versioned span table, for `Coconut.Edit.WarpProvider.for_coord/3`."
  @spec spans(t()) :: %{Tamale.version() => %{Tamale.id() => span()}}
  def spans(%__MODULE__{spans_by_version: spans_by_version}), do: spans_by_version

  @doc """
  The latest recorded span table.

  "Latest recorded" means the newest version that actually has a snapshot —
  Move-only batches write no span snapshot, so this may lag behind the
  Space's head version.
  """
  @spec latest_spans(t()) :: %{Tamale.id() => span()}
  def latest_spans(track) do
    case track |> spans() |> Map.keys() |> Enum.max(fn -> nil end) do
      nil -> %{}
      version -> Map.fetch!(track.spans_by_version, version)
    end
  end

  @doc "The latest recorded span for a single element, or `nil`."
  @spec latest_span(t(), Tamale.id()) :: span() | nil
  def latest_span(track, id) do
    track |> latest_spans() |> Map.get(id)
  end

  # ---- Truncation (design doc §11.3) ----

  @doc """
  Truncate history below `oldest_live_version` (design doc §11.3).

  The Space's op log is cut via `Tamale.Space.truncate/2`; span snapshots
  older than the cut are dropped, except the newest pre-cut snapshot —
  Move-only batches write no spans, so that baseline may be the only
  source of `latest_spans/1` after truncation.
  """
  @spec truncate(t(), Tamale.version()) :: t()
  def truncate(track, oldest_live_version) do
    kept =
      for {version, spans} <- track.spans_by_version,
          version > oldest_live_version,
          into: %{},
          do: {version, spans}

    # Snapshots are sparse (Move-only batches write none), so warp
    # construction for the oldest retained log entries — `spans_at(v - 1)`
    # in `Coconut.Edit.WarpProvider` — can resolve below the cut. Always keep
    # the newest snapshot at or below it as the baseline.
    baseline =
      track.spans_by_version
      |> Enum.filter(fn {version, _} -> version <= oldest_live_version end)
      |> Enum.max_by(fn {version, _} -> version end, fn -> nil end)

    spans_by_version =
      case baseline do
        nil -> kept
        {version, spans} -> Map.put(kept, version, spans)
      end

    %{
      track
      | space: Tamale.Space.truncate(track.space, oldest_live_version),
        spans_by_version: spans_by_version
    }
  end

  # ---- Sync (the write side of `Workspace.apply_batch/5`) ----

  @doc """
  Sync the side tables after an op batch commits.

  `changes` is `Coconut.Edit.Operation`'s side_changes: element upserts/tombstones,
  span deltas, and patch removals. `patches_add` is *not* handled here —
  additions join after write-time transport, minted at the new head (see
  `Coconut.Edit.Workspace.apply_batch/5`).
  """
  @spec sync(t(), Tamale.version(), Coconut.Edit.Operation.side_changes()) :: t()
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

  defmodule TempoDerive do
    @moduledoc """
    Optional `:tempo_derive` capability: the tempo-map projection
    (`Coconut.Edit.Workspace.tempo_map/1`). Sniffed via
    `Coconut.Edit.Track.supports?/2`; declaring this behaviour buys
    compile-time warnings but is not required.
    """

    @callback tempo_events(Coconut.Edit.Track.t()) :: [
                {Coconut.Score.Tick.numeric_tick(), Coconut.Score.Tempo.Event.t()}
              ]
  end

  defmodule ElementCodec do
    @moduledoc """
    Optional `:element_codec` capability: per-element archive codec for
    `Coconut.Pickle.Track`. Both callbacks are sniffed as a pair via
    `Coconut.Edit.Track.supports?/2` — a module exporting only one is treated
    as codec-less (archiving a non-empty element table then fails with
    `{:error, {:no_element_codec, module}}`).
    """

    @callback dump_element(element :: term()) :: {:ok, term()} | {:error, term()}
    @callback load_element(dumped :: term()) :: {:ok, term()} | {:error, term()}
  end
end
