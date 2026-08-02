defmodule Coconut.Workspace do
  @moduledoc """
  Aggregate for edit.

  The workspace is a single-writer serialisation point. Every track write
  goes through `apply_batch/5`, which atomically updates the Space, bumps
  the version, and syncs the side tables.
  """

  alias Coconut.Util.{ID, Model, Object}
  alias Coconut.Score.{Tempo, TempoMap}

  defmodule Side do
    @moduledoc """
    Contain raw data.
    """
    alias Coconut.Score.{TempoMap, Tick}

    @type span :: %{
            ID.t() => {start_tick :: Tick.numeric_tick(), end_tick :: Tick.numeric_tick()}
          }
    @type item :: term()

    @type t :: %__MODULE__{
            tempos_by_version: %{Tamale.version() => TempoMap.t()},
            spans_by_version: %{Coconut.Operate.track_id() => %{Tamale.version() => span()}},
            elements_by_id: %{Tamale.id() => item()},
            patches: [Coconut.Patch.t()]
          }
    # tempos_by_version is reserved for the variable-tempo plan: once tempo
    # changes are committed into the Space, versioned TempoMap snapshots will
    # be written here to anchor transport across tempo edits. Nothing writes
    # it yet — `Workspace.tempo_map/2` compiles on demand from latest spans.
    use Object,
      keys: [tempos_by_version: %{}, spans_by_version: %{}, elements_by_id: %{}, patches: []]
  end

  @type t :: %__MODULE__{
          id: ID.t(t()),
          edit_version: Tamale.version(),
          tempo_space: Tamale.Space.t() | nil,
          tracks: %{ID.t() => Tamale.Space.t()},
          side: Side.t()
        }
  use Model,
    keys: [:id, :edit_version, :tempo_space, :tracks, :side],
    id_prefix: "WSpc_"

  # ---- Apply ----

  @doc """
  Apply an op batch to a track, syncing side tables.

  `expected_version` is the optimistic-lock check: the caller must pass
  the workspace version it read before lowering. If the workspace has
  moved on, `{:error, :version_conflict}` is returned.

  `ops` and `side_changes` are the output of `Coconut.Operate.lower/3`.
  """
  @spec apply_batch(
          t(),
          Coconut.Operate.track_id(),
          expected_version :: Tamale.version(),
          [Tamale.Op.t()],
          Coconut.Operate.side_changes()
        ) :: {:ok, t()} | {:error, term()}
  def apply_batch(ws, :tempo, expected_version, ops, side_changes) do
    with :ok <- check_version(ws, expected_version),
         %Tamale.Space{} = space <- ws.tempo_space,
         {:ok, space} <- Tamale.Space.apply_batch(space, ops),
         side <- sync_side(ws.side, :tempo, space.version, side_changes) do
      {:ok,
       %{
         ws
         | tempo_space: space,
           side: side,
           edit_version: ws.edit_version + 1
       }}
    else
      nil -> {:error, :no_tempo_track}
      {:error, _} = err -> err
    end
  end

  def apply_batch(ws, track_id, expected_version, ops, side_changes) do
    with :ok <- check_version(ws, expected_version),
         {:ok, space} <- Map.fetch(ws.tracks, track_id),
         {:ok, space} <- Tamale.Space.apply_batch(space, ops),
         side <- sync_side(ws.side, track_id, space.version, side_changes) do
      {:ok,
       %{
         ws
         | tracks: Map.put(ws.tracks, track_id, space),
           side: side,
           edit_version: ws.edit_version + 1
       }}
    else
      :error -> {:error, {:unknown_track, track_id}}
      {:error, _} = err -> err
    end
  end

  # ---- Transport ----

  @doc """
  Transport every patch's anchor along the track's op log.

  Returns `{:ok, survivors, dead}` where survivors have updated anchors.
  `warp_provider` is required for `Tamale.Anchor.Metric` patches; pass `nil`
  for Ordinal/Relative-only v1.

  Dead patches are `{patch, result}` tuples — the caller decides whether to
  garbage-collect, notify, or retry.
  """
  @spec transport_patches(
          t(),
          Coconut.Operate.track_id(),
          warp_provider :: Tamale.Transport.warp_provider() | nil
        ) :: {:ok, survivors :: [Coconut.Patch.t()], dead :: [term()]}
  def transport_patches(ws, track_id, warp_provider \\ nil)

  def transport_patches(ws, :tempo, warp_provider) do
    space = ws.tempo_space || raise "no tempo track"

    {survivors, dead} =
      Enum.reduce(ws.side.patches, {[], []}, fn cp, {surv, dead} ->
        if cp.track_id == :tempo do
          case transport_one(cp, space, warp_provider) do
            {:ok, new_anchor} -> {[%{cp | anchor: new_anchor} | surv], dead}
            result -> {surv, [{cp, result} | dead]}
          end
        else
          {[cp | surv], dead}
        end
      end)

    {:ok, Enum.reverse(survivors), Enum.reverse(dead)}
  end

  def transport_patches(ws, track_id, warp_provider) do
    space = Map.fetch!(ws.tracks, track_id)

    {survivors, dead} =
      Enum.reduce(ws.side.patches, {[], []}, fn cp, {surv, dead} ->
        if cp.track_id == track_id do
          case transport_one(cp, space, warp_provider) do
            {:ok, new_anchor} -> {[%{cp | anchor: new_anchor} | surv], dead}
            result -> {surv, [{cp, result} | dead]}
          end
        else
          {[cp | surv], dead}
        end
      end)

    {:ok, Enum.reverse(survivors), Enum.reverse(dead)}
  end

  # ---- Side sync (private) ----

  defp sync_side(side, track_id, new_version, changes) do
    side
    |> sync_elements(changes.elements)
    |> sync_spans(track_id, new_version, changes.span_snapshot)
    |> sync_patches(changes.patches_add, changes.patches_remove)
  end

  defp sync_elements(side, elements) when map_size(elements) == 0, do: side

  defp sync_elements(side, elements) do
    # `:delete` tombstones remove the element; `:touch` / `:pending` are
    # markers only (no data change) — same convention as apply_span_deltas/2.
    Enum.reduce(elements, side, fn
      {id, :delete}, acc ->
        %{acc | elements_by_id: Map.delete(acc.elements_by_id, id)}

      {_id, marker}, acc when marker in [:touch, :pending] ->
        acc

      {id, data}, acc ->
        %{acc | elements_by_id: Map.put(acc.elements_by_id, id, data)}
    end)
  end

  defp sync_spans(side, _track_id, _new_version, span_changes) when map_size(span_changes) == 0,
    do: side

  defp sync_spans(side, track_id, new_version, span_changes) do
    track_spans = Map.get(side.spans_by_version, track_id, %{})
    prev = latest_spans(track_spans)
    new = apply_span_deltas(prev, span_changes)

    %{
      side
      | spans_by_version:
          Map.put(side.spans_by_version, track_id, Map.put(track_spans, new_version, new))
    }
  end

  defp latest_spans(track_spans) do
    case Enum.max(Map.keys(track_spans), fn -> nil end) do
      nil -> %{}
      v -> Map.get(track_spans, v, %{})
    end
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

  defp sync_patches(side, adds, removes) do
    cond do
      adds == [] and removes == [] -> side
      true -> %{side | patches: (side.patches ++ adds) -- removes}
    end
  end

  # ---- Transport helpers ----

  # Ordinal & Relative travel by identity (transport/2).
  # Metric travels by warp (transport/3). Dispatch on anchor type.
  defp transport_one(cp, space, nil) do
    case cp.anchor do
      %Tamale.Anchor.Metric{} -> {:error, :warp_provider_required}
      anchor -> Tamale.Transport.transport(anchor, space)
    end
  end

  defp transport_one(cp, space, warp_provider) do
    case cp.anchor do
      %Tamale.Anchor.Metric{} ->
        Tamale.Transport.transport(cp.anchor, space, warp_provider)

      anchor ->
        Tamale.Transport.transport(anchor, space)
    end
  end

  # ---- Other helpers ----

  defp check_version(ws, expected) do
    if ws.edit_version == expected do
      :ok
    else
      {:error, {:version_conflict, expected: expected, actual: ws.edit_version}}
    end
  end

  @doc """
  Returns the span table for a specific track, for passing to `WarpProvider.tick/2`.
  """
  @spec track_spans(t(), Coconut.Operate.track_id()) :: %{
          Tamale.version() => %{Tamale.id() => {non_neg_integer(), non_neg_integer()}}
        }
  def track_spans(ws, track_id) do
    Map.get(ws.side.spans_by_version, track_id, %{})
  end

  @doc """
  Returns the latest recorded span table for a track.

  "Latest recorded" means the newest version that actually has a snapshot —
  Move-only batches write no span snapshot, so this may lag behind the
  Space's head version. Prefer this over reading `spans_by_version` at
  `space.version` directly.
  """
  @spec latest_spans(t(), Coconut.Operate.track_id()) :: %{
          Tamale.id() => {non_neg_integer(), non_neg_integer()}
        }
  def latest_spans(ws, track_id) do
    ws |> track_spans(track_id) |> latest_spans()
  end

  @doc """
  Returns the latest recorded span for a single element, or `nil`.
  See `latest_spans/2`.
  """
  @spec latest_span(t(), Coconut.Operate.track_id(), Tamale.id()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def latest_span(ws, track_id, id) do
    ws |> latest_spans(track_id) |> Map.get(id)
  end

  @doc """
  Appends a patch to the side table.

  No validation is performed at this point: construction-time legality
  (supported Metric `coord`) is enforced by `Coconut.Patch.new/1`, and
  unknown tracks surface as check entries in `Coconut.Resolve.run_check/3`.
  """
  @spec attach_patch(t(), Coconut.Patch.t()) :: t()
  def attach_patch(ws, %Coconut.Patch{} = patch) do
    %{ws | side: %{ws.side | patches: ws.side.patches ++ [patch]}}
  end

  @doc "Appends a list of patches. See `attach_patch/2`."
  @spec attach_patches(t(), [Coconut.Patch.t()]) :: t()
  def attach_patches(ws, patches) when is_list(patches) do
    %{ws | side: %{ws.side | patches: ws.side.patches ++ patches}}
  end

  @doc """
  Builds a compiled `TempoMap` from the current tempo Space.
  """
  @spec tempo_map(t(), keyword()) :: {:ok, TempoMap.t()} | {:error, term()}
  def tempo_map(ws, opts \\ []) do
    case ws.tempo_space do
      nil ->
        {:error, :no_tempo_track}

      space ->
        latest = latest_spans(ws, :tempo)
        elements = ws.side.elements_by_id

        # Collect every live event. Move only permutes ids — spans are
        # untouched — so ordering must never silently drop events here;
        # RecordMap sorts by position and rejects pathological input loudly.
        events =
          space.ids
          |> Enum.flat_map(fn id ->
            case Map.get(latest, id) do
              {start, _end_tick} ->
                bpm_milli = Map.get(elements, id, %{}) |> Map.get(:bpm)

                event =
                  {start, %Tempo.Event{module: Tempo.Step, context: %{bpm: bpm_milli / 1000}}}

                [event]

              _ ->
                []
            end
          end)

        tpqn = Keyword.get(opts, :tpqn, 480)
        TempoMap.compile(events, tpqn: tpqn)
    end
  end
end
