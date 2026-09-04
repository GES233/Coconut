defmodule CoconutTest do
  use ExUnit.Case
  doctest Coconut.Util.Helpers

  alias Coconut.Edit.{Track, Workspace}

  test "workspace construction supplies a usable edit version" do
    assert {:ok, %Workspace{edit_version: 0}} = Workspace.new(%{id: "workspace"})
  end

  test "workspace construction rejects invalid version and tpqn" do
    assert {:error, {:invalid_edit_version, nil}} =
             Workspace.new(%{id: "workspace", edit_version: nil})

    assert {:error, {:invalid_tpqn, 0}} = Workspace.new(%{id: "workspace", tpqn: 0})
  end

  test "workspace construction rejects incomplete track side tables" do
    {:ok, track} =
      Track.new(%{
        id: "vocal",
        module: Track.Vocal,
        space: %Tamale.Space{ids: ["n1"], seen: MapSet.new(["n1"])}
      })

    assert {:error,
            {:track_table_mismatch, %{table: :elements_by_id, missing: ["n1"], extra: []}}} =
             Workspace.new(%{id: "workspace", tracks: %{"vocal" => track}})
  end

  test "new/2 mounts a restored history and rejects a mismatched one" do
    alias Coconut.Edit.Operations.InsertNote
    alias Coconut.Pickle.History, as: PickleHistory
    alias Coconut.Pickle.Track, as: PickleTrack

    ws = Coconut.Scenario.base_workspace()
    {:ok, original} = Coconut.Project.new(%{id: "Proj_restore", workspace: ws})

    assert {:ok, session} = Coconut.new(original)

    assert {:ok, session} =
             Coconut.edit(session, %InsertNote{
               track_id: "vocal",
               note_id: "n1",
               after_id: :head,
               span: {0, 480},
               attrs: %{pitch: 62}
             })

    # 经 pickle 往返模拟跨进程恢复，再挂到新会话上。
    assert {:ok, dumped} = PickleHistory.dump(session.history, PickleTrack.default_registry())
    assert {:ok, restored} = PickleHistory.load(dumped, PickleTrack.default_registry())

    # 恢复的历史 present 领先工程 workspace 一条边：以历史为准挂载。
    project = %Coconut.Project{original | workspace: restored.present}
    assert {:ok, mounted} = Coconut.new(project, history: restored)
    assert Coconut.workspace(mounted) == restored.present
    assert {:ok, undone} = Coconut.undo(mounted)
    assert Coconut.workspace(undone) == ws

    # edit_version 错位的历史拒绝挂载（防错档/损坏）。
    assert {:error, {:history_workspace_mismatch, _, _}} =
             Coconut.new(original, history: restored)
  end
end
