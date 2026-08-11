defmodule Coconut.PatchTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.Patch

  defp tamale_patch, do: %Tamale.Patch{base_digest: "d", payload: %{}}

  defp metric_patch(coord) do
    Patch.new(%{
      track_id: "vocal",
      channel: :energy,
      anchor: %Tamale.Anchor.Metric{coord: coord, from: 0, to: 480, at_version: 0},
      patch: tamale_patch()
    })
  end

  describe "construction-time validation" do
    test "Metric anchor with a supported coord (:tick, :frame) is accepted" do
      assert {:ok, %Patch{}} = metric_patch(:tick)
      assert {:ok, %Patch{}} = metric_patch(:frame)
    end

    test "Metric anchor with an unsupported coord is rejected" do
      assert {:error, {:unsupported_coord, :seconds}} = metric_patch(:seconds)
    end

    test "Ordinal and Relative anchors carry no coord and pass" do
      assert {:ok, %Patch{}} =
               Patch.new(%{
                 track_id: "vocal",
                 channel: :lyric,
                 anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: 0},
                 patch: tamale_patch()
               })

      assert {:ok, %Patch{}} =
               Patch.new(%{
                 track_id: "vocal",
                 channel: :lyric,
                 anchor: %Tamale.Anchor.Relative{ref: "n1", from_offset: 0, to_offset: 480},
                 patch: tamale_patch()
               })
    end
  end
end
