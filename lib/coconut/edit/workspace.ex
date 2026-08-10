defmodule Coconut.Edit.Workspace do
  @moduledoc """
  Aggregate for edit.

  The workspace is a single-writer serialisation point. Every track write
  goes through `apply_batch/5`, which atomically updates the track's Space,
  bumps the version, syncs the track's side tables, and transports the
  track's patches (write-time transport: survivors are persisted with
  up-to-date anchors, the dead move to the track's `dead_patches`).

  A workspace is `id / edit_version / tracks / globals` plus the project-level
  `tpqn` / `time_sigs` (tick resolution and the bar-grid time signature
  events — neither participates in the op/transport machinery).
  Everything else lives on `Coconut.Edit.Track` (design doc §11.3). Global
  tracks (the tempo track is the built-in one) live in the `globals` map,
  not in `tracks` (design doc §6); their ids carry the `"global:"` prefix
  (the tempo track is `"global:tempo"`), so track-id-keyed functions
  (`fetch_track/2`, `apply_batch/5`, …) route to the right map purely by id.
  """

  alias Coconut.Edit.{Track, WarpProvider}
  alias Coconut.Score.{TempoMap, TimeSig, TimeSigMap}
  alias Coconut.Util.ID

  import Coconut.Util.Helpers, only: [normalize_attrs: 2, strictly_normalize_attrs: 2]

  # Global tracks are addressed purely by id: the `"global:"` prefix is the
  # routing rule, so the `globals` / `tracks` namespaces are disjoint by
  # construction. The tempo track is the one built-in global.
  @global_prefix "global:"
  @tempo_global_id @global_prefix <> "tempo"

  @type t :: %__MODULE__{
          id: ID.t(t()),
          edit_version: Tamale.version(),
          tracks: %{Track.track_id() => Track.t()},
          globals: %{Track.track_id() => Track.t()},
          tpqn: pos_integer(),
          time_sigs: [Coconut.Score.TimeSig.time_sig_event(), ...]
        }
  @keys [
    :id,
    :edit_version,
    tracks: %{},
    globals: %{@tempo_global_id => %Track{id: @tempo_global_id, module: Coconut.Edit.Track.Tempo}},
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
  @update_keys [:id, :edit_version, :tracks, :globals, :tpqn]

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
  `validate/1`: every signature must pass `Coconut.Score.TimeSig.validate/1`,
  first event at bar 1, bar numbers strictly ascending.

  `edit_version` is deliberately NOT bumped: the bar grid is display data —
  `Coconut.Render.Engine.Snapshot` does not carry `time_sigs`, so no render
  input can go stale (same rationale as `rename_track/3`, §12.4). If a
  future consumer (bar-domain anchors, tempo derivation) reads the meter,
  revisit this.
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

  The id must be fresh and outside the reserved `"global:"` namespace
  (`{:global_id_reserved, _}` / `{:track_id_taken, _}`), and the track
  module must not carry the `:tempo_derive` capability — global tracks
  live in `globals` (§6). Adding a track bumps `edit_version`
  (score-structure change, §12.4).
  """
  @spec add_track(t(), Track.t()) :: {:ok, t()} | {:error, term()}
  def add_track(ws, %Track{id: track_id} = track) do
    cond do
      global_id?(track_id) ->
        {:error, {:global_id_reserved, track_id}}

      Map.has_key?(ws.tracks, track_id) ->
        {:error, {:track_id_taken, track_id}}

      true ->
        validate(%{
          ws
          | tracks: Map.put(ws.tracks, track_id, track),
            edit_version: ws.edit_version + 1
        })
    end
  end

  @doc """
  Remove a track by id. Global tracks cannot be removed
  (`{:global_track_immutable, _}`). Removing a track bumps `edit_version`
  (score-structure change, §12.4).
  """
  @spec remove_track(t(), Track.track_id()) :: {:ok, t()} | {:error, term()}
  def remove_track(ws, track_id) do
    cond do
      global_id?(track_id) and Map.has_key?(ws.globals, track_id) ->
        {:error, {:global_track_immutable, track_id}}

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

  defp global_id?(track_id),
    do: is_binary(track_id) and String.starts_with?(track_id, @global_prefix)

  @doc "Fetches a track by id; `\"global:\"`-prefixed ids route to `globals`."
  @spec fetch_track(t(), Track.track_id()) ::
          {:ok, Track.t()} | {:error, {:unknown_track, term()}}
  def fetch_track(%__MODULE__{globals: globals}, "global:" <> _ = track_id),
    do: fetch_from(globals, track_id)

  def fetch_track(%__MODULE__{tracks: tracks}, track_id),
    do: fetch_from(tracks, track_id)

  defp fetch_from(map, track_id) do
    case Map.fetch(map, track_id) do
      {:ok, track} -> {:ok, track}
      :error -> {:error, {:unknown_track, track_id}}
    end
  end

  @doc "All tracks as `{id, track}` pairs, globals first (fold order is not semantic)."
  @spec all_tracks(t()) :: [{Track.track_id(), Track.t()}]
  def all_tracks(ws), do: Map.to_list(ws.globals) ++ Map.to_list(ws.tracks)

  # Write-back counterpart of fetch_track/2's routing.
  defp put_track(ws, %{id: "global:" <> _} = track),
    do: %{ws | globals: Map.put(ws.globals, track.id, track)}

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
  Appends a patch to its track, returning the post-mint patch.

  Mount anchors at the track's current head version; every later
  `apply_batch/5` transports them forward. Construction-time legality
  (supported Metric `coord`) is enforced by `Coconut.Edit.Patch.new/1`; an
  unknown `track_id` is rejected here (`{:error, {:unknown_track, _}}`) —
  with patches stored per track there is nowhere for an orphan to land.
  A Metric anchor whose `coord` differs from the track's `coord_domain`
  is rejected as well (`{:error, {:anchor_coord_mismatch, _, _}}`, design
  doc §5): it would otherwise mount fine and only die as
  `:warp_provider_required` at transport time.

  Returns `{:ok, workspace, patch}` where `patch` is the mounted patch
  after id minting — the recordable form (design doc §12.4).
  """
  @spec attach_patch(t(), Coconut.Edit.Patch.t()) ::
          {:ok, t(), Coconut.Edit.Patch.t()} | {:error, term()}
  def attach_patch(ws, %Coconut.Edit.Patch{track_id: track_id} = patch) do
    with {:ok, track} <- fetch_track(ws, track_id),
         :ok <- check_anchor_domain(patch, track) do
      patch = mint_patch_id(patch)
      track = %{track | patches: track.patches ++ [patch]}
      {:ok, put_track(ws, track), patch}
    end
  end

  # Patch ids are minted at the aggregate boundary: an absent id gets a
  # fresh `"Patch_"`-prefixed one at mount; explicit ids pass through.
  defp mint_patch_id(%Coconut.Edit.Patch{id: nil} = patch),
    do: %{patch | id: ID.generate_id("Patch_")}

  defp mint_patch_id(patch), do: patch

  # Anchor coord vs track domain consistency (design doc §5 todo, landed with
  # `Track.Audio`): a Metric anchor's coord must equal the track's
  # coord_domain. Ordinal/Relative anchors are coord-free and always pass.
  defp check_anchor_domain(
         %Coconut.Edit.Patch{anchor: %Tamale.Anchor.Metric{coord: coord}},
         track
       ) do
    if coord == Track.coord_domain(track) do
      :ok
    else
      {:error, {:anchor_coord_mismatch, coord, Track.coord_domain(track)}}
    end
  end

  defp check_anchor_domain(_patch, _track), do: :ok

  @doc """
  Appends a list of patches. See `attach_patch/2`.

  Returns `{:ok, workspace, minted}` with the mounted patches in input
  order, post-mint.
  """
  @spec attach_patches(t(), [Coconut.Edit.Patch.t()]) ::
          {:ok, t(), [Coconut.Edit.Patch.t()]} | {:error, term()}
  def attach_patches(ws, patches) when is_list(patches) do
    patches
    |> Enum.reduce_while({:ok, ws, []}, fn patch, {:ok, ws, minted} ->
      case attach_patch(ws, patch) do
        {:ok, ws, patch} -> {:cont, {:ok, ws, [patch | minted]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> then(fn
      {:ok, ws, minted} -> {:ok, ws, Enum.reverse(minted)}
      err -> err
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
  Builds a compiled `TempoMap` from the tempo global track
  (`"global:tempo"` in `globals`), at the workspace's `tpqn`.

  A missing or empty tempo track yields `{:error, :no_tempo_track}` —
  engines apply their own fallback (see `Coconut.Render.Engine.Snapshot`).
  """
  @spec tempo_map(t()) :: {:ok, TempoMap.t()} | {:error, term()}
  def tempo_map(ws) do
    with %Track{} = tempo <- Map.get(ws.globals, @tempo_global_id),
         [_ | _] = events <- tempo.module.tempo_events(tempo) do
      TempoMap.compile(events, tpqn: ws.tpqn)
    else
      _ -> {:error, :no_tempo_track}
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

  # The tempo slot (`"global:tempo"`) is bound by capability, not module
  # identity: any track module with the `:tempo_derive` capability may
  # occupy it. The concrete choice lives here (composition root); the
  # projection lives on the module.
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = ws) do
    with :ok <- check_globals(ws.globals),
         :ok <- check_tracks(ws.tracks),
         :ok <- check_tempo_global(ws.globals),
         :ok <- check_time_sigs(ws.time_sigs) do
      {:ok, ws}
    end
  end

  # Every `globals` key must carry the prefix and equal its track's id.
  defp check_globals(globals) do
    case Enum.find(globals, fn {id, track} -> not global_id?(id) or id != track.id end) do
      nil -> :ok
      {id, track} -> {:error, {:invalid_global_track, id, track.id}}
    end
  end

  # The `"global:"` namespace is reserved for `globals`; a tempo-capable
  # module among the regular tracks would compete with the tempo global (§6).
  defp check_tracks(tracks) do
    case Enum.find(tracks, fn {id, _track} -> global_id?(id) end) do
      {id, _track} -> {:error, {:global_id_reserved, id}}
      nil -> check_track_modules(tracks)
    end
  end

  defp check_track_modules(tracks) do
    if Enum.any?(tracks, fn {_id, track} -> Track.supports?(track.module, :tempo_derive) end),
      do: {:error, :tempo_track_in_tracks},
      else: :ok
  end

  # The tempo slot may be absent (`tempo_map/1` then reports
  # `:no_tempo_track`); when present its module must derive tempo.
  defp check_tempo_global(globals) do
    case Map.get(globals, @tempo_global_id) do
      nil ->
        :ok

      %Track{module: module} ->
        if Track.supports?(module, :tempo_derive),
          do: :ok,
          else: {:error, {:invalid_tempo_track, module}}
    end
  end

  defp check_time_sigs(time_sigs) do
    if valid_time_sigs?(time_sigs),
      do: :ok,
      else: {:error, {:invalid_time_sigs, time_sigs}}
  end

  # The bar is the authoritative coordinate: the first event must sit at
  # bar 1, and bar numbers must be positive and strictly ascending. Each
  # signature's own shape is delegated to `TimeSig.validate/1`.
  defp valid_time_sigs?([{1, _sig} | _] = events) do
    Enum.all?(events, &match?({bar, _sig} when is_integer(bar) and bar >= 1, &1)) and
      Enum.all?(events, fn {_bar, sig} -> TimeSig.validate(sig) == :ok end) and
      strictly_ascending?(Enum.map(events, &elem(&1, 0)))
  end

  defp valid_time_sigs?(_other), do: false

  defp strictly_ascending?(bars) do
    bars
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> b > a end)
  end
end
