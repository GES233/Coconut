defmodule Coconut.Pickle.WorkspaceTest do
  use ExUnit.Case, async: true

  import Coconut.PickleHelper

  alias Coconut.Edit.{Operation, Workspace}
  alias Coconut.Pickle.{Registry, Track}
  alias Coconut.Pickle.Workspace, as: PickleWorkspace
  alias Coconut.Score.TempoMap
  alias Coconut.Util.ID

  # 照 tempo_test 的方式：Edit.Operation.lower + apply_batch 造 vocal 音符 + tempo 事件
  defp build_workspace do
    {:ok, tempo} = Coconut.Edit.Track.new(%{id: "global:tempo", module: Coconut.Edit.Track.Tempo})
    {:ok, vocal} = Coconut.Edit.Track.new(%{id: "vocal", module: Coconut.Edit.Track.Vocal})

    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        tracks: %{"vocal" => vocal},
        globals: %{"global:tempo" => tempo},
        time_sigs: [{1, {4, 4}}, {5, {3, 4}}]
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
          track_id: "global:tempo",
          note_id: "t1",
          after_id: "t0",
          span: {1920, 3840},
          attrs: %{bpm: 90}
        },
        %Coconut.Edit.Operations.InsertNote{
          track_id: "vocal",
          note_id: "n1",
          after_id: :head,
          span: {0, 480},
          attrs: %{lyric: "ら"}
        },
        %Coconut.Edit.Operations.InsertNote{
          track_id: "vocal",
          note_id: "n2",
          after_id: "n1",
          span: {480, 960},
          attrs: %{lyric: "ー"}
        }
      ]
      |> Enum.reduce(ws, fn op, ws ->
        {:ok, ops, changes} = Operation.lower(op, ws, %Operation.Config{})
        {:ok, ws} = Workspace.apply_batch(ws, op.track_id, ws.edit_version, ops, changes)
        ws
      end)

    ws
  end

  describe "dump/2 + load/2 round-trip" do
    test "workspace with vocal notes and tempo events round-trips" do
      ws = build_workspace()
      registry = Track.default_registry()

      assert {:ok, dumped} = PickleWorkspace.dump(ws, registry)

      assert dumped.id == ws.id
      assert dumped.edit_version == ws.edit_version
      assert dumped.tpqn == 480
      assert dumped.time_sigs == [[1, [4, 4]], [5, [3, 4]]]
      assert Map.keys(dumped.tracks) == ["vocal"]
      assert dumped.globals["global:tempo"].module == "tempo"
      assert dumped.tracks["vocal"].module == "vocal"

      assert_pickle_conform(dumped)

      assert {:ok, loaded} = PickleWorkspace.load(dumped, registry)
      assert loaded == ws
    end

    test "tempo_map behaves identically after the round-trip" do
      ws = build_workspace()
      registry = Track.default_registry()

      {:ok, dumped} = PickleWorkspace.dump(ws, registry)
      {:ok, loaded} = PickleWorkspace.load(dumped, registry)

      {:ok, tm_before} = Workspace.tempo_map(ws)
      {:ok, tm_after} = Workspace.tempo_map(loaded)
      assert tm_after == tm_before

      assert_in_delta TempoMap.tick_to_sec(tm_after, 1920), 2.0, 0.01
    end
  end

  describe "load/2 error paths" do
    test "unknown track type name reports {:unknown_type_name, _}" do
      ws = build_workspace()
      registry = Track.default_registry()
      {:ok, dumped} = PickleWorkspace.dump(ws, registry)

      {:ok, empty} = Registry.new(%{})

      assert {:error, {:unknown_type_name, "vocal"}} = PickleWorkspace.load(dumped, empty)
    end

    test "dump with unregistered track module reports {:unregistered_module, _}" do
      ws = build_workspace()
      {:ok, registry} = Registry.new(%{"tempo" => Coconut.Edit.Track.Tempo})

      assert {:error, {:unregistered_module, Coconut.Edit.Track.Vocal}} =
               PickleWorkspace.dump(ws, registry)
    end

    test "malformed time_sigs entry is an error tuple" do
      ws = build_workspace()
      registry = Track.default_registry()
      {:ok, dumped} = PickleWorkspace.dump(ws, registry)
      bad = %{dumped | time_sigs: [[1, [4, 4]], ["x", [3, 4]]]}

      assert {:error, {:invalid_time_sig_dump, ["x", [3, 4]]}} =
               PickleWorkspace.load(bad, registry)
    end

    test "Workspace.new/1 validation fires on load (invalid time_sigs)" do
      ws = build_workspace()
      registry = Track.default_registry()
      {:ok, dumped} = PickleWorkspace.dump(ws, registry)
      bad = %{dumped | time_sigs: [[2, [4, 4]]]}

      assert {:error, {:invalid_time_sigs, [{2, {4, 4}}]}} = PickleWorkspace.load(bad, registry)
    end

    test "non-map input is an error tuple" do
      registry = Track.default_registry()
      assert {:error, {:invalid_workspace_dump, 42}} = PickleWorkspace.load(42, registry)
    end
  end
end
