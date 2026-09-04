defmodule Coconut.Edit.Track do
  @moduledoc """
  A track: one `Tamale.Space` plus its side tables, typed by a track module.

  Tracks own everything that used to live in the workspace `Side` drawer
  (design doc §11.3): the versioned span table (the timing authority,
  §11.2), the element payloads, and the track's patches — interventions
  transport per track, so they are stored per track. The `version_clock`
  maps each of the track's Space versions to the workspace `edit_version`
  at which it was committed — the cross-track correlation facility that lets
  a frame-coord warp locate the tempo state paired with a log entry
  (design doc §5 item 4, the `T_old`/`T_new` pair).

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
  - `validate_state/1` — whole-track invariants checked at construction and
    after every workspace commit.

  ## Optional capabilities

  A track module may additionally export optional capability callbacks,
  sniffed by `supports?/2` (export-based, not behaviour-enforced — they
  are opt-in, so required-callback enforcement cannot apply):

  - `:tempo_derive` — `tempo_events/1` (see `TempoDerive`): the tempo-map
    projection; `Coconut.Edit.Workspace` binds (and reserves) the
    `"global:tempo"` globals slot by it.

  `use Coconut.Edit.Track` supplies permissive defaults for
  `validate_gesture/3` (accepts everything) and `retime_element/3`
  (returns the element unchanged).
  """

  alias Coconut.Pickle
  alias Coconut.Score.Tick
  alias Coconut.Util.ID

  import Coconut.Util.Helpers, only: [normalize_attrs: 2]

  @typedoc "A span `{start, end}` in the track's coordinate domain."
  @type span :: {Tick.numeric_tick(), Tick.numeric_tick()}

  @typedoc "The flattened score view: `[{id, element, span}]` ordered by `{start, id}`."
  @type view :: [{Tamale.id(), element :: term(), span()}]

  @type track_id :: ID.t(__MODULE__)

  # `name` / `metadata` 是展示注释，不参与身份；`extras` 是宿主命名空间下的
  # 工程扩展事实。三者都不能承载运行时对象，路由、anchor 与版本 pin 只用 `id`。
  @type plain_data :: map() | list() | number() | atom() | binary() | nil

  @type t :: %__MODULE__{
          id: track_id(),
          name: String.t() | nil,
          metadata: map(),
          extras: map(),
          module: module(),
          space: Tamale.Space.t(),
          spans_by_version: %{Tamale.version() => %{Tamale.id() => span()}},
          version_clock: %{Tamale.version() => Tamale.version()},
          elements_by_id: %{Tamale.id() => term()},
          patches: [Coconut.Edit.Patch.t()],
          dead_patches: [{Coconut.Edit.Patch.t(), term()}]
        }

  @enforce_keys [:module]
  @keys [
    :id,
    :module,
    name: nil,
    metadata: %{},
    extras: %{},
    space: %Tamale.Space{},
    spans_by_version: %{},
    version_clock: %{},
    elements_by_id: %{},
    patches: [],
    dead_patches: []
  ]
  defstruct @keys

  @doc "Create a new track based on the attributes. `:id` must be provided explicitly."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs, @keys),
         :ok <- validate_plain_map(:metadata, Map.get(normalized, :metadata, %{})),
         :ok <- validate_plain_map(:extras, Map.get(normalized, :extras, %{})) do
      case Map.fetch(normalized, :id) do
        :error -> {:error, {:missing_id, "Track_"}}
        {:ok, id} -> {:ok, struct(__MODULE__, Map.put(normalized, :id, id))}
      end
    end
  end

  defp validate_plain_map(:metadata, value) when is_map(value) do
    if Pickle.pickle_conform?(value),
      do: :ok,
      else: {:error, {:non_conform_metadata, value}}
  end

  defp validate_plain_map(:extras, value) when is_map(value) do
    if Pickle.pickle_conform?(value),
      do: :ok,
      else: {:error, {:non_conform_extras, value}}
  end

  defp validate_plain_map(:metadata, value), do: {:error, {:invalid_metadata, value}}
  defp validate_plain_map(:extras, value), do: {:error, {:invalid_extras, value}}

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

  @doc "Validate invariants of a fully materialized track state."
  @callback validate_state(t()) :: :ok | {:error, term()}
  @optional_callbacks validate_state: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour Coconut.Edit.Track

      @impl true
      def validate_gesture(_gesture, _track, _info), do: :ok

      @impl true
      def retime_element(element, _old_span, _new_span), do: {:ok, element}

      @impl true
      def validate_state(_track), do: :ok

      defoverridable validate_gesture: 3, retime_element: 3, validate_state: 1
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

  @doc "Validate the track module's whole-state invariants."
  @spec validate_state(t()) :: :ok | {:error, term()}
  def validate_state(%__MODULE__{module: module} = track) do
    with :ok <- validate_plain_map(:metadata, track.metadata),
         :ok <- validate_plain_map(:extras, track.extras),
         :ok <- validate_live_tables(track),
         :ok <- validate_spans(track),
         {:module, _module} <- Code.ensure_loaded(module) do
      if function_exported?(module, :validate_state, 1),
        do: module.validate_state(track),
        else: :ok
    else
      {:error, reason} when is_atom(reason) -> {:error, {:invalid_track_module, module, reason}}
      {:error, _} = error -> error
    end
  end

  defp validate_live_tables(track) do
    live_ids = MapSet.new(track.space.ids)
    element_ids = track.elements_by_id |> Map.keys() |> MapSet.new()
    span_ids = track |> latest_spans() |> Map.keys() |> MapSet.new()

    cond do
      MapSet.size(live_ids) != length(track.space.ids) ->
        {:error, :duplicate_track_ids}

      element_ids != live_ids ->
        {:error, table_mismatch(:elements_by_id, live_ids, element_ids)}

      span_ids != live_ids ->
        {:error, table_mismatch(:spans_by_version, live_ids, span_ids)}

      true ->
        :ok
    end
  end

  defp table_mismatch(table, live_ids, actual_ids) do
    {:track_table_mismatch,
     %{
       table: table,
       missing: live_ids |> MapSet.difference(actual_ids) |> Enum.sort(),
       extra: actual_ids |> MapSet.difference(live_ids) |> Enum.sort()
     }}
  end

  defp validate_spans(track) do
    Enum.find_value(latest_spans(track), :ok, fn
      {_id, {start_tick, end_tick}}
      when is_integer(start_tick) and start_tick >= 0 and is_integer(end_tick) and
             end_tick > start_tick ->
        nil

      {id, span} ->
        {:error, {:invalid_track_span, id, span}}
    end)
  end

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
    `"global:tempo"` globals slot by it. Plus `tempo_steps_at/2`: the
    versioned, exact (integer milli-bpm) step projection backing the
    frame-warp tempo pair (design doc §5 item 4).
  """
  @type capability :: :tempo_derive

  @capabilities %{
    tempo_derive: [tempo_events: 1, tempo_steps_at: 2]
  }

  @doc """
  Whether `module` exports every callback of the optional `capability`.

  The single sniffing point (`Code.ensure_loaded?` + `function_exported?`
  per callback), keeping capability callback names out of call sites.

  Declaring the matching `@behaviour` (`TempoDerive`) buys compile-time
  warnings but is not required: binding stays by export, not by declaration.
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

  @doc "The latest recorded span table at or before `version` (`%{}` when none)."
  @spec spans_at(t(), Tamale.version()) :: %{Tamale.id() => span()}
  def spans_at(track, version) do
    track.spans_by_version
    |> Map.keys()
    |> Enum.filter(&(&1 <= version))
    |> Enum.max(fn -> nil end)
    |> case do
      nil -> %{}
      v -> Map.fetch!(track.spans_by_version, v)
    end
  end

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

  # ---- Transport ----

  @doc """
  Transport this track's patch anchors along its op log.

  Returns `{:ok, survivors, dead}`. Metric anchors require a warp provider;
  Ordinal and Relative anchors use Tamale's identity transport.
  """
  @spec transport_patches(t(), Tamale.Transport.warp_provider() | nil) ::
          {:ok, survivors :: [Coconut.Edit.Patch.t()], dead :: [term()]}
  def transport_patches(track, warp_provider \\ nil) do
    {survivors, dead} =
      Enum.reduce(track.patches, {[], []}, fn patch, {survivors, dead} ->
        case transport_one(patch, track.space, warp_provider) do
          {:ok, new_anchor} -> {[%{patch | anchor: new_anchor} | survivors], dead}
          result -> {survivors, [{patch, result} | dead]}
        end
      end)

    {:ok, Enum.reverse(survivors), Enum.reverse(dead)}
  end

  defp transport_one(patch, space, nil) do
    case patch.anchor do
      %Tamale.Anchor.Metric{} -> {:error, :warp_provider_required}
      anchor -> Tamale.Transport.transport(anchor, space)
    end
  end

  defp transport_one(patch, space, warp_provider) do
    case patch.anchor do
      %Tamale.Anchor.Metric{} ->
        Tamale.Transport.transport(patch.anchor, space, warp_provider)

      anchor ->
        Tamale.Transport.transport(anchor, space)
    end
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
        spans_by_version: spans_by_version,
        version_clock: truncate_clock(track.version_clock, oldest_live_version)
    }
  end

  # version_clock 与 span 表同规则裁剪：cut 以下保留最新一份作 baseline
  # （截断后存活 log entry 的 tempo 对组合仍要查它）。
  defp truncate_clock(clock, oldest_live_version) do
    kept = for {v, e} <- clock, v > oldest_live_version, into: %{}, do: {v, e}

    baseline =
      clock
      |> Enum.filter(fn {v, _} -> v <= oldest_live_version end)
      |> Enum.max_by(fn {v, _} -> v end, fn -> nil end)

    case baseline do
      nil -> kept
      {v, e} -> Map.put(kept, v, e)
    end
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
    # `:delete` tombstones remove the element; everything else is an
    # upsert — same convention as apply_span_deltas/2.
    by_id =
      Enum.reduce(elements, track.elements_by_id, fn
        {id, :delete}, acc ->
          Map.delete(acc, id)

        {id, data}, acc ->
          Map.put(acc, id, data)
      end)

    %{track | elements_by_id: by_id}
  end

  defp sync_spans(track, _new_version, span_changes) when map_size(span_changes) == 0,
    do: track

  defp sync_spans(track, new_version, span_changes),
    do: %{
      track
      | spans_by_version:
          Map.put(
            track.spans_by_version,
            new_version,
            track |> latest_spans() |> apply_span_deltas(span_changes)
          )
    }

  defp apply_span_deltas(prev, deltas) do
    {upserts, tombstones} = Enum.split_with(deltas, fn {_id, v} -> v != :delete end)

    result = Map.merge(prev, Map.new(upserts))

    Enum.reduce(tombstones, result, fn {id, :delete}, acc -> Map.delete(acc, id) end)
  end

  # Removes land before write-time transport; additions land after it (see
  # Workspace.apply_batch/5), so a batch never transports the patches it mints.
  defp drop_patches(track, []), do: track
  defp drop_patches(track, removes), do: %{track | patches: track.patches -- removes}

  defmodule TempoDerive do
    @moduledoc """
    Optional `:tempo_derive` capability: the tempo-map projection
    (`Coconut.Edit.Workspace.tempo_map/1`) plus the versioned exact step
    projection (`Coconut.Edit.Workspace.tempo_steps_at/2`, frame-warp tempo
    pairs). Sniffed via `Coconut.Edit.Track.supports?/2`; declaring this
    behaviour buys compile-time warnings but is not required.
    """

    @callback tempo_events(Coconut.Edit.Track.t()) :: [
                {Coconut.Score.Tick.numeric_tick(), Coconut.Score.Tempo.Event.t()}
              ]

    @doc """
    Exact tempo steps at a track version: `{start_tick, milli_bpm}` pairs
    sorted by tick, derived from the span snapshot at `version` and the
    current element table (bpm value edits are content edits — unversioned;
    documented limitation of the frame-warp tempo pair, design doc §5).
    """
    @callback tempo_steps_at(Coconut.Edit.Track.t(), Tamale.version()) :: [
                {Coconut.Score.Tick.numeric_tick(), pos_integer()}
              ]
  end
end
