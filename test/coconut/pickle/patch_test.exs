defmodule Coconut.Pickle.PatchTest do
  use ExUnit.Case, async: true

  import Coconut.PickleHelper

  alias Coconut.Edit.Patch
  alias Coconut.Pickle.Patch, as: PicklePatch
  alias Tamale.Anchor.{Metric, Ordinal}

  defp build_patch(anchor) do
    {:ok, tamale_patch} = Tamale.Patch.new(%{"base" => [1, 2]}, [[0, 60], [480, 62]])

    {:ok, patch} =
      Patch.new(%{
        id: "Patch_1",
        track_id: "vocal",
        anchor: anchor,
        patch: tamale_patch,
        channel: :pitch
      })

    patch
  end

  describe "dump/1 + load/1 round-trip" do
    test "patch with Metric anchor round-trips" do
      patch = build_patch(%Metric{coord: :tick, from: 0, to: 480, at_version: 2})
      assert {:ok, dumped} = PicklePatch.dump(patch)

      assert dumped.id == "Patch_1"
      assert dumped.channel == :pitch
      assert dumped.anchor.module == Metric
      assert dumped.patch.module == Tamale.Patch
      assert is_binary(dumped.patch.base_digest)
      assert dumped.patch.payload == [[0, 60], [480, 62]]

      assert_pickle_conform(dumped)
      assert {:ok, loaded} = PicklePatch.load(dumped)
      assert loaded == patch
    end

    test "patch with Ordinal anchor and nil id round-trips" do
      patch =
        build_patch(%Ordinal{refs: ["n1", "n2"], adjacent?: true, at_version: 0})

      {:ok, patch} = Patch.new(Map.from_struct(patch) |> Map.put(:id, nil))

      assert {:ok, dumped} = PicklePatch.dump(patch)
      assert dumped.id == nil
      assert_pickle_conform(dumped)
      assert {:ok, loaded} = PicklePatch.load(dumped)
      assert loaded == patch
    end
  end

  describe "load/1 invalid input" do
    test "invalid anchor dump is an error tuple, not a raise" do
      assert {:error, {:invalid_anchor_dump, "nowhere"}} =
               PicklePatch.load(%{
                 id: "p1",
                 track_id: "vocal",
                 anchor: "nowhere",
                 patch: %{module: Tamale.Patch, base_digest: "d", payload: []},
                 channel: :pitch
               })
    end

    test "invalid tamale patch dump is an error tuple" do
      assert {:error, {:invalid_tamale_patch_dump, %{payload: []}}} =
               PicklePatch.load(%{
                 id: "p1",
                 track_id: "vocal",
                 anchor: %{module: Ordinal, refs: ["n1"], adjacent?: false, at_version: 0},
                 patch: %{payload: []},
                 channel: :pitch
               })
    end

    test "unsupported Metric coord surfaces Patch.new/1's validation error" do
      assert {:error, {:unsupported_coord, :seconds}} =
               PicklePatch.load(%{
                 id: "p1",
                 track_id: "vocal",
                 anchor: %{module: Metric, coord: :seconds, from: 0, to: 1, at_version: 0},
                 patch: %{module: Tamale.Patch, base_digest: "d", payload: []},
                 channel: :pitch
               })
    end

    test "non-map input is an error tuple" do
      assert {:error, {:invalid_patch_dump, 42}} = PicklePatch.load(42)
    end
  end
end
