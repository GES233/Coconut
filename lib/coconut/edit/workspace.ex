defmodule Coconut.Edit.Workspace do
  @moduledoc """
  Aggregate for edit.

  The workspace is a single-writer serialisation point. Every track write
  goes through `apply_batch/5`, which atomically updates the track's Space,
  bumps the version, syncs the track's side tables, and transports the
  track's patches (write-time transport: survivors are persisted with
  up-to-date anchors, the dead move to the track's `dead_patches`).

  A workspace is `id / edit_version / tracks / globals` plus the project-level
  `tpqn` / `frame_rate` / `time_sigs` (tick resolution; the engine frame-grid
  declaration — stored, never interpreted, but consulted by frame warps;
  the bar-grid time signature events).
  Everything else lives on `Coconut.Edit.Track` (design doc §11.3). Global
  tracks (the tempo track is the built-in one) live in the `globals` map,
  not in `tracks` (design doc §6); their ids carry the `"global:"` prefix
  (the tempo track is `"global:tempo"`), so track-id-keyed functions
  (`fetch_track/2`, `apply_batch/5`, …) route to the right map purely by id.
  """

  alias Coconut.Edit.{Track, WarpProvider}
  alias Coconut.Score.{TempoMap, TimeSig, TimeSigMap}
  alias Coconut.Util.ID
  alias Tamale.Warp

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
          frame_rate: Tamale.Coord.input() | nil,
          time_sigs: [Coconut.Score.TimeSig.time_sig_event(), ...]
        }
  @keys [
    :id,
    edit_version: 0,
    tracks: %{},
    globals: %{@tempo_global_id => %Track{id: @tempo_global_id, module: Coconut.Edit.Track.Tempo}},
    tpqn: 480,
    frame_rate: nil,
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
  @update_keys [:id, :edit_version, :tracks, :globals, :tpqn, :frame_rate]

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

  @doc """
  整体替换轨道展示 metadata。该字段不影响渲染，不递增 `edit_version`；调用方
  需要 merge 时应先显式构造完整新 map，使 History record 保持确定的完整值。
  """
  @spec put_track_metadata(t(), Track.track_id(), map()) :: {:ok, t()} | {:error, term()}
  def put_track_metadata(ws, track_id, metadata) do
    with {:ok, track} <- fetch_track(ws, track_id),
         updated = %{track | metadata: metadata},
         :ok <- Track.validate_state(updated) do
      {:ok, put_track(ws, updated)}
    end
  end

  @doc """
  整体替换轨道宿主扩展 extras。extras 可能被宿主投影为合成输入，因此递增
  `edit_version`，使已检查请求和渲染缓存不会继续复用旧工程事实。
  """
  @spec put_track_extras(t(), Track.track_id(), map()) :: {:ok, t()} | {:error, term()}
  def put_track_extras(ws, track_id, extras) do
    with {:ok, track} <- fetch_track(ws, track_id),
         updated = %{track | extras: extras},
         :ok <- Track.validate_state(updated) do
      {:ok, put_track(%{ws | edit_version: ws.edit_version + 1}, updated)}
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
  Apply already-lowered op batches to one or more tracks atomically, syncing
  side tables.

  This is a low-level adapter/replay boundary and does not run gesture policy.
  Host applications should use `Coconut.Edit.History.apply/4`, which validates
  and lowers the request first. Whole-track invariants are still checked here
  before a commit is accepted.

  `batches` is a list of `{track_id, ops, side_changes}` — the output of
  `Coconut.Edit.Operation.lower_batches/3` (single-track gestures yield a
  one-element list). `expected_version` is the optimistic-lock check: the
  caller must pass the workspace version it read before lowering. If the
  workspace has moved on, `{:error, :version_conflict}` is returned.

  The whole list commits as one gesture: a single version check, one
  `edit_version` bump, and either every batch applies or none does (a
  failing batch discards the accumulator — these are pure values). Each
  touched track's patches are then transported along its fresh log entry
  and persisted (write-time transport; design doc §2 step 4): survivors
  keep marching with up-to-date `at_version`, the dead (`{:undefined, _}`
  / `{:clip, _, _}` results) move to the track's `dead_patches`.
  `patches_add` from a batch are minted at the new head and join
  afterwards, untransported.
  """
  @spec apply_batches(
          t(),
          expected_version :: Tamale.version(),
          [{Track.track_id(), [Tamale.Op.t()], Coconut.Edit.Operation.side_changes()}]
        ) :: {:ok, t()} | {:error, term()}
  def apply_batches(_ws, _expected_version, []), do: {:error, :empty_batches}

  def apply_batches(ws, expected_version, batches) do
    new_version = ws.edit_version + 1

    with :ok <- check_version(ws, expected_version),
         {:ok, ws} <- apply_track_batches(ws, batches, new_version),
         :ok <- validate_touched_tracks(ws, batches) do
      ws = %{ws | edit_version: new_version}

      {:ok,
       ws
       |> transport_touched_tracks(batches)
       |> echo_tempo_transport(batches)}
    end
  end

  @doc """
  Apply an op batch to a single track. Convenience delegate of
  `apply_batches/3`; see its documentation.
  """
  @spec apply_batch(
          t(),
          Track.track_id(),
          expected_version :: Tamale.version(),
          [Tamale.Op.t()],
          Coconut.Edit.Operation.side_changes()
        ) :: {:ok, t()} | {:error, term()}
  def apply_batch(ws, track_id, expected_version, ops, side_changes),
    do: apply_batches(ws, expected_version, [{track_id, ops, side_changes}])

  # Each batch applies to its own track's Space and syncs that track's
  # side tables; batches on the same track apply sequentially in order.
  # Every committed batch records its version-clock entry (space version →
  # edit_version) — the cross-track tempo correlation facility (§5 item 4).
  # Pure content edits (empty op list) don't bump the Space version, so
  # they must not rewrite the existing entry's commit time.
  defp apply_track_batches(ws, batches, new_version) do
    Enum.reduce_while(batches, {:ok, ws}, fn {track_id, ops, side_changes}, {:ok, ws} ->
      with {:ok, track} <- fetch_track(ws, track_id),
           {:ok, space} <- Tamale.Space.apply_batch(track.space, ops) do
        track = %{track | space: space, version_clock: record_clock(track, space, new_version)}

        {:cont, {:ok, put_track(ws, Track.sync(track, space.version, side_changes))}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # 纯内容编辑（空 op 列表）不 bump Space version，不得覆写既有 clock
  # 条目的提交时刻。
  defp record_clock(track, space, new_version) do
    if space.version == track.space.version,
      do: track.version_clock,
      else: Map.put(track.version_clock, space.version, new_version)
  end

  defp validate_touched_tracks(ws, batches) do
    batches
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.find_value(:ok, fn track_id ->
      case validate_track(ws, track_id) do
        :ok ->
          nil

        {:error, _} = error ->
          error
      end
    end)
  end

  defp validate_track(ws, track_id) do
    with {:ok, track} <- fetch_track(ws, track_id) do
      Track.validate_state(track)
    end
  end

  # Write-time transport for every touched track, in first-touch order;
  # a track hit by several batches gets the concatenated patches_add.
  defp transport_touched_tracks(ws, batches) do
    batches
    |> Enum.reduce(%{}, fn {track_id, _ops, changes}, acc ->
      Map.update(acc, track_id, changes.patches_add, &(&1 ++ changes.patches_add))
    end)
    |> Enum.reduce(ws, fn {track_id, patches_add}, ws ->
      transport_track_patches(ws, track_id, patches_add)
    end)
  end

  # Write-time transport (design doc §2 flow step 4). Runs inside
  # apply_batch on the post-sync workspace: the track's surviving patches
  # are persisted with anchors at the new head, the dead are moved to the
  # graveyard, and this batch's own `patches_add` join untouched.
  defp transport_track_patches(ws, track_id, patches_add) do
    {:ok, track} = fetch_track(ws, track_id)

    provider =
      WarpProvider.for_coord(
        Track.coord_domain(track),
        Track.spans(track),
        track.patches,
        warp_context(ws, track)
      )

    {:ok, survivors, dead} = Track.transport_patches(track, provider)

    track = %{
      track
      | patches: survivors ++ patches_add,
        dead_patches: track.dead_patches ++ dead
    }

    put_track(ws, track)
  end

  # ---- Tempo echo transport (design doc §5 item 4) ----

  # A tempo batch adds no entry to other tracks' logs, yet frame-addressed,
  # score-following anchors must still follow it: after a tempo-track batch,
  # map every :frame Metric anchor on tick-domain tracks through
  # T_new ∘ T_old⁻¹. The tempo track itself is covered by its own log
  # entry's transport; frame-domain tracks (audio) never drift (§4).
  # Tracks touched by this same gesture are excluded — their write-time
  # transport already used the entry's {T_old, T_new} pair; echoing them
  # would move the anchor twice.
  defp echo_tempo_transport(ws, batches) do
    touched = MapSet.new(batches, fn {track_id, _ops, _changes} -> track_id end)

    if MapSet.member?(touched, @tempo_global_id) do
      steps_old = tempo_steps_at(ws, ws.edit_version - 1)
      steps_new = tempo_steps_at(ws, ws.edit_version)

      Enum.reduce(all_tracks(ws), ws, fn {track_id, track}, ws ->
        maybe_echo_track(ws, track_id, track, steps_old, steps_new, touched)
      end)
    else
      ws
    end
  end

  # 同一手势已触及的轨跳过：其写时 transport 已用 entry 的 T 对，echo
  # 会二次移动。无帧锚的轨与帧域轨（audio 不漂移，§4）零成本跳过。
  defp maybe_echo_track(ws, track_id, track, steps_old, steps_new, touched) do
    if MapSet.member?(touched, track_id) or Track.coord_domain(track) != :tick or
         not frame_anchored?(track) do
      ws
    else
      echo_track(ws, track, steps_old, steps_new)
    end
  end

  defp frame_anchored?(track) do
    Enum.any?(track.patches, fn
      %Coconut.Edit.Patch{anchor: %Tamale.Anchor.Metric{coord: :frame}} -> true
      _ -> false
    end)
  end

  defp echo_track(ws, track, steps_old, steps_new) do
    case WarpProvider.tempo_shift(steps_old, steps_new, ws.frame_rate, ws.tpqn, track.patches) do
      {:ok, warp} -> apply_echo(ws, track, warp)
      {:error, reason} -> kill_frame_anchors(ws, track, reason)
    end
  end

  defp apply_echo(ws, track, warp) do
    {survivors, dead} =
      track.patches
      |> Enum.map(&echo_anchor(&1, warp))
      |> Enum.reduce({[], []}, fn
        {:ok, patch}, {sv, dd} -> {[patch | sv], dd}
        {dead_patch, reason}, {sv, dd} -> {sv, [{dead_patch, reason} | dd]}
      end)

    put_track(ws, %{
      track
      | patches: Enum.reverse(survivors),
        dead_patches: track.dead_patches ++ Enum.reverse(dead)
    })
  end

  # warp 构造失败（tempo 缺失 / 帧率未声明）：本轨所有帧锚判死
  # （可见失败），其他锚原样保留
  defp kill_frame_anchors(ws, track, reason) do
    {frame_patches, others} =
      Enum.split_with(track.patches, fn
        %Coconut.Edit.Patch{anchor: %Tamale.Anchor.Metric{coord: :frame}} -> true
        _ -> false
      end)

    dead = Enum.map(frame_patches, &{&1, reason})

    put_track(ws, %{track | patches: others, dead_patches: track.dead_patches ++ dead})
  end

  # 非 :frame Metric 锚与 Ordinal/Relative 不受 tempo 影响，原样存活。
  # at_version 不动：echo 不产生 log entry。
  defp echo_anchor(
         %Coconut.Edit.Patch{
           anchor: %Tamale.Anchor.Metric{coord: :frame, from: from, to: to} = anchor
         } = patch,
         warp
       ) do
    case Warp.map_interval(warp, from, to) do
      {:ok, {new_from, new_to}} ->
        {:ok, %{patch | anchor: %{anchor | from: new_from, to: new_to}}}

      other ->
        {patch, other}
    end
  end

  defp echo_anchor(patch, _warp), do: {:ok, patch}

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
  Appends a patch to its track, returning the post-mint patch.

  Mount anchors at the track's current head version; every later
  `apply_batch/5` transports them forward. Construction-time legality
  (supported Metric `coord`) is enforced by `Coconut.Edit.Patch.new/1`; an
  unknown `track_id` is rejected here (`{:error, {:unknown_track, _}}`) —
  with patches stored per track there is nowhere for an orphan to land.
  A Metric anchor whose `coord` differs from the track's `coord_domain`
  is rejected as well (`{:error, {:anchor_coord_mismatch, _, _}}`, design
  doc §5): it would otherwise mount fine and only die as
  `:warp_provider_required` at transport time. The one cross-domain
  exception: a `:frame` Metric anchor on a `:tick` track (score-following,
  frame-addressed, §5 item 4), which requires a declared `frame_rate`
  (`{:error, :missing_frame_rate}`).

  Returns `{:ok, workspace, patch}` where `patch` is the mounted patch
  after id minting — the recordable form (design doc §12.4).
  """
  @spec attach_patch(t(), Coconut.Edit.Patch.t()) ::
          {:ok, t(), Coconut.Edit.Patch.t()} | {:error, term()}
  def attach_patch(ws, %Coconut.Edit.Patch{track_id: track_id} = patch) do
    with {:ok, track} <- fetch_track(ws, track_id),
         :ok <- check_anchor_domain(patch, track, ws) do
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

  # Anchor coord vs track domain consistency (design doc §5): a Metric
  # anchor's coord must equal the track's coord_domain — except a `:frame`
  # anchor on a `:tick` track (score-following, frame-addressed, §5 item 4),
  # which additionally requires the workspace to declare a `frame_rate`
  # (the tick↔frame grid) at mount time. Ordinal/Relative anchors are
  # coord-free and always pass.
  defp check_anchor_domain(patch, track, ws) do
    case patch.anchor do
      %Tamale.Anchor.Metric{coord: coord} -> check_metric_coord(coord, track, ws)
      _anchor -> :ok
    end
  end

  defp check_metric_coord(coord, track, ws) do
    domain = Track.coord_domain(track)
    frame_on_tick? = coord == :frame and domain == :tick

    cond do
      coord == domain -> :ok
      frame_on_tick? and is_nil(ws.frame_rate) -> {:error, :missing_frame_rate}
      frame_on_tick? -> :ok
      true -> {:error, {:anchor_coord_mismatch, coord, domain}}
    end
  end

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
  Moves active patches into their tracks' graveyards.

  Each entry is `{track_id, patch_id, reason}`. The whole discard is
  validated before any track changes, so an unknown or repeated patch leaves
  the workspace untouched. Patch lifecycle changes do not bump
  `edit_version`, matching `attach_patch/2`.
  """
  @spec discard_patches(t(), [{Track.track_id(), ID.t(), term()}]) ::
          {:ok, t()} | {:error, term()}
  def discard_patches(ws, entries) when is_list(entries) do
    with :ok <- validate_discard_shapes(entries),
         :ok <- validate_discard_entries(ws, entries) do
      {:ok, Enum.reduce(entries, ws, &discard_patch/2)}
    end
  end

  def discard_patches(_ws, entries), do: {:error, {:invalid_patch_discards, entries}}

  defp validate_discard_shapes(entries) do
    if Enum.all?(entries, fn
         {track_id, patch_id, _reason} when not is_nil(track_id) and not is_nil(patch_id) -> true
         _other -> false
       end) do
      :ok
    else
      {:error, {:invalid_patch_discards, entries}}
    end
  end

  defp validate_discard_entries(ws, entries) do
    refs = Enum.map(entries, fn {track_id, patch_id, _reason} -> {track_id, patch_id} end)

    if length(refs) != MapSet.size(MapSet.new(refs)) do
      {:error, :duplicate_patch_discard}
    else
      Enum.reduce_while(refs, :ok, &validate_discard_ref(ws, &1, &2))
    end
  end

  defp validate_discard_ref(ws, {track_id, patch_id}, :ok) do
    case fetch_discard_patch(ws, track_id, patch_id) do
      :ok -> {:cont, :ok}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp fetch_discard_patch(ws, track_id, patch_id) do
    with {:ok, track} <- fetch_track(ws, track_id) do
      validate_patch_count(Enum.count(track.patches, &(&1.id == patch_id)), track_id, patch_id)
    end
  end

  defp validate_patch_count(1, _track_id, _patch_id), do: :ok

  defp validate_patch_count(0, track_id, patch_id),
    do: {:error, {:unknown_patch, track_id, patch_id}}

  defp validate_patch_count(_many, track_id, patch_id),
    do: {:error, {:ambiguous_patch, track_id, patch_id}}

  defp discard_patch({track_id, patch_id, reason}, ws) do
    {:ok, track} = fetch_track(ws, track_id)
    {discarded, active} = Enum.split_with(track.patches, &(&1.id == patch_id))
    [patch] = discarded

    put_track(ws, %{
      track
      | patches: active,
        dead_patches: track.dead_patches ++ [{patch, reason}]
    })
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
  Exact tempo steps (`[{tick, milli_bpm}]`) in effect at `edit_version`,
  located through the tempo track's version clock — the cross-track
  correlation backing frame warps (design doc §5 item 4).

  `nil` when the tempo track is missing or had no events at that moment.
  Element payloads are the current table (bpm value edits are unversioned
  content edits — a documented approximation).
  """
  @spec tempo_steps_at(t(), Tamale.version()) ::
          [{Coconut.Score.Tick.numeric_tick(), pos_integer()}] | nil
  def tempo_steps_at(ws, edit_version) when is_integer(edit_version) and edit_version >= 0 do
    with %Track{} = tempo <- Map.get(ws.globals, @tempo_global_id),
         version when is_integer(version) <- tempo_version_at(tempo, edit_version),
         [{_, _} | _] = steps <- tempo.module.tempo_steps_at(tempo, version) do
      steps
    else
      _ -> nil
    end
  end

  # 反查 tempo 轨在 edit_version E 时的 Space 版本：clock 非空取
  # edit_version ≤ E 的最大 space version（无 → 0，出生状态）；旧档 clock
  # 为空时事件无法定年，一律视为与读档状态同时（最新快照——读档后锚都
  # 在 head，无历史 fold，这是正确的近似）。
  defp tempo_version_at(tempo, edit_version) do
    case tempo.version_clock do
      clock when map_size(clock) == 0 ->
        tempo.spans_by_version |> Map.keys() |> Enum.max(fn -> nil end)

      clock ->
        clock
        |> Enum.filter(fn {_v, ev} -> ev <= edit_version end)
        |> Enum.max_by(fn {v, _ev} -> v end, fn -> nil end)
        |> case do
          nil -> 0
          {v, _ev} -> v
        end
    end
  end

  @doc """
  The `Coconut.Edit.WarpProvider.frame_context()` for one track: the
  tempo-pair closure (dated through the track's version clock), the
  workspace's `frame_rate`, and `tpqn`. Shared by the two provider
  construction sites — write-time (`apply_batches/3`) and check-time
  (`Coconut.Render.Resolve`).
  """
  @spec warp_context(t(), Track.t()) :: WarpProvider.frame_context()
  def warp_context(ws, track) do
    %{
      tempo_pair_at: fn version ->
        with {:ok, e} <- edit_version_at(track, version),
             steps_old when not is_nil(steps_old) <- tempo_steps_at(ws, e - 1),
             steps_new when not is_nil(steps_new) <- tempo_steps_at(ws, e) do
          {steps_old, steps_new}
        else
          _ -> nil
        end
      end,
      frame_rate: ws.frame_rate,
      tpqn: ws.tpqn
    }
  end

  # log entry 的 space version → edit_version：精确命中优先，缺失时取
  # ≤ version 的最近记录（截断 baseline 由此兜底）；全无记录 → :error
  # （旧档的历史 entry 无法定年，对组合拒绝服务，帧锚可见判死）。
  defp edit_version_at(track, version) do
    clock = track.version_clock

    case Map.fetch(clock, version) do
      {:ok, e} ->
        {:ok, e}

      :error ->
        clock
        |> Enum.filter(fn {v, _e} -> v <= version end)
        |> Enum.max_by(fn {v, _e} -> v end, fn -> nil end)
        |> case do
          nil -> :error
          {_v, e} -> {:ok, e}
        end
    end
  end

  @doc """
  Builds a compiled `TempoMap` from the tempo global track
  (`"global:tempo"` in `globals`), at the workspace's `tpqn`.

  A missing or empty tempo track yields `{:error, :missing_tempo_track}` —
  engines apply their own fallback (see `Coconut.Render.Engine.Snapshot`).
  """
  @spec tempo_map(t()) :: {:ok, TempoMap.t()} | {:error, term()}
  def tempo_map(ws) do
    with %Track{} = tempo <- Map.get(ws.globals, @tempo_global_id),
         [_ | _] = events <- tempo.module.tempo_events(tempo) do
      TempoMap.compile(events, tpqn: ws.tpqn)
    else
      _ -> {:error, :missing_tempo_track}
    end
  end

  @doc """
  Elapsed physical time of a tick range (e.g. an editor selection) under
  the workspace's tempo track. Propagates `{:error, :missing_tempo_track}`
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
    with :ok <- check_edit_version(ws.edit_version),
         :ok <- check_tpqn(ws.tpqn),
         :ok <- check_globals(ws.globals),
         :ok <- check_tracks(ws.tracks),
         :ok <- check_tempo_global(ws.globals),
         :ok <- check_frame_rate(ws.frame_rate),
         :ok <- check_time_sigs(ws.time_sigs),
         :ok <- check_track_states(ws) do
      {:ok, ws}
    end
  end

  defp check_edit_version(version) when is_integer(version) and version >= 0, do: :ok
  defp check_edit_version(version), do: {:error, {:invalid_edit_version, version}}

  defp check_tpqn(tpqn) when is_integer(tpqn) and tpqn > 0, do: :ok
  defp check_tpqn(tpqn), do: {:error, {:invalid_tpqn, tpqn}}

  defp check_track_states(ws) do
    Enum.find_value(all_tracks(ws), :ok, fn {_id, track} ->
      case Track.validate_state(track) do
        :ok -> nil
        {:error, _} = error -> error
      end
    end)
  end

  # 帧网格声明：工程 metadata，内核存而不解释（单位归引擎，§11.8）。
  # nil = 未声明（帧域 Metric 锚上不了 tick 轨）；正整数或正有理数。
  defp check_frame_rate(nil), do: :ok
  defp check_frame_rate(rate) when is_integer(rate) and rate > 0, do: :ok

  defp check_frame_rate({n, d}) when is_integer(n) and is_integer(d) and n > 0 and d > 0,
    do: :ok

  defp check_frame_rate(other), do: {:error, {:invalid_frame_rate, other}}

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
  # `:missing_tempo_track`); when present its module must derive tempo.
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
