defmodule Coconut.ResolveTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.{Operation, Patch, Track, Workspace}
  alias Coconut.Engines.Mock
  alias Coconut.Render.Engine
  alias Coconut.Render.Engine.Request
  alias Coconut.Render.Resolve
  alias Coconut.Score.Note
  alias Coconut.Util.ID

  @track "vocal"

  defmodule FanoutChannel do
    alias Coconut.Render.Channels.Lyric

    @behaviour Coconut.Render.Channel

    @impl true
    def projection(ws, patch), do: Lyric.projection(ws, patch)

    @impl true
    def target do
      fn payload ->
        [
          {{:port, :synth, :lyric}, payload.lyric},
          {{:port, :synth, :energy}, payload.energy}
        ]
      end
    end
  end

  defmodule ProbeChannel do
    @moduledoc """
    probe 期 channel（§6.6 身份底料）：静态 check 不裁决 digest，
    payload 原样 fold；projection 永远不会被 Resolve 调用。
    """

    @behaviour Coconut.Render.Channel

    @impl true
    def projection(_ws, _patch), do: {:error, :probe_stage_channel}

    @impl true
    def target(%Patch{anchor: %Tamale.Anchor.Ordinal{refs: [id | _]}}),
      do: {:port, id, :probe_pin}

    @impl true
    def resolve_stage, do: :probe
  end

  setup do
    {:ok, track} = Track.new(%{id: @track, module: Track.Vocal})

    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        tracks: %{@track => track}
      })

    {:ok, ws: ws}
  end

  # ---- Helpers ----

  defp insert_note(ws, id, after_id, span, attrs) do
    {:ok, ops, changes} =
      Operation.lower(
        %Coconut.Edit.Operations.InsertNote{
          track_id: @track,
          note_id: id,
          after_id: after_id,
          span: span,
          attrs: attrs
        },
        ws,
        %Operation.Config{}
      )

    {:ok, ws} = Workspace.apply_batch(ws, @track, ws.edit_version, ops, changes)
    ws
  end

  # Mounts a :lyric patch on `note_id`, capturing the current element's
  # canonical projection as base — same as a real mount-at-edit-time flow.
  defp attach_lyric_patch(ws, note_id, payload) do
    data = Map.fetch!(ws.tracks[@track].elements_by_id, note_id)
    {:ok, tp} = Tamale.Patch.new(Note.to_canonical(data), payload)

    {:ok, cp} =
      Patch.new(%{
        track_id: @track,
        channel: :lyric,
        anchor: %Tamale.Anchor.Ordinal{
          refs: [note_id],
          at_version: ws.tracks[@track].space.version
        },
        patch: tp
      })

    {:ok, ws, _minted} = Workspace.attach_patch(ws, cp)
    ws
  end

  # Rewrites a note's element data in place (simulating a content edit).
  defp rewrite_note(ws, note_id, attrs) do
    {:ok, note} = Note.from_element(note_id, attrs)
    put_in(ws.tracks[@track].elements_by_id[note_id], note)
  end

  defp channels, do: %{lyric: Coconut.Render.Channels.Lyric}

  # ---- Tests ----

  test "empty patch list resolves to empty interventions", %{ws: ws} do
    assert {:ok, %{passed: true, interventions: interventions, survivors: []}} =
             Resolve.run_check(ws, channels())

    assert interventions == %{}
  end

  test "all patches resolve and fold into interventions", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60, lyric: "ら"})
    ws = attach_lyric_patch(ws, "n1", %{lyric: "らん"})

    assert {:ok, %{passed: true, interventions: interventions, survivors: survivors}} =
             Resolve.run_check(ws, channels())

    assert interventions == %{{:port, :synth, :lyric} => %{input: %{lyric: "らん"}}}
    assert [%Patch{track_id: @track, channel: :lyric}] = survivors
  end

  test "stale base digest vetoes the batch — no silent apply", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60, lyric: "ら"})
    ws = attach_lyric_patch(ws, "n1", %{lyric: "らん"})

    assert {:ok, %{passed: true}} = Resolve.run_check(ws, channels())

    # The content changes out from under the mounted patch.
    ws = rewrite_note(ws, "n1", %{pitch: 60, lyric: "り"})

    assert {:ok, %{passed: false, entries: [entry]}} = Resolve.run_check(ws, channels())
    assert entry.kind == :conflict
    assert entry.channel == :lyric
    assert entry.track_id == @track
  end

  test "all failures are aggregated, not short-circuited", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60})
    ws = insert_note(ws, "n2", "n1", {480, 960}, %{pitch: 62})
    ws = attach_lyric_patch(ws, "n1", %{lyric: "x"})
    ws = attach_lyric_patch(ws, "n2", %{lyric: "y"})

    ws = rewrite_note(ws, "n1", %{pitch: 61})
    ws = rewrite_note(ws, "n2", %{pitch: 63})

    assert {:ok, %{passed: false, entries: entries}} = Resolve.run_check(ws, channels())
    assert length(entries) == 2
    assert Enum.all?(entries, &(&1.kind == :conflict))
  end

  test "patch anchored on a deleted note dies at write time", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60})
    ws = attach_lyric_patch(ws, "n1", %{lyric: "x"})

    {:ok, ops, changes} =
      Operation.lower(
        %Coconut.Edit.Operations.DeleteNote{track_id: @track, note_id: "n1"},
        ws,
        %Operation.Config{}
      )

    {:ok, ws} = Workspace.apply_batch(ws, @track, ws.edit_version, ops, changes)

    # Write-time transport moved the patch to the graveyard during
    # apply_batch — the check no longer sees it at all.
    assert ws.tracks[@track].patches == []
    assert [{_cp, {:undefined, {:deleted, "n1"}}}] = ws.tracks[@track].dead_patches

    assert {:ok, %{passed: true, interventions: %{}, survivors: []}} =
             Resolve.run_check(ws, channels())
  end

  test "patch on an unknown channel is rejected", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60})

    {:ok, cp} =
      Patch.new(%{
        track_id: @track,
        channel: :pitch,
        anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: ws.tracks[@track].space.version},
        patch: %Tamale.Patch{base_digest: "whatever", payload: %{}}
      })

    {:ok, ws, _minted} = Workspace.attach_patch(ws, cp)

    assert {:ok, %{passed: false, entries: [entry]}} = Resolve.run_check(ws, channels())
    assert entry.kind == :unknown_channel
    assert entry.channel == :pitch
  end

  test "patch-aware channel target folds to per-note ports", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60})

    data = Map.fetch!(ws.tracks[@track].elements_by_id, "n1")
    {:ok, tp} = Tamale.Patch.new(Note.to_canonical(data), [[0, 60], [480, 62]])

    {:ok, cp} =
      Patch.new(%{
        track_id: @track,
        channel: :pitch,
        anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: ws.tracks[@track].space.version},
        patch: tp
      })

    {:ok, ws, _minted} = Workspace.attach_patch(ws, cp)

    assert {:ok, %{passed: true, interventions: interventions}} =
             Resolve.run_check(ws, %{pitch: Coconut.Render.Channels.Pitch})

    assert interventions == %{{:port, "n1", :pitch} => %{input: [[0, 60], [480, 62]]}}
  end

  test "duration channel folds to per-note duration ports", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60})

    data = Map.fetch!(ws.tracks[@track].elements_by_id, "n1")
    {:ok, tp} = Tamale.Patch.new(Note.to_canonical(data), [[0, 96], [1, 384]])

    {:ok, cp} =
      Patch.new(%{
        track_id: @track,
        channel: :duration,
        anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: ws.tracks[@track].space.version},
        patch: tp
      })

    {:ok, ws, _minted} = Workspace.attach_patch(ws, cp)

    assert {:ok, %{passed: true, interventions: interventions}} =
             Resolve.run_check(ws, %{duration: Coconut.Render.Channels.Duration})

    assert interventions == %{{:port, "n1", :duration} => %{input: [[0, 96], [1, 384]]}}
  end

  test "probe-stage channel skips static digest adjudication", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60, lyric: "ら"})

    # probe 期 channel 的底料在 workspace 之外物化：静态 check 不做 digest
    # 裁决，payload 原样 fold（引擎 probe 重新裁决）。
    {:ok, tp} = Tamale.Patch.new([["zh", "l"], ["zh", "a"]], [[0, 96]])

    {:ok, cp} =
      Patch.new(%{
        track_id: @track,
        channel: :probe_pin,
        anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: ws.tracks[@track].space.version},
        patch: tp
      })

    {:ok, ws, _minted} = Workspace.attach_patch(ws, cp)

    assert {:ok, %{passed: true, interventions: interventions, survivors: [_]}} =
             Resolve.run_check(ws, %{probe_pin: ProbeChannel})

    assert interventions == %{{:port, "n1", :probe_pin} => %{input: [[0, 96]]}}

    # 音符内容漂移不会触发静态 veto（身份裁决归引擎 probe）；但锚 transport
    # 仍是静态的——删音符照旧杀 patch。
    ws = rewrite_note(ws, "n1", %{pitch: 61, lyric: "り"})
    assert {:ok, %{passed: true}} = Resolve.run_check(ws, %{probe_pin: ProbeChannel})
  end

  test "probe-stage channel still dies at transport when the anchor dies", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60})

    {:ok, tp} = Tamale.Patch.new([["zh", "a"]], [[0, 96]])

    {:ok, cp} =
      Patch.new(%{
        track_id: @track,
        channel: :probe_pin,
        anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: ws.tracks[@track].space.version},
        patch: tp
      })

    {:ok, ws, _minted} = Workspace.attach_patch(ws, cp)

    {:ok, ops, changes} =
      Operation.lower(
        %Coconut.Edit.Operations.DeleteNote{track_id: @track, note_id: "n1"},
        ws,
        %Operation.Config{}
      )

    {:ok, ws} = Workspace.apply_batch(ws, @track, ws.edit_version, ops, changes)

    assert ws.tracks[@track].patches == []
    assert [{_cp, {:undefined, {:deleted, "n1"}}}] = ws.tracks[@track].dead_patches
  end

  test "function target fans a payload out to multiple ports", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60, lyric: "ら"})
    ws = attach_lyric_patch(ws, "n1", %{lyric: "らん", energy: 80})

    channels = %{lyric: FanoutChannel}

    assert {:ok, %{interventions: interventions}} = Resolve.run_check(ws, channels)

    assert interventions == %{
             {:port, :synth, :lyric} => %{input: "らん"},
             {:port, :synth, :energy} => %{input: 80}
           }
  end

  test "end-to-end: resolve, then engine check + render", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60, lyric: "ら"})
    ws = attach_lyric_patch(ws, "n1", %{lyric: "らん"})

    {:ok, %{passed: true, interventions: interventions}} = Resolve.run_check(ws, channels())
    {:ok, request} = Request.for_workspace(ws, interventions: interventions)

    assert {:ok, %{passed: true, checked: nil}} = Engine.run_check(Mock, request)
    assert {:ok, artifact} = Engine.run_render(Mock, request, nil)
    assert artifact.overrides == interventions
    assert artifact.payload.notes["n1"].span == {0, 480}
    assert artifact.payload.notes["n1"].lyric == "ら"
  end
end
