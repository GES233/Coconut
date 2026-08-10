defmodule Coconut.Scenario do
  @moduledoc """
  Golden scenario contract, ported from zongzi_feasibility's
  Scenario/Measurer pattern (design doc §10 item 2).

  Only the contract and the adversarial-round driver came over — the
  Measurer's PNG/HTML report stayed behind: it was bound to a real engine
  projection producing plots, and coconut's projections are channel-supplied
  digest slices with nothing to draw.

  Flow (driven by `run_scenario/1`):

  1. `setup/0` — build a workspace, mount patches, supply check channels.
  2. round 1 — baseline check (no edit).
  3. `edits/1` — each op one adversarial round: `Edit.Operation` lower →
     `Workspace.apply_batch` → `Resolve.run_check`.
  4. `expect/1` — judges all rounds, `:ok` or `{:miss, message}`.

  The round record handed to `expect/1`:

      %{
        round: pos_integer(),
        op: :baseline | Coconut.Edit.Operation.request(),
        passed: boolean(),
        survivors: [Coconut.Edit.Patch.t()],   # check-time survivors (pass only)
        dead: [{Coconut.Edit.Patch.t(), term()}],  # write-time graveyard
        entries: [Coconut.Render.Resolve.check_entry()]
      }
  """

  alias Coconut.Edit.{Operation, Patch, Track, Workspace}
  alias Coconut.Edit.Operations.InsertNote
  alias Coconut.Render.Channels.Lyric
  alias Coconut.Render.Resolve
  alias Coconut.Score.Note
  alias Coconut.Util.ID

  @vocal_track "vocal"

  @callback id() :: String.t()
  @callback title() :: String.t()
  @callback setup() :: {Workspace.t(), %{atom() => Resolve.channel_spec()}}
  @callback edits(Workspace.t()) :: [Operation.request()]
  @callback expect(%{rounds: [map()], final_ws: Workspace.t()}) :: :ok | {:miss, String.t()}

  @doc "Runs one scenario, returning `%{id, title, verdict, rounds}`."
  def run_scenario(scenario) do
    {ws, channels} = scenario.setup()
    ops = [:baseline | scenario.edits(ws)]

    {rounds, final_ws} =
      ops
      |> Enum.with_index(1)
      |> Enum.map_reduce(ws, fn {op, i}, ws ->
        ws = apply_edit(ws, op)
        {:ok, check} = Resolve.run_check(ws, channels)
        {summarize_round(i, op, ws, check), ws}
      end)

    verdict = scenario.expect(%{rounds: rounds, final_ws: final_ws})
    %{id: scenario.id(), title: scenario.title(), verdict: verdict, rounds: rounds}
  end

  # ---- Round driving ----

  defp apply_edit(ws, :baseline), do: ws

  defp apply_edit(ws, op) do
    track_id = op.track_id
    :ok = Operation.validate(op, ws)
    {:ok, ops, changes} = Operation.lower(op, ws, %Operation.Config{})
    {:ok, ws} = Workspace.apply_batch(ws, track_id, ws.edit_version, ops, changes)
    ws
  end

  defp summarize_round(i, op, ws, check) do
    base = %{round: i, op: op, dead: dead_patches(ws)}

    case check do
      %{passed: true, survivors: survivors} ->
        Map.merge(base, %{passed: true, survivors: survivors, entries: []})

      %{passed: false, entries: entries} ->
        Map.merge(base, %{passed: false, survivors: [], entries: entries})
    end
  end

  defp dead_patches(ws) do
    Enum.flat_map(Workspace.all_tracks(ws), fn {_id, track} -> track.dead_patches end)
  end

  # ---- Scenario authoring helpers ----

  @doc "An empty workspace with a single vocal track `\"vocal\"`."
  def base_workspace do
    {:ok, track} = Track.new(%{id: @vocal_track, module: Track.Vocal})

    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        tracks: %{@vocal_track => track}
      })

    ws
  end

  @doc "Inserts a note into the vocal track through the full Edit.Operation path."
  def insert_note(ws, id, after_id, span, attrs) do
    req = %InsertNote{
      track_id: @vocal_track,
      note_id: id,
      after_id: after_id,
      span: span,
      attrs: attrs
    }

    :ok = Operation.validate(req, ws)
    {:ok, ops, changes} = Operation.lower(req, ws, %Operation.Config{})
    {:ok, ws} = Workspace.apply_batch(ws, @vocal_track, ws.edit_version, ops, changes)
    ws
  end

  @doc """
  Mounts a note-anchored patch, capturing the current element's canonical
  projection as the base — the mount-at-edit-time flow.
  """
  def mount_note_patch(ws, note_id, channel, payload) do
    track = Map.fetch!(ws.tracks, @vocal_track)
    element = Map.fetch!(track.elements_by_id, note_id)
    {:ok, tp} = Tamale.Patch.new(Note.to_canonical(element), payload)

    {:ok, cp} =
      Patch.new(%{
        track_id: @vocal_track,
        channel: channel,
        anchor: %Tamale.Anchor.Ordinal{refs: [note_id], at_version: track.space.version},
        patch: tp
      })

    {:ok, ws, _minted} = Workspace.attach_patch(ws, cp)
    ws
  end

  @doc "The default check channels: lyric on the vocal track."
  def default_channels, do: %{lyric: Lyric}
end
