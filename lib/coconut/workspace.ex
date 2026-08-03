defmodule Coconut.Workspace do
  @moduledoc """
  Aggregate for edit.

  The workspace is a single-writer serialisation point. Every track write
  goes through `apply_batch/5`, which atomically updates the track's Space,
  bumps the version, syncs the track's side tables, and transports the
  track's patches (write-time transport: survivors are persisted with
  up-to-date anchors, the dead move to the track's `dead_patches`).

  A workspace is just `id / edit_version / tracks` — everything else lives
  on `Coconut.Track` (design doc §11.3). The tempo track is an ordinary
  track, identified by its module `Coconut.Track.Tempo`.
  """

  alias Coconut.{Track, Util.ID, Util.Model, WarpProvider}
  alias Coconut.Score.{Tempo, TempoMap}

  @type t :: %__MODULE__{
          id: ID.t(t()),
          edit_version: Tamale.version(),
          tracks: %{Coconut.Operate.track_id() => Track.t()}
        }
  use Model,
    keys: [:id, :edit_version, tracks: %{}],
    id_prefix: "WSpc_"

  # ---- Tracks ----

  @doc "Fetches a track by id."
  @spec fetch_track(t(), Coconut.Operate.track_id()) ::
          {:ok, Track.t()} | {:error, {:unknown_track, term()}}
  def fetch_track(ws, track_id) do
    case Map.fetch(ws.tracks, track_id) do
      {:ok, track} -> {:ok, track}
      :error -> {:error, {:unknown_track, track_id}}
    end
  end

  # ---- Apply ----

  @doc """
  Apply an op batch to a track, syncing side tables.

  `expected_version` is the optimistic-lock check: the caller must pass
  the workspace version it read before lowering. If the workspace has
  moved on, `{:error, :version_conflict}` is returned.

  `ops` and `side_changes` are the output of `Coconut.Operate.lower/3`.

  After the batch commits, the track's patches are transported along the
  fresh log entry and persisted (write-time transport; design doc §2 step
  4): survivors keep marching with up-to-date `at_version`, the dead
  (`{:undefined, _}` / `{:clip, _, _}` results) move to the track's
  `dead_patches`. `patches_add` from the same batch are minted at the
  new head and join afterwards, untransported.
  """
  @spec apply_batch(
          t(),
          Coconut.Operate.track_id(),
          expected_version :: Tamale.version(),
          [Tamale.Op.t()],
          Coconut.Operate.side_changes()
        ) :: {:ok, t()} | {:error, term()}
  def apply_batch(ws, track_id, expected_version, ops, side_changes) do
    with :ok <- check_version(ws, expected_version),
         {:ok, track} <- fetch_track(ws, track_id),
         {:ok, space} <- Tamale.Space.apply_batch(track.space, ops) do
      track = Track.sync(%{track | space: space}, space.version, side_changes)

      ws = %{
        ws
        | tracks: Map.put(ws.tracks, track_id, track),
          edit_version: ws.edit_version + 1
      }

      {:ok, transport_track_patches(ws, track_id, side_changes.patches_add)}
    end
  end

  # ---- Transport ----

  @doc """
  Transport a track's patch anchors along its op log.

  Returns `{:ok, survivors, dead}` where survivors have updated anchors.
  `warp_provider` is required for `Tamale.Anchor.Metric` patches; pass `nil`
  for Ordinal/Relative-only v1.

  `apply_batch/5` already transports at write time and persists the
  results, so calling this on a workspace whose patches all sit at head is
  a no-op fold — it remains as the check-time safety net (`Coconut.Resolve`)
  for patches mounted out-of-band.

  Dead patches are `{patch, result}` tuples — the caller decides whether to
  garbage-collect, notify, or retry.
  """
  @spec transport_patches(
          t(),
          Coconut.Operate.track_id(),
          warp_provider :: Tamale.Transport.warp_provider() | nil
        ) :: {:ok, survivors :: [Coconut.Patch.t()], dead :: [term()]}
  def transport_patches(ws, track_id, warp_provider \\ nil) do
    track = Map.fetch!(ws.tracks, track_id)

    {survivors, dead} =
      Enum.reduce(track.patches, {[], []}, fn cp, {surv, dead} ->
        case transport_one(cp, track.space, warp_provider) do
          {:ok, new_anchor} -> {[%{cp | anchor: new_anchor} | surv], dead}
          result -> {surv, [{cp, result} | dead]}
        end
      end)

    {:ok, Enum.reverse(survivors), Enum.reverse(dead)}
  end

  # Write-time transport (design doc §2 flow step 4). Runs inside
  # apply_batch on the post-sync workspace: the track's surviving patches
  # are persisted with anchors at the new head, the dead are moved to the
  # graveyard, and this batch's own `patches_add` join untouched.
  defp transport_track_patches(ws, track_id, patches_add) do
    track = Map.fetch!(ws.tracks, track_id)
    provider = WarpProvider.tick(Track.spans(track), track.patches)
    {:ok, survivors, dead} = transport_patches(ws, track_id, provider)

    track = %{
      track
      | patches: survivors ++ patches_add,
        dead_patches: track.dead_patches ++ dead
    }

    %{ws | tracks: Map.put(ws.tracks, track_id, track)}
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
  Truncate a track's history below `oldest_live_version`, cutting both the
  op log and the old span snapshots (design doc §11.3 — the "synchronous
  pruning" that keeps `spans_by_version` bounded).
  """
  @spec truncate(t(), Coconut.Operate.track_id(), Tamale.version()) ::
          {:ok, t()} | {:error, {:unknown_track, term()}}
  def truncate(ws, track_id, oldest_live_version) do
    with {:ok, track} <- fetch_track(ws, track_id) do
      {:ok,
       %{ws | tracks: Map.put(ws.tracks, track_id, Track.truncate(track, oldest_live_version))}}
    end
  end

  @doc """
  Returns the track's versioned span table, for `WarpProvider.tick/2`.
  """
  @spec track_spans(t(), Coconut.Operate.track_id()) :: %{
          Tamale.version() => %{Tamale.id() => Track.span()}
        }
  def track_spans(ws, track_id) do
    case fetch_track(ws, track_id) do
      {:ok, track} -> Track.spans(track)
      {:error, _} -> %{}
    end
  end

  @doc """
  Returns the track's latest recorded span table. See `Track.latest_spans/1`.
  """
  @spec latest_spans(t(), Coconut.Operate.track_id()) :: %{Tamale.id() => Track.span()}
  def latest_spans(ws, track_id) do
    case fetch_track(ws, track_id) do
      {:ok, track} -> Track.latest_spans(track)
      {:error, _} -> %{}
    end
  end

  @doc """
  Returns the latest recorded span for a single element, or `nil`.
  See `Track.latest_span/2`.
  """
  @spec latest_span(t(), Coconut.Operate.track_id(), Tamale.id()) :: Track.span() | nil
  def latest_span(ws, track_id, id) do
    case fetch_track(ws, track_id) do
      {:ok, track} -> Track.latest_span(track, id)
      {:error, _} -> nil
    end
  end

  @doc """
  Appends a patch to its track.

  Mount anchors at the track's current head version; every later
  `apply_batch/5` transports them forward. Construction-time legality
  (supported Metric `coord`) is enforced by `Coconut.Patch.new/1`; an
  unknown `track_id` is rejected here (`{:error, {:unknown_track, _}}`) —
  with patches stored per track there is nowhere for an orphan to land.
  """
  @spec attach_patch(t(), Coconut.Patch.t()) ::
          {:ok, t()} | {:error, {:unknown_track, term()}}
  def attach_patch(ws, %Coconut.Patch{track_id: track_id} = patch) do
    with {:ok, track} <- fetch_track(ws, track_id) do
      track = %{track | patches: track.patches ++ [patch]}
      {:ok, %{ws | tracks: Map.put(ws.tracks, track_id, track)}}
    end
  end

  @doc "Appends a list of patches. See `attach_patch/2`."
  @spec attach_patches(t(), [Coconut.Patch.t()]) ::
          {:ok, t()} | {:error, {:unknown_track, term()}}
  def attach_patches(ws, patches) when is_list(patches) do
    Enum.reduce_while(patches, {:ok, ws}, fn patch, {:ok, ws} ->
      case attach_patch(ws, patch) do
        {:ok, ws} -> {:cont, {:ok, ws}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  Returns the accumulated dead patches (`{patch, reason}` tuples) across
  all tracks and clears the graveyards. The policy layer decides re-mount
  or discard (design doc §6: 锚判死由策略层重挂).
  """
  @spec take_dead_patches(t()) :: {[{Coconut.Patch.t(), term()}], t()}
  def take_dead_patches(ws) do
    dead = Enum.flat_map(ws.tracks, fn {_id, track} -> track.dead_patches end)
    tracks = Map.new(ws.tracks, fn {id, track} -> {id, %{track | dead_patches: []}} end)
    {dead, %{ws | tracks: tracks}}
  end

  @doc """
  Builds a compiled `TempoMap` from the tempo track (the track whose
  module is `Coconut.Track.Tempo`).
  """
  @spec tempo_map(t(), keyword()) :: {:ok, TempoMap.t()} | {:error, term()}
  def tempo_map(ws, opts \\ []) do
    case Enum.find(ws.tracks, fn {_id, track} -> track.module == Coconut.Track.Tempo end) do
      nil ->
        {:error, :no_tempo_track}

      {_id, track} ->
        events =
          track.module.view(track)
          |> Enum.map(fn {_id, element, {start, _end}} ->
            {start, %Tempo.Event{module: Tempo.Step, context: %{bpm: element.bpm / 1000}}}
          end)

        tpqn = Keyword.get(opts, :tpqn, 480)
        TempoMap.compile(events, tpqn: tpqn)
    end
  end
end
