defmodule Coconut.Edit.Command do
  @moduledoc """
  A resolved workspace write, in recordable form (design doc §12.4).

  A command is the *only* write record `Coconut.Edit.History` understands:
  write entries lower user-level input to a command, `execute/3` performs
  it against a workspace and returns the **resolved** command (post-mint,
  post-construction), and replay folds stored commands back through the
  same `execute/3` — live writes and replay share this single dispatch
  table (§12.4 discipline 3, no replay-only implementation).

  `payload` shape per `op`:

  - `:batch` — `[{track_id, ops, side_changes}]` per-track batches (the
    output of `Coconut.Edit.Operation.lower_batches/3`; normally produced
    via `Coconut.Edit.History.apply/4`, not built by hand);
  - `:attach_patches` — `[Patch.t()]`; execution mints patch ids, so the
    resolved command can differ from the input one;
  - `:discard_patches` — `[{track_id, patch_id, reason}]`; active patches
    move to their tracks' graveyards;
  - `:repatch_patches` — `{discards, [Patch.t()]}`: the batch re-mount
    gesture (design doc `design-2026-08-orchid-intervention.md` §6.6).
    Discards execute before attachments in a single history edge, so one
    undo restores the whole batch; attachment ids are minted at execution
    (same discipline as `:attach_patches`);
  - `:add_track` — a fully constructed `Coconut.Edit.Track.t()`;
  - `:remove_track` — `track_id`;
  - `:rename_track` — `{track_id, name}`;
  - `:put_track_metadata` / `:put_track_extras` — `{track_id, full_map}`；
  - `:set_time_sigs` — `[time_sig_event]`;
  - `:consume_dead` — execution drains the graveyards and fills the
    payload with the drained `{patch, reason}` tuples (replay re-drains,
    ignoring the stored payload).
  """

  alias Coconut.Edit.{Operation, Patch, Track, Workspace}
  alias Coconut.Util.ID

  @type op ::
          :batch
          | :attach_patches
          | :discard_patches
          | :repatch_patches
          | :add_track
          | :remove_track
          | :rename_track
          | :put_track_metadata
          | :put_track_extras
          | :set_time_sigs
          | :consume_dead

  @typedoc """
  A workspace write record. `label` is the display annotation History
  stores on the tree node; `payload` is post-resolution by the time a
  command reaches the tree (see `execute/3`).
  """
  @type t :: %__MODULE__{
          op: op(),
          payload: term(),
          label: String.t()
        }

  defstruct [:op, :payload, label: "Edit"]

  # ---- Constructors ----

  @doc """
  Per-track op batches lowered from an edit gesture
  (`Coconut.Edit.Operation.lower_batches/3` output) — a one-element list
  for single-track gestures.
  """
  @spec batch([{Track.track_id(), [Tamale.Op.t()], Operation.side_changes()}], String.t()) :: t()
  def batch(batches, label) when is_list(batches),
    do: %__MODULE__{op: :batch, payload: batches, label: label}

  @doc "Mount a list of patches; ids are minted at execution (see `execute/3`)."
  @spec attach_patches([Patch.t()]) :: t()
  def attach_patches(patches) when is_list(patches),
    do: %__MODULE__{op: :attach_patches, payload: patches, label: "AttachPatches"}

  @doc "Move active patches to their tracks' graveyards with explicit reasons."
  @spec discard_patches([{Track.track_id(), ID.t(), term()}]) :: t()
  def discard_patches(entries) when is_list(entries),
    do: %__MODULE__{op: :discard_patches, payload: entries, label: "DiscardPatches"}

  @doc """
  Batch re-mount gesture: discard the drifted patches and attach their
  re-signed replacements as one history edge (`§6.6` re-patch).
  """
  @spec repatch_patches([{Track.track_id(), ID.t(), term()}], [Patch.t()]) :: t()
  def repatch_patches(discards, patches) when is_list(discards) and is_list(patches),
    do: %__MODULE__{op: :repatch_patches, payload: {discards, patches}, label: "RepatchPatches"}

  @doc """
  Build an add-track command from `Track.new/1` attrs; `:id` is minted
  when absent. The constructed track rides in the payload, so replay
  never re-mints (§12.4 discipline 1).
  """
  @spec add_track(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def add_track(attrs) do
    attrs = attrs |> Map.new() |> Map.put_new_lazy(:id, fn -> ID.generate_id("Track_") end)

    case Track.new(attrs) do
      {:ok, track} -> {:ok, %__MODULE__{op: :add_track, payload: track, label: "AddTrack"}}
      {:error, _} = err -> err
    end
  end

  @doc "Remove a track by id (a structural edge)."
  @spec remove_track(Track.track_id()) :: t()
  def remove_track(track_id),
    do: %__MODULE__{op: :remove_track, payload: track_id, label: "RemoveTrack"}

  @doc "Rename a track (a light field edge; `name` is an annotation, §11.8)."
  @spec rename_track(Track.track_id(), String.t() | nil) :: t()
  def rename_track(track_id, name),
    do: %__MODULE__{op: :rename_track, payload: {track_id, name}, label: "RenameTrack"}

  @doc "整体替换轨道展示 metadata，作为一条可撤销历史边。"
  @spec put_track_metadata(Track.track_id(), map()) :: t()
  def put_track_metadata(track_id, metadata) when is_map(metadata),
    do: %__MODULE__{
      op: :put_track_metadata,
      payload: {track_id, metadata},
      label: "PutTrackMetadata"
    }

  @doc "整体替换轨道宿主 extras，作为一条可撤销历史边。"
  @spec put_track_extras(Track.track_id(), map()) :: t()
  def put_track_extras(track_id, extras) when is_map(extras),
    do: %__MODULE__{op: :put_track_extras, payload: {track_id, extras}, label: "PutTrackExtras"}

  @doc "Replace the time signature events (a light field edge, §6)."
  @spec set_time_sigs([Coconut.Score.TimeSig.time_sig_event()]) :: t()
  def set_time_sigs(events),
    do: %__MODULE__{op: :set_time_sigs, payload: events, label: "SetTimeSigs"}

  @doc "Drain the patch graveyards; the resolved payload carries the drained tuples."
  @spec consume_dead() :: t()
  def consume_dead, do: %__MODULE__{op: :consume_dead, payload: [], label: "ConsumeDead"}

  # ---- Execution ----

  @doc """
  Execute a command against a workspace.

  Returns `{:ok, new_workspace, resolved}` where `resolved` is the
  recordable form — identical to the input for every op except
  `:attach_patches` / `:repatch_patches` (patch ids minted) and
  `:consume_dead` (payload filled with the drained tuples).

  Options: `:expected_version` — the aggregate optimistic lock for
  `:batch`, defaulting to the workspace's own version (replay is
  sequential, so the lock always sees the current version, §12.4).
  """
  @spec execute(Workspace.t(), t(), keyword()) ::
          {:ok, Workspace.t(), t()} | {:error, term()}
  def execute(ws, command, opts \\ [])

  def execute(ws, %__MODULE__{op: :batch, payload: batches} = command, opts) do
    expected = Keyword.get(opts, :expected_version, ws.edit_version)
    run(command, fn -> Workspace.apply_batches(ws, expected, batches) end)
  end

  def execute(ws, %__MODULE__{op: :attach_patches, payload: patches} = command, _opts) do
    case Workspace.attach_patches(ws, patches) do
      {:ok, new_ws, minted} -> {:ok, new_ws, %{command | payload: minted}}
      {:error, _} = err -> err
    end
  end

  def execute(ws, %__MODULE__{op: :discard_patches, payload: entries} = command, _opts),
    do: run(command, fn -> Workspace.discard_patches(ws, entries) end)

  def execute(
        ws,
        %__MODULE__{op: :repatch_patches, payload: {discards, patches}} = command,
        _opts
      ) do
    with {:ok, ws} <- Workspace.discard_patches(ws, discards),
         {:ok, ws, minted} <- Workspace.attach_patches(ws, patches) do
      {:ok, ws, %{command | payload: {discards, minted}}}
    end
  end

  def execute(ws, %__MODULE__{op: :add_track, payload: %Track{} = track} = command, _opts),
    do: run(command, fn -> Workspace.add_track(ws, track) end)

  def execute(ws, %__MODULE__{op: :remove_track, payload: track_id} = command, _opts),
    do: run(command, fn -> Workspace.remove_track(ws, track_id) end)

  def execute(ws, %__MODULE__{op: :rename_track, payload: {track_id, name}} = command, _opts),
    do: run(command, fn -> Workspace.rename_track(ws, track_id, name) end)

  def execute(
        ws,
        %__MODULE__{op: :put_track_metadata, payload: {track_id, metadata}} = command,
        _opts
      ),
      do: run(command, fn -> Workspace.put_track_metadata(ws, track_id, metadata) end)

  def execute(
        ws,
        %__MODULE__{op: :put_track_extras, payload: {track_id, extras}} = command,
        _opts
      ),
      do: run(command, fn -> Workspace.put_track_extras(ws, track_id, extras) end)

  def execute(ws, %__MODULE__{op: :set_time_sigs, payload: events} = command, _opts),
    do: run(command, fn -> Workspace.set_time_sigs(ws, events) end)

  def execute(ws, %__MODULE__{op: :consume_dead} = command, _opts) do
    {dead, new_ws} = Workspace.take_dead_patches(ws)
    {:ok, new_ws, %{command | payload: dead}}
  end

  defp run(command, fun) do
    case fun.() do
      {:ok, new_ws} -> {:ok, new_ws, command}
      {:error, _} = err -> err
    end
  end
end
