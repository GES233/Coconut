defmodule Coconut.Pickle.FileTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.{Operation, Workspace}
  alias Coconut.Pickle.File, as: PickleFile
  alias Coconut.Pickle.Track, as: PickleTrack
  alias Coconut.Project
  alias Coconut.Util.ID

  @tag tmp_dir: "pickle_file"
  test "write/3 + read/2 round-trips a project through the version envelope", %{
    tmp_dir: tmp_dir
  } do
    project = build_project()
    registry = PickleTrack.default_registry()
    path = Path.join(tmp_dir, "demo.coconut")

    assert {:ok, ^path} = PickleFile.write(project, registry, path)

    # 信封形状抽查：format 标签 + version + project 载荷（无历史时 history 为 nil）
    envelope = path |> File.read!() |> :erlang.binary_to_term()
    assert %{format: :coconut_project, version: 2, project: dumped, history: nil} = envelope
    assert dumped.id == project.id

    assert {:ok, loaded} = PickleFile.read(path, registry)
    assert loaded == project
  end

  @tag tmp_dir: "pickle_file"
  test "write/4 with :history + read_with_history/2 restores the undo tree", %{
    tmp_dir: tmp_dir
  } do
    project = build_project()
    registry = PickleTrack.default_registry()

    # 用工程 workspace 起一段真实历史：两条边（插音符 + extras 旋钮）。
    history = Coconut.Edit.History.new(project.workspace)

    {:ok, history} =
      Coconut.Edit.History.apply(history, %Coconut.Edit.Operations.InsertNote{
        track_id: "vocal",
        note_id: "n2",
        after_id: "n1",
        span: {480, 960},
        attrs: %{pitch: 65}
      })

    {:ok, history} =
      Coconut.Edit.History.run(
        history,
        Coconut.Edit.Command.put_track_extras("vocal", %{neume: %{globals: %{energy: 1.5}}})
      )

    # 存档两侧必须是同一份会话状态：project 投影自 history.present。
    {:ok, project} =
      Coconut.Project.new(%{
        id: project.id,
        workspace: history.present,
        voicebank: project.voicebank,
        metadata: project.metadata
      })

    path = Path.join(tmp_dir, "with_history.coconut")
    assert {:ok, ^path} = PickleFile.write(project, registry, path, history: history)

    assert {:ok, loaded, restored} = PickleFile.read_with_history(path, registry)
    assert loaded == project
    assert %Coconut.Edit.History{} = restored
    assert restored.present == history.present

    # 恢复的历史可以继续 undo：第一步撤销 extras，第二步撤销音符。
    assert {:ok, restored} = Coconut.Edit.History.undo(restored)

    assert Map.fetch!(restored.present.tracks, "vocal").extras == %{}

    assert {:ok, restored} = Coconut.Edit.History.undo(restored)
    track = Map.fetch!(restored.present.tracks, "vocal")
    assert Map.has_key?(track.elements_by_id, "n2") == false
  end

  @tag tmp_dir: "pickle_file"
  test "read_with_history/2 on a v1 envelope yields a nil history", %{tmp_dir: tmp_dir} do
    project = build_project()
    registry = PickleTrack.default_registry()
    {:ok, dumped} = Coconut.Pickle.Project.dump(project, registry)

    path = Path.join(tmp_dir, "v1.coconut")

    File.write!(
      path,
      :erlang.term_to_binary(%{format: :coconut_project, version: 1, project: dumped})
    )

    assert {:ok, loaded, nil} = PickleFile.read_with_history(path, registry)
    assert loaded == project
  end

  @tag tmp_dir: "pickle_file"
  test "read/2 rejects an unknown format version", %{tmp_dir: tmp_dir} do
    project = build_project()
    registry = PickleTrack.default_registry()
    {:ok, dumped} = Coconut.Pickle.Project.dump(project, registry)

    path = Path.join(tmp_dir, "future.coconut")

    File.write!(
      path,
      :erlang.term_to_binary(%{format: :coconut_project, version: 3, project: dumped})
    )

    assert {:error, {:unsupported_format_version, 3}} = PickleFile.read(path, registry)
  end

  @tag tmp_dir: "pickle_file"
  test "read/2 rejects a foreign format tag", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "other.bin")

    File.write!(
      path,
      :erlang.term_to_binary(%{format: :something_else, version: 1, project: %{}})
    )

    assert {:error, {:invalid_envelope, _}} =
             PickleFile.read(path, PickleTrack.default_registry())
  end

  @tag tmp_dir: "pickle_file"
  test "read/2 wraps garbage bytes as an error tuple, not a raise", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "garbage.coconut")
    File.write!(path, "this is not a term_to_binary payload")

    assert {:error, :invalid_file_contents} =
             PickleFile.read(path, PickleTrack.default_registry())
  end

  test "read/2 on a missing file is an error tuple" do
    assert {:error, :enoent} =
             PickleFile.read(
               "tmp/definitely_missing_pickle_file.coconut",
               %Coconut.Pickle.Registry{}
             )
  end

  # 与 project_test 同形的 workspace 构造（vocal 音符 + tempo 事件）
  defp build_project do
    {:ok, tempo} = Coconut.Edit.Track.new(%{id: "global:tempo", module: Coconut.Edit.Track.Tempo})
    {:ok, vocal} = Coconut.Edit.Track.new(%{id: "vocal", module: Coconut.Edit.Track.Vocal})

    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        tracks: %{"vocal" => vocal},
        globals: %{"global:tempo" => tempo}
      })

    ws =
      [
        %Coconut.Edit.Operations.InsertNote{
          track_id: "global:tempo",
          note_id: "t0",
          after_id: :head,
          span: {0, 1920},
          attrs: %{bpm: 120}
        },
        %Coconut.Edit.Operations.InsertNote{
          track_id: "vocal",
          note_id: "n1",
          after_id: :head,
          span: {0, 480},
          attrs: %{lyric: "ら"}
        }
      ]
      |> Enum.reduce(ws, fn op, ws ->
        {:ok, ops, changes} = Operation.lower(op, ws, %Operation.Config{})
        {:ok, ws} = Workspace.apply_batch(ws, op.track_id, ws.edit_version, ops, changes)
        ws
      end)

    {:ok, project} =
      Project.new(%{
        id: ID.generate_id("Proj_"),
        workspace: ws,
        voicebank: %{name: "OU-xia", engine: :diffsinger, digest: "sha256:abc123"},
        metadata: %{"author" => "q"}
      })

    project
  end
end
