defmodule Coconut.Pickle.ProjectTest do
  use ExUnit.Case, async: true

  import Coconut.PickleHelper

  alias Coconut.Edit.{Operation, Workspace}
  alias Coconut.Pickle.Project, as: PickleProject
  alias Coconut.Pickle.Track, as: PickleTrack
  alias Coconut.Project
  alias Coconut.Util.ID

  # 沿用 workspace_test 的构造方式：vocal 音符 + tempo 事件
  defp build_workspace do
    {:ok, tempo} = Coconut.Edit.Track.new(%{id: "global:tempo", module: Coconut.Edit.Track.Tempo})
    {:ok, vocal} = Coconut.Edit.Track.new(%{id: "vocal", module: Coconut.Edit.Track.Vocal})

    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        tracks: %{"vocal" => vocal},
        globals: %{"global:tempo" => tempo}
      })

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
  end

  defp build_project do
    {:ok, project} =
      Project.new(%{
        id: ID.generate_id("Proj_"),
        workspace: build_workspace(),
        voicebank: %{name: "OU-xia", engine: :diffsinger, digest: "sha256:abc123"},
        metadata: %{"author" => "q", "tags" => ["demo", "v1"], "bpm_locked" => true}
      })

    project
  end

  describe "dump/2 + load/2 round-trip" do
    test "project with workspace, voicebank signature and metadata round-trips" do
      project = build_project()
      registry = PickleTrack.default_registry()

      assert {:ok, dumped} = PickleProject.dump(project, registry)

      assert dumped.id == project.id
      refute Map.has_key?(dumped, :engine)
      refute Map.has_key?(dumped, :settings)
      refute Map.has_key?(dumped, :assets)

      assert dumped.voicebank == %{
               name: "OU-xia",
               engine: :diffsinger,
               digest: "sha256:abc123"
             }

      assert dumped.metadata == %{"author" => "q", "tags" => ["demo", "v1"], "bpm_locked" => true}

      assert_pickle_conform(dumped)

      assert {:ok, loaded} = PickleProject.load(dumped, registry)
      assert loaded == project
    end

    test "nil voicebank and nil metadata round-trip" do
      {:ok, project} = Project.new(%{id: ID.generate_id("Proj_"), workspace: build_workspace()})
      registry = PickleTrack.default_registry()

      assert {:ok, dumped} = PickleProject.dump(project, registry)
      assert_pickle_conform(dumped)
      assert {:ok, loaded} = PickleProject.load(dumped, registry)
      assert loaded == project
    end
  end

  describe "Project.new/1 validation" do
    test "missing id is an error" do
      assert {:error, {:missing_id, "Proj_"}} = Project.new(%{workspace: build_workspace()})
    end

    test "workspace is required" do
      assert {:error, {:invalid_workspace, nil}} = Project.new(%{id: ID.generate_id("Proj_")})
    end

    test "voicebank with wrong shape is an error" do
      ws = build_workspace()

      for voicebank <- [
            %{name: "OU-xia", engine: :diffsinger},
            %{name: "OU-xia", engine: :diffsinger, digest: 123},
            %{name: :ou_xia, engine: :diffsinger, digest: "abc"},
            "OU-xia"
          ] do
        assert {:error, {:invalid_voicebank, ^voicebank}} =
                 Project.new(%{id: ID.generate_id("Proj_"), workspace: ws, voicebank: voicebank})
      end
    end

    test "legacy reserved fields are not Project attributes" do
      ws = build_workspace()

      for {field, value} <- [engine: :diffsinger, settings: %{}, assets: []] do
        assert {:error, {:extra_attrs, [^field]}} =
                 Project.new(%{
                   field => value,
                   id: ID.generate_id("Proj_"),
                   workspace: ws
                 })
      end
    end
  end

  describe "load/2 error paths" do
    test "reserved field set in the dump surfaces Project.new/1's error" do
      project = build_project()
      registry = PickleTrack.default_registry()
      {:ok, dumped} = PickleProject.dump(project, registry)
      bad = Map.put(dumped, :settings, %{"gain" => 1})

      assert {:error, {:reserved_field_set, :settings}} = PickleProject.load(bad, registry)
    end

    test "legacy nil fields remain load-compatible" do
      project = build_project()
      registry = PickleTrack.default_registry()
      {:ok, dumped} = PickleProject.dump(project, registry)
      legacy = Map.merge(dumped, %{engine: nil, settings: nil, assets: nil})

      assert {:ok, ^project} = PickleProject.load(legacy, registry)
    end

    test "invalid voicebank shape surfaces Project.new/1's error" do
      project = build_project()
      registry = PickleTrack.default_registry()
      {:ok, dumped} = PickleProject.dump(project, registry)
      bad = %{dumped | voicebank: %{name: "OU-xia"}}

      assert {:error, {:invalid_voicebank, %{name: "OU-xia"}}} =
               PickleProject.load(bad, registry)
    end

    test "non-conform metadata is an error on dump" do
      {:ok, project} =
        Project.new(%{
          id: ID.generate_id("Proj_"),
          workspace: build_workspace(),
          metadata: %{"span" => {0, 480}}
        })

      registry = PickleTrack.default_registry()

      assert {:error, {:non_conform_metadata, %{"span" => {0, 480}}}} =
               PickleProject.dump(project, registry)
    end

    test "non-conform metadata in the dump is an error on load" do
      registry = PickleTrack.default_registry()
      {:ok, dumped} = PickleProject.dump(build_project(), registry)

      # tuple/fun 不会从 JSON 式输入出现，但 load 侧同样守约定
      assert {:error, {:non_conform_metadata, _}} =
               PickleProject.load(%{dumped | metadata: %{1 => fn -> :x end}}, registry)
    end

    test "non-map input is an error tuple" do
      registry = PickleTrack.default_registry()
      assert {:error, {:invalid_project_dump, 42}} = PickleProject.load(42, registry)
    end
  end
end
