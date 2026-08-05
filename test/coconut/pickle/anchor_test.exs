defmodule Coconut.Pickle.AnchorTest do
  use ExUnit.Case, async: true

  import Coconut.PickleHelper

  alias Coconut.Pickle.Anchor, as: PickleAnchor
  alias Tamale.Anchor.{Metric, Ordinal, Relative}

  describe "dump/1 + load/1 round-trip" do
    test "Ordinal anchor round-trips, including adjacent boundary anchors" do
      for anchor <- [
            %Ordinal{refs: ["n1"], adjacent?: false, at_version: 3},
            %Ordinal{refs: ["n1", "n2"], adjacent?: true, at_version: 7}
          ] do
        assert {:ok, dumped} = PickleAnchor.dump(anchor)
        assert dumped.module == Ordinal
        assert_pickle_conform(dumped)
        assert {:ok, loaded} = PickleAnchor.load(dumped)
        assert loaded == anchor
      end
    end

    test "Metric anchor round-trips integer and rational endpoints" do
      for anchor <- [
            %Metric{coord: :tick, from: 0, to: 480, at_version: 1},
            %Metric{coord: :tick, from: {1, 3}, to: {7, 2}, at_version: 2},
            %Metric{coord: {:frames, 60}, from: 10, to: {25, 2}, at_version: 0}
          ] do
        assert {:ok, dumped} = PickleAnchor.dump(anchor)
        assert dumped.module == Metric
        assert_pickle_conform(dumped)
        assert {:ok, loaded} = PickleAnchor.load(dumped)
        assert loaded == anchor
      end
    end

    test "Metric sentinel coord atoms pass through untouched" do
      anchor = %Metric{coord: :dynamic_tick, from: 0, to: 100, at_version: 4}
      assert {:ok, dumped} = PickleAnchor.dump(anchor)
      assert dumped.coord == :dynamic_tick
      assert {:ok, loaded} = PickleAnchor.load(dumped)
      assert loaded == anchor
    end

    test "Relative anchor round-trips negative and rational offsets" do
      for anchor <- [
            %Relative{ref: "ph3", from_offset: -80, to_offset: 50, at_version: 5},
            %Relative{ref: "ph3", from_offset: {1, 4}, to_offset: {3, 4}, at_version: 6}
          ] do
        assert {:ok, dumped} = PickleAnchor.dump(anchor)
        assert dumped.module == Relative
        assert_pickle_conform(dumped)
        assert {:ok, loaded} = PickleAnchor.load(dumped)
        assert loaded == anchor
      end
    end
  end

  describe "dump shape" do
    test "rational coordinates encode as two-element lists" do
      anchor = %Metric{coord: :tick, from: {1, 3}, to: 480, at_version: 1}
      assert {:ok, dumped} = PickleAnchor.dump(anchor)
      assert dumped.from == [1, 3]
      assert dumped.to == 480
    end
  end

  describe "load/1 invalid input" do
    test "unknown module tag is an error tuple, not a raise" do
      assert {:error, {:invalid_anchor_dump, %{module: No.Such.Anchor}}} =
               PickleAnchor.load(%{module: No.Such.Anchor})
    end

    test "non-map input is an error tuple" do
      assert {:error, {:invalid_anchor_dump, "c4"}} = PickleAnchor.load("c4")
    end

    test "bad coordinate shape is an error tuple" do
      assert {:error, {:invalid_anchor_dump, _}} =
               PickleAnchor.load(%{
                 module: Metric,
                 coord: :tick,
                 from: 1.5,
                 to: 480,
                 at_version: 0
               })
    end

    test "dump of a non-anchor term is an error tuple" do
      assert {:error, {:invalid_anchor, 42}} = PickleAnchor.dump(42)
    end
  end
end
