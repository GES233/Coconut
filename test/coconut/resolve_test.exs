defmodule Coconut.ResolveTest do
  use ExUnit.Case, async: true

  alias Coconut.{Engine, Operate, Patch, Resolve, Workspace}
  alias Coconut.Engine.{MockEngine, Request}
  alias Coconut.Util.ID

  @track :vocal

  setup do
    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        tracks: %{@track => %Tamale.Space{}},
        side: %Workspace.Side{}
      })

    {:ok, ws: ws}
  end

  # ---- Helpers ----

  defp insert_note(ws, id, after_id, span, attrs) do
    {:ok, ops, changes} =
      Operate.lower({:insert_note, @track, id, after_id, span, attrs}, ws, %Operate.Config{})

    {:ok, ws} = Workspace.apply_batch(ws, @track, ws.edit_version, ops, changes)
    ws
  end

  # Mounts a :lyric patch on `note_id`, capturing the current element as
  # base — same as a real mount-at-edit-time flow.
  defp attach_lyric_patch(ws, note_id, payload) do
    data = Map.fetch!(ws.side.elements_by_id, note_id)
    {:ok, tp} = Tamale.Patch.new(data, payload)

    {:ok, cp} =
      Patch.new(%{
        track_id: @track,
        channel: :lyric,
        anchor: %Tamale.Anchor.Ordinal{refs: [note_id], at_version: ws.tracks[@track].version},
        patch: tp
      })

    Workspace.attach_patch(ws, cp)
  end

  defp lyric_channel do
    %{
      projection: fn ws, %Patch{} = patch ->
        case patch.anchor do
          %Tamale.Anchor.Ordinal{refs: [id | _]} ->
            Map.fetch(ws.side.elements_by_id, id)

          _other ->
            {:error, :unsupported_anchor}
        end
      end,
      target: {:port, :synth, :lyric}
    }
  end

  defp channels, do: %{lyric: lyric_channel()}

  # ---- Tests ----

  test "empty patch list resolves to empty interventions", %{ws: ws} do
    assert {:ok, %{interventions: interventions, survivors: []}} =
             Resolve.run_check(ws, channels())

    assert interventions == %{}
  end

  test "all patches resolve and fold into interventions", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60, lyric: "ら"})
    ws = attach_lyric_patch(ws, "n1", %{lyric: "らん"})

    assert {:ok, %{interventions: interventions, survivors: survivors}} =
             Resolve.run_check(ws, channels())

    assert interventions == %{{:port, :synth, :lyric} => %{input: %{lyric: "らん"}}}
    assert [%Patch{track_id: @track, channel: :lyric}] = survivors
  end

  test "stale base digest vetoes the batch — no silent apply", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60, lyric: "ら"})
    ws = attach_lyric_patch(ws, "n1", %{lyric: "らん"})

    assert {:ok, _} = Resolve.run_check(ws, channels())

    # The content changes out from under the mounted patch.
    ws = put_in(ws.side.elements_by_id["n1"], %{pitch: 60, lyric: "り"})

    assert {:error, {:check_failed, [entry]}} = Resolve.run_check(ws, channels())
    assert entry.kind == :conflict
    assert entry.channel == :lyric
    assert entry.track_id == @track
  end

  test "all failures are aggregated, not short-circuited", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60})
    ws = insert_note(ws, "n2", "n1", {480, 960}, %{pitch: 62})
    ws = attach_lyric_patch(ws, "n1", %{lyric: "x"})
    ws = attach_lyric_patch(ws, "n2", %{lyric: "y"})

    ws = put_in(ws.side.elements_by_id["n1"], %{pitch: 61})
    ws = put_in(ws.side.elements_by_id["n2"], %{pitch: 63})

    assert {:error, {:check_failed, entries}} = Resolve.run_check(ws, channels())
    assert length(entries) == 2
    assert Enum.all?(entries, &(&1.kind == :conflict))
  end

  test "patch anchored on a deleted note is a transport failure", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60})
    ws = attach_lyric_patch(ws, "n1", %{lyric: "x"})

    {:ok, ops, changes} = Operate.lower({:delete_note, @track, "n1"}, ws, %Operate.Config{})
    {:ok, ws} = Workspace.apply_batch(ws, @track, ws.edit_version, ops, changes)

    assert {:error, {:check_failed, [entry]}} = Resolve.run_check(ws, channels())
    assert entry.kind == :transport
  end

  test "patch on an unknown channel is rejected", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60})

    {:ok, cp} =
      Patch.new(%{
        track_id: @track,
        channel: :pitch,
        anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: ws.tracks[@track].version},
        patch: %Tamale.Patch{base_digest: "whatever", payload: %{}}
      })

    ws = Workspace.attach_patch(ws, cp)

    assert {:error, {:check_failed, [entry]}} = Resolve.run_check(ws, channels())
    assert entry.kind == :unknown_channel
    assert entry.channel == :pitch
  end

  test "function target fans a payload out to multiple ports", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60, lyric: "ら"})
    ws = attach_lyric_patch(ws, "n1", %{lyric: "らん", energy: 80})

    fanout = fn payload ->
      [{{:port, :synth, :lyric}, payload.lyric}, {{:port, :synth, :energy}, payload.energy}]
    end

    channels = %{lyric: %{lyric_channel() | target: fanout}}

    assert {:ok, %{interventions: interventions}} = Resolve.run_check(ws, channels)

    assert interventions == %{
             {:port, :synth, :lyric} => %{input: "らん"},
             {:port, :synth, :energy} => %{input: 80}
           }
  end

  test "end-to-end: resolve, then engine check + render", %{ws: ws} do
    ws = insert_note(ws, "n1", :head, {0, 480}, %{pitch: 60, lyric: "ら"})
    ws = attach_lyric_patch(ws, "n1", %{lyric: "らん"})

    {:ok, %{interventions: interventions}} = Resolve.run_check(ws, channels())
    {:ok, request} = Request.new(%{workspace: ws, interventions: interventions})

    assert :ok = Engine.run_check(MockEngine, request)
    assert {:ok, artifact} = Engine.run_render(MockEngine, request)
    assert artifact.overrides == interventions
    assert artifact.notes["n1"].span == {0, 480}
    assert artifact.notes["n1"].lyric == "ら"
  end
end
