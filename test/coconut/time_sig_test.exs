defmodule Coconut.TimeSigTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.Workspace
  alias Coconut.Score.{TimeSig, TimeSigMap}
  alias Coconut.Util.ID

  setup do
    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0
      })

    {:ok, ws: ws}
  end

  describe "time_sigs field" do
    test "defaults to constant 4/4", %{ws: ws} do
      assert ws.time_sigs == [{1, {4, 4}}]
    end

    test "updated via Workspace.set_time_sigs/2 (display data, no edit_version bump)", %{ws: ws} do
      {:ok, ws} = Workspace.set_time_sigs(ws, [{1, {6, 8}}])

      assert ws.time_sigs == [{1, {6, 8}}]
      assert ws.edit_version == 0
    end

    test "update/2 no longer accepts time_sigs (carved out to set_time_sigs/2)", %{ws: ws} do
      assert {:error, {:extra_attrs, [:time_sigs]}} =
               Workspace.update(ws, %{time_sigs: [{1, {6, 8}}]})
    end

    test "rejects malformed event lists", %{ws: ws} do
      assert {:error, {:invalid_time_sigs, []}} = Workspace.set_time_sigs(ws, [])

      assert {:error, {:invalid_time_sigs, _}} =
               Workspace.set_time_sigs(ws, [{2, {4, 4}}])

      assert {:error, {:invalid_time_sigs, _}} =
               Workspace.set_time_sigs(ws, [{1, {4, 4}}, {1, {3, 4}}])

      assert {:error, {:invalid_time_sigs, _}} =
               Workspace.set_time_sigs(ws, [{1, {4, 4}}, {3, {3, 4}}, {2, {6, 8}}])
    end

    test "rejects malformed signature values", %{ws: ws} do
      assert {:error, {:invalid_time_sigs, _}} = Workspace.set_time_sigs(ws, [{1, {0, 4}}])
      assert {:error, {:invalid_time_sigs, _}} = Workspace.set_time_sigs(ws, [{1, {4, 0}}])

      assert {:error, {:invalid_time_sigs, _}} =
               Workspace.set_time_sigs(ws, [{1, {:compound, [], 4}}])

      assert {:error, {:invalid_time_sigs, _}} =
               Workspace.set_time_sigs(ws, [{1, {:compound, [0, 3], 4}}])
    end
  end

  describe "TimeSig.validate/1" do
    test "accepts well-formed signatures" do
      assert :ok = TimeSig.validate({4, 4})
      assert :ok = TimeSig.validate({:standard, 6, 8})
      assert :ok = TimeSig.validate({:compound, [2, 3], 8})
      assert :ok = TimeSig.validate(:san)
    end

    test "rejects malformed signatures" do
      assert {:error, {:invalid_time_sig, {0, 4}}} = TimeSig.validate({0, 4})
      assert {:error, {:invalid_time_sig, {4, 0}}} = TimeSig.validate({4, 0})

      assert {:error, {:invalid_time_sig, {:compound, [], 4}}} =
               TimeSig.validate({:compound, [], 4})

      assert {:error, {:invalid_time_sig, {:compound, [0, 3], 4}}} =
               TimeSig.validate({:compound, [0, 3], 4})

      assert {:error, {:invalid_time_sig, "4/4"}} = TimeSig.validate("4/4")
    end
  end

  describe "time_sig_map/1" do
    test "4/4 at tpqn 480: a bar is 1920 ticks", %{ws: ws} do
      {:ok, map} = Workspace.time_sig_map(ws)

      assert {:ok, 0} = TimeSigMap.bar_to_tick(map, 1)
      assert {:ok, 1920} = TimeSigMap.bar_to_tick(map, 2)
      assert {:ok, 2} = TimeSigMap.tick_to_bar(map, 1920)
      assert {:ok, 1} = TimeSigMap.tick_to_bar(map, 1919)
    end

    test "mid-song meter change: 4/4 for two bars, then 3/4", %{ws: ws} do
      {:ok, ws} = Workspace.set_time_sigs(ws, [{1, {4, 4}}, {3, {3, 4}}])
      {:ok, map} = Workspace.time_sig_map(ws)

      # Bars 1-2 at 4/4 (1920 ticks each), bar 3 onward at 3/4 (1440 ticks).
      assert {:ok, 3840} = TimeSigMap.bar_to_tick(map, 3)
      # 3840 + 1440
      assert {:ok, 5280} = TimeSigMap.bar_to_tick(map, 4)

      assert {:ok, 2} = TimeSigMap.tick_to_bar(map, 3839)
      assert {:ok, 3} = TimeSigMap.tick_to_bar(map, 3840)
      assert {:ok, 4} = TimeSigMap.tick_to_bar(map, 5280)
    end

    test "respects the workspace tpqn", %{ws: ws} do
      {:ok, ws} = Workspace.update(ws, %{tpqn: 960})
      {:ok, map} = Workspace.time_sig_map(ws)

      assert {:ok, 3840} = TimeSigMap.bar_to_tick(map, 2)
    end
  end
end
