defmodule Coconut.Edit.Workspace do
  @moduledoc """
  Aggregate for edit.

  The workspace is a single-writer serialisation point. Every track write
  goes through `apply_batch/5`, which atomically updates the track's Space,
  bumps the version, syncs the track's side tables, and transports the
  track's patches (write-time transport: survivors are persisted with
  up-to-date anchors, the dead move to the track's `dead_patches`).

  A workspace is `id / edit_version / tracks / tempo` plus the project-level
  `tpqn` / `time_sigs` (tick resolution and the bar-grid time signature
  events — neither participates in the op/transport machinery).
  Everything else lives on `Coconut.Edit.Track` (design doc §11.3). The tempo
  track is a dedicated field — exactly one per workspace, structurally —
  not an entry of `tracks` (design doc §6); track-id-keyed functions
  (`fetch_track/2`, `apply_batch/5`, …) route to it transparently.
  """

  alias Coconut.Edit.{Track, WarpProvider}
  alias Coconut.Score.{TempoMap, TimeSigMap}
  alias Coconut.Util.ID

  import Coconut.Util.Helpers, only: [normalize_attrs: 2, strictly_normalize_attrs: 2]

  @type t :: %__MODULE__{
          id: ID.t(t()),
          edit_version: Tamale.version(),
          tracks: %{Track.track_id() => Track.t()},
          tempo: Track.t(),
          tpqn: pos_integer(),
          time_sigs: [Coconut.Score.TimeSig.time_sig_event(), ...]
        }
  @keys [
    :id,
    :edit_version,
    tracks: %{},
    tempo: %Track{id: "tempo", module: Coconut.Edit.Track.Tempo},
    tpqn: 480,
    time_sigs: [{1, {4, 4}}]
  ]
  defstruct @keys

  @doc "Create a new workspace based on the attributes. `:id` must be provided explicitly."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs, @keys) do
      case Map.fetch(normalized, :id) do
        :error ->
          {:error, {:missing_id, "WSpc_"}}

        {:ok, id} ->
          struct(__MODULE__, Map.put(normalized, :id, id))
          |> validate()
      end
    end
  end

  # `update/2` rejects `time_sigs`: meter changes are a score gesture with
  # their own writer (`set_time_sigs/2`) so they can enter the undo history
  # (design doc §6 addendum, §12.4).
  @update_keys [:id, :edit_version, :tracks, :tempo, :tpqn]

  @doc """
  Modify the properties of an existing workspace.

  The `id` is immutable, and `time_sigs` is rejected here — use
  `set_time_sigs/2` for meter changes (design doc §6 addendum).
  """
  @spec update(t(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def update(ws, attrs) do
    with {:ok, normalized} <- strictly_normalize_attrs(attrs, @update_keys),
         :ok <- if(Map.has_key?(normalized, :id), do: {:error, :id_immutable}, else: :ok) do
      new_ws = struct(ws, normalized)
      validate(new_ws)
    end
  end

  @doc """
  Replace the bar-grid time signature events (design doc §6).

  This is the dedicated writer for meter changes — a score gesture that
  enters the undo history as a `{:set_time_sigs, events}` edge (§12.4);
  `update/2` no longer accepts `time_sigs`. Legality is the same rule as
  `validate/1`: first event at bar 1, bar numbers strictly ascending.
  """
  @spec set_time_sigs(t(), [Coconut.Score.TimeSig.time_sig_event()]) ::
          {:ok, t()} | {:error, {:invalid_time_sigs, term()}}
  def set_time_sigs(ws, events) do
    if valid_time_sigs?(events) do
      {:ok, %{ws | time_sigs: events}}
    else
      {:error, {:invalid_time_sigs, events}}
    end
  end

  # ---- Track structure ----

  @doc """
  Add a track to the workspace.

  The id must be fresh (colliding with the tempo track's id or an existing
  track is `{:track_id_taken, _}`), and the track module must not carry the
  `:tempo_derive` capability — the tempo field is unique (§6). Adding a
  track bumps `edit_version` (score-structure change, §12.4).
  """
  @spec add_track(t(), Track.t()) :: {:ok, t()} | {:error, term()}
  def add_track(ws, %Track{id: track_id} = track) do
    if track_id == ws.tempo.id or Map.has_key?(ws.tracks, track_id) do
      {:error, {:track_id_taken, track_id}}
    else
      validate(%{
        ws
        | tracks: Map.put(ws.tracks, track_id, track),
          edit_version: ws.edit_version + 1
      })
    end
  end

  @doc """
  Remove a track by id. The dedicated tempo track cannot be removed
  (`{:tempo_track_immutable, _}`). Removing a track bumps `edit_version`
  (score-structure change, §12.4).
  """
  @spec remove_track(t(), Track.track_id()) :: {:ok, t()} | {:error, term()}
  def remove_track(ws, track_id) do
    cond do
      track_id == ws.tempo.id ->
        {:error, {:tempo_track_immutable, track_id}}

      not Map.has_key?(ws.tracks, track_id) ->
        {:error, {:unknown_track, track_id}}

      true ->
        {:ok, %{ws | tracks: Map.delete(ws.tracks, track_id), edit_version: ws.edit_version + 1}}
    end
  end

  @doc """
  Rename a track. The name is a display annotation (§11.8): mutable,
  non-unique, nilable — nothing semantic keys off it. Renaming does not
  bump `edit_version` (render output is unaffected).
  """
  @spec rename_track(t(), Track.track_id(), String.t() | nil) ::
          {:ok, t()} | {:error, {:unknown_track, term()}}
  def rename_track(ws, track_id, name) do
    with {:ok, track} <- fetch_track(ws, track_id) do
      {:ok, put_track(ws, %{track | name: name})}
    end
  end

  # ---- Tracks ----

  defguardp in_tempo_track(ws, track_id)
            when is_struct(ws, __MODULE__) and is_struct(ws.tempo, Track) and
                   track_id == ws.tempo.id

  @doc "Fetches a track by id; the tempo track's id routes to the dedicated field."
  @spec fetch_track(t(), Track.track_id()) ::
          {:ok, Track.t()} | {:error, {:unknown_track, term()}}
  def fetch_track(ws, track_id) when in_tempo_track(ws, track_id), do: {:ok, ws.tempo}

  def fetch_track(%__MODULE__{tracks: tracks}, track_id) do
    case Map.fetch(tracks, track_id) do
      {:ok, track} -> {:ok, track}
      :error -> {:error, {:unknown_track, track_id}}
    end
  end

  @doc "All tracks as `{id, track}` pairs, tempo track first (fold order is not semantic)."
  @spec all_tracks(t()) :: [{Track.track_id(), Track.t()}]
  def all_tracks(ws), do: [{ws.tempo.id, ws.tempo} | Map.to_list(ws.tracks)]

  # Write-back counterpart of fetch_track/2's routing.
  defp put_track(ws, %{id: track_id} = track) when in_tempo_track(ws, track_id),
    do: %{ws | tempo: track}

  defp put_track(ws, %{id: track_id} = track),
    do: %{ws | tracks: Map.put(ws.tracks, track_id, track)}

  # ---- Apply ----

  @doc """
  Apply an op batch to a track, syncing side tables.

  `expected_version` is the optimistic-lock check: the caller must pass
  the workspace version it read before lowering. If the workspace has
  moved on, `{:error, :version_conflict}` is returned.

  `ops` and `side_changes` are the output of `Coconut.Edit.Operation.lower/3`.

  After the batch commits, the track's patches are transported along the
  fresh log entry and persisted (write-time transport; design doc §2 step
  4): survivors keep marching with up-to-date `at_version`, the dead
  (`{:undefined, _}` / `{:clip, _, _}` results) move to the track's
  `dead_patches`. `patches_add` from the same batch are minted at the
  new head and join afterwards, untransported.
  """
  @spec apply_batch(
          t(),
          Track.track_id(),
          expected_version :: Tamale.version(),
          [Tamale.Op.t()],
          Coconut.Edit.Operation.side_changes()
        ) :: {:ok, t()} | {:error, term()}
  def apply_batch(ws, track_id, expected_version, ops, side_changes) do
    with :ok <- check_version(ws, expected_version),
         {:ok, track} <- fetch_track(ws, track_id),
         {:ok, space} <- Tamale.Space.apply_batch(track.space, ops) do
      track = Track.sync(%{track | space: space}, space.version, side_changes)

      ws = %{ws | edit_version: ws.edit_version + 1}
      ws = put_track(ws, track)

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
  a no-op fold — it remains as the check-time safety net (`Coconut.Render.Resolve`)
  for patches mounted out-of-band.

  Dead patches are `{patch, result}` tuples — the caller decides whether to
  garbage-collect, notify, or retry.
  """
  @spec transport_patches(
          t(),
          Track.track_id(),
          warp_provider :: Tamale.Transport.warp_provider() | nil
        ) :: {:ok, survivors :: [Coconut.Edit.Patch.t()], dead :: [term()]}
  def transport_patches(ws, track_id, warp_provider \\ nil) do
    {:ok, track} = fetch_track(ws, track_id)

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
    {:ok, track} = fetch_track(ws, track_id)

    provider =
      WarpProvider.for_coord(Track.coord_domain(track), Track.spans(track), track.patches)

    {:ok, survivors, dead} = transport_patches(ws, track_id, provider)

    track = %{
      track
      | patches: survivors ++ patches_add,
        dead_patches: track.dead_patches ++ dead
    }

    put_track(ws, track)
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
  @spec truncate(t(), Track.track_id(), Tamale.version()) ::
          {:ok, t()} | {:error, {:unknown_track, term()}}
  def truncate(ws, track_id, oldest_live_version) do
    with {:ok, track} <- fetch_track(ws, track_id) do
      {:ok, put_track(ws, Track.truncate(track, oldest_live_version))}
    end
  end

  @doc """
  Returns the track's versioned span table, for `WarpProvider.for_coord/3`.
  """
  @spec track_spans(t(), Track.track_id()) :: %{
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
  @spec latest_spans(t(), Track.track_id()) :: %{Tamale.id() => Track.span()}
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
  @spec latest_span(t(), Track.track_id(), Tamale.id()) :: Track.span() | nil
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
  (supported Metric `coord`) is enforced by `Coconut.Edit.Patch.new/1`; an
  unknown `track_id` is rejected here (`{:error, {:unknown_track, _}}`) —
  with patches stored per track there is nowhere for an orphan to land.
  """
  @spec attach_patch(t(), Coconut.Edit.Patch.t()) ::
          {:ok, t()} | {:error, {:unknown_track, term()}}
  def attach_patch(ws, %Coconut.Edit.Patch{track_id: track_id} = patch) do
    with {:ok, track} <- fetch_track(ws, track_id) do
      patch = mint_patch_id(patch)
      track = %{track | patches: track.patches ++ [patch]}
      {:ok, put_track(ws, track)}
    end
  end

  # Patch ids are minted at the aggregate boundary: an absent id gets a
  # fresh `"Patch_"`-prefixed one at mount; explicit ids pass through.
  defp mint_patch_id(%Coconut.Edit.Patch{id: nil} = patch),
    do: %{patch | id: ID.generate_id("Patch_")}

  defp mint_patch_id(patch), do: patch

  @doc "Appends a list of patches. See `attach_patch/2`."
  @spec attach_patches(t(), [Coconut.Edit.Patch.t()]) ::
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
  @spec take_dead_patches(t()) :: {[{Coconut.Edit.Patch.t(), term()}], t()}
  def take_dead_patches(ws) do
    dead = Enum.flat_map(all_tracks(ws), fn {_id, track} -> track.dead_patches end)

    ws =
      Enum.reduce(all_tracks(ws), ws, fn {_id, track}, acc ->
        put_track(acc, %{track | dead_patches: []})
      end)

    {dead, ws}
  end

  @doc """
  Builds a compiled `TempoMap` from the tempo track (the dedicated `tempo`
  field), at the workspace's `tpqn`.

  A tempo track with no events yields `{:error, :no_tempo_track}` — engines
  apply their own fallback (see `Coconut.Render.Engine.Snapshot`).
  """
  @spec tempo_map(t()) :: {:ok, TempoMap.t()} | {:error, term()}
  def tempo_map(ws) do
    case ws.tempo.module.tempo_events(ws.tempo) do
      [] -> {:error, :no_tempo_track}
      events -> TempoMap.compile(events, tpqn: ws.tpqn)
    end
  end

  @doc """
  Elapsed physical time of a tick range (e.g. an editor selection) under
  the workspace's tempo track. Propagates `{:error, :no_tempo_track}`
  from `tempo_map/1` when the tempo track is empty — engines apply their
  own fallback.
  """
  @spec region_duration_sec(t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, float()} | {:error, term()}
  def region_duration_sec(ws, start_tick, end_tick)
      when is_integer(start_tick) and is_integer(end_tick) and start_tick >= 0 and end_tick >= 0 do
    with {:ok, tm} <- tempo_map(ws) do
      {:ok, TempoMap.duration_sec(tm, start_tick, end_tick)}
    end
  end

  @doc """
  Builds a compiled `TimeSigMap` from the workspace's `time_sigs` events,
  at the workspace's `tpqn`.

  Time signatures are display/grid data (bar ruler, snapping), not an
  editable track — they live outside the op/transport machinery, with
  the bar number as the authoritative coordinate (mid-song meter changes
  are ordinary list entries).
  """
  @spec time_sig_map(t()) :: {:ok, TimeSigMap.t()} | {:error, term()}
  def time_sig_map(ws) do
    TimeSigMap.compile(ws.time_sigs, tpqn: ws.tpqn)
  end

  # The tempo field is bound by capability, not module identity: any track
  # module with the `:tempo_derive` capability may type the tempo track.
  # The concrete choice lives here (composition root); the projection
  # lives on the module.
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%{tempo: tempo, time_sigs: time_sigs} = ws) do
    cond do
      not Track.supports?(tempo.module, :tempo_derive) ->
        {:error, {:invalid_tempo_track, tempo.module}}

      Map.has_key?(ws.tracks, tempo.id) ->
        {:error, {:tempo_id_collision, tempo.id}}

      Enum.any?(ws.tracks, fn {_id, track} -> Track.supports?(track.module, :tempo_derive) end) ->
        {:error, :tempo_track_in_tracks}

      not valid_time_sigs?(time_sigs) ->
        {:error, {:invalid_time_sigs, time_sigs}}

      true ->
        {:ok, ws}
    end
  end

  # The bar is the authoritative coordinate: the first event must sit at
  # bar 1, and bar numbers must be positive and strictly ascending.
  defp valid_time_sigs?([{1, _sig} | _] = events) do
    Enum.all?(events, &match?({bar, _sig} when is_integer(bar) and bar >= 1, &1)) and
      strictly_ascending?(Enum.map(events, &elem(&1, 0)))
  end

  defp valid_time_sigs?(_other), do: false

  defp strictly_ascending?(bars) do
    bars
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> b > a end)
  end
end
