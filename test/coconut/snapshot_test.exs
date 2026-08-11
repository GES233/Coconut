defmodule Coconut.Render.Engine.SnapshotTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.{Operation, Track, Workspace}
  alias Coconut.Edit.Operations.InsertNote
  alias Coconut.Render.Engine.Snapshot
  alias Coconut.Util.ID

  setup do
    {:ok, vocal} = Track.new(%{id: "vocal", module: Track.Vocal})

    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        tracks: %{"vocal" => vocal}
      })

    {:ok, ws: ws}
  end

  defp apply_gesture(ws, req) do
    :ok = Operation.validate(req, ws)
    {:ok, ops, changes} = Operation.lower(req, ws, %Operation.Config{})
    {:ok, ws} = Workspace.apply_batch(ws, req.track_id, ws.edit_version, ops, changes)
    ws
  end

  test "tracks include the tempo global track with its raw events", %{ws: ws} do
    ws =
      apply_gesture(ws, %InsertNote{
        track_id: "global:tempo",
        note_id: "t0",
        after_id: :head,
        span: {0, 1920},
        attrs: %{bpm: 120}
      })

    {:ok, snap} = Snapshot.from_workspace(ws)

    # 引擎拿得到原始 tempo 事件，而不只是编译后的 tempo_map
    # （tempo ramp 干预 / tempo patch 投影的共同前置，设计文档 §11.7）。
    assert %{module: Track.Tempo, coord: :tick, elements: [{"t0", %{bpm: 120_000}, {0, 1920}}]} =
             snap.tracks["global:tempo"]

    assert snap.tempo_map != nil
  end

  test "an empty tempo track still contributes its (empty) view", %{ws: ws} do
    {:ok, snap} = Snapshot.from_workspace(ws)

    assert %{module: Track.Tempo, coord: :tick, elements: []} = snap.tracks["global:tempo"]
    assert snap.tempo_map == nil
  end
end
