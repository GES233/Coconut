defmodule Coconut.Pickle.HistoryTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.{Command, History, Patch}
  alias Coconut.Edit.Operations.{DeleteNote, DragNote, InsertNote}
  alias Coconut.Pickle.History, as: PickleHistory
  alias Coconut.Pickle.Track, as: PickleTrack
  alias Coconut.Scenario
  alias Coconut.Score.Note

  import Coconut.PickleHelper

  @registry PickleTrack.default_registry()

  # 一棵含多种 record、checkpoint（interval=2）和分支的历史树。
  defp build_history do
    ws = Scenario.base_workspace()
    hist = History.new(ws, checkpoint_interval: 2)

    hist = apply!(hist, insert("n1", :head, {0, 480}))
    hist = apply!(hist, insert("n2", "n1", {480, 960}))
    hist = run!(hist, Command.put_track_extras("vocal", %{neume: %{globals: %{energy: 1.5}}}))
    hist = run!(hist, Command.attach_patches([build_patch(hist, "n1")]))

    # undo 后写入 → 分叉（fork 点拿 checkpoint）
    {:ok, hist} = History.undo(hist)
    hist = apply!(hist, %DeleteNote{track_id: "vocal", note_id: "n2"})
    apply!(hist, drag("n1", {240, 720}))
  end

  defp insert(id, after_id, span),
    do: %InsertNote{
      track_id: "vocal",
      note_id: id,
      after_id: after_id,
      span: span,
      attrs: %{pitch: 62}
    }

  defp drag(id, new_span) do
    %DragNote{
      track_id: "vocal",
      note_id: id,
      after_id: :head,
      old_span: {0, 480},
      new_span: new_span
    }
  end

  defp build_patch(hist, note_id) do
    track = Map.fetch!(hist.present.tracks, "vocal")
    element = Map.fetch!(track.elements_by_id, note_id)
    {:ok, tp} = Tamale.Patch.new(Note.to_canonical(element), %{lyric: "らん"})

    {:ok, patch} =
      Patch.new(%{
        track_id: "vocal",
        channel: :lyric,
        anchor: %Tamale.Anchor.Ordinal{refs: [note_id], at_version: track.space.version},
        patch: tp
      })

    patch
  end

  defp apply!(hist, req) do
    {:ok, hist} = History.apply(hist, req)
    hist
  end

  defp run!(hist, command) do
    {:ok, hist} = History.run(hist, command)
    hist
  end

  test "dump 产物满足 pickle 约定" do
    assert {:ok, dumped} = PickleHistory.dump(build_history(), @registry)
    assert_pickle_conform(dumped)
  end

  test "往返后 present / 游标 / 全节点状态逐位一致" do
    hist = build_history()

    assert {:ok, dumped} = PickleHistory.dump(hist, @registry)
    assert {:ok, restored} = PickleHistory.load(dumped, @registry)

    assert restored.cursor == hist.cursor
    assert restored.seq == hist.seq
    assert restored.base_seq == hist.base_seq
    assert restored.checkpoint_interval == hist.checkpoint_interval
    assert restored.max_edges == hist.max_edges
    assert restored.present == hist.present

    # 每个活节点的 materialize 结果一致（含分支另一臂）。
    for seq <- hist.base_seq..hist.seq do
      assert {:ok, ws} = History.state_at(restored, seq)
      assert {:ok, ^ws} = History.state_at(hist, seq)
    end

    # 恢复后 traversal 继续可用：undo 到分叉前再 redo 回来。
    {:ok, undone} = History.undo(restored)
    {:ok, undone_original} = History.undo(hist)
    assert undone.present == undone_original.present
  end

  test "restore 复检窗口不变量" do
    hist = build_history()
    {:ok, dumped} = PickleHistory.dump(hist, @registry)

    # 游标越出窗口
    bad = %{dumped | cursor: dumped.seq + 1}
    assert {:error, {:invalid_history_window, _}} = PickleHistory.load(bad, @registry)

    # 窗口不稠密（挖掉中间节点）
    middle = div(hist.base_seq + hist.seq, 2)
    bad = %{dumped | nodes: Map.delete(dumped.nodes, middle)}
    assert {:error, {:non_dense_history_window, _}} = PickleHistory.load(bad, @registry)

    # 根节点缺 checkpoint
    bad = put_in(dumped.nodes[dumped.base_seq].checkpoint, nil)
    assert {:error, {:missing_root_checkpoint, _}} = PickleHistory.load(bad, @registry)

    assert {:error, {:invalid_history_dump, _}} = PickleHistory.load("nope", @registry)
  end
end
