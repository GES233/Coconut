defmodule Coconut.WarpProviderTest do
  use ExUnit.Case, async: true

  alias Coconut.WarpProvider
  alias Tamale.{Op, Warp}

  # Span tables are %{version => %{id => {start_tick, end_tick}}}.
  defp provider(spans, patches \\ []), do: WarpProvider.tick(spans, patches)

  describe "identity cases (no warp-relevant ops)" do
    test "empty ops and structural-only ops return identity" do
      wp = provider(%{1 => %{"n1" => {0, 480}}})

      assert Warp.identity() == wp.(:tick, {2, []})
      assert Warp.identity() == wp.(:tick, {2, [%Op.Insert{id: "n2", after_id: "n1"}]})
      assert Warp.identity() == wp.(:tick, {2, [%Op.Move{id: "n1", after_id: :head}]})
      assert Warp.identity() == wp.(:tick, {2, [%Op.Split{id: "n1", children: ["n1", "n2"]}]})
      assert Warp.identity() == wp.(:tick, {2, [%Op.Merge{ids: ["n1", "n2"], into: "n1"}]})
    end
  end

  describe "Retime segments" do
    test "shrink: own span maps linearly, surroundings stay identity" do
      spans = %{1 => %{"n1" => {480, 960}}, 2 => %{"n1" => {480, 720}}}
      wp = provider(spans)

      w = wp.(:tick, {2, [%Op.Retime{id: "n1", old_span: {480, 960}, new_span: {480, 720}}]})

      assert Warp.at!(w, 100) == {:ok, {100, 1}}
      assert Warp.at!(w, 700) == {:ok, {590, 1}}
      assert Warp.map_interval!(w, 480, 960) == {:ok, {{480, 1}, {720, 1}}}
    end

    test "drag batch (Move + Retime): only Retime contributes" do
      spans = %{1 => %{"n1" => {0, 480}}, 2 => %{"n1" => {100, 580}}}
      wp = provider(spans)

      w =
        wp.(
          :tick,
          {2,
           [
             %Op.Move{id: "n1", after_id: "n2"},
             %Op.Retime{id: "n1", old_span: {0, 480}, new_span: {100, 580}}
           ]}
        )

      assert Warp.map_interval!(w, 0, 480) == {:ok, {{100, 1}, {580, 1}}}
      # the region the note vacated/overran is not covered
      assert Warp.at!(w, 500) == :undefined
    end

    test "zero-length new span is a hole, not a degenerate segment" do
      wp = provider(%{1 => %{"n1" => {0, 480}}})

      w = wp.(:tick, {2, [%Op.Retime{id: "n1", old_span: {0, 480}, new_span: {200, 200}}]})

      assert Warp.at!(w, 100) == :undefined
    end

    test "overlapping retime segments collapse into one hole" do
      spans = %{1 => %{"n1" => {0, 480}, "n2" => {240, 720}}}
      wp = provider(spans)

      w =
        wp.(
          :tick,
          {2,
           [
             %Op.Retime{id: "n1", old_span: {0, 480}, new_span: {0, 240}},
             %Op.Retime{id: "n2", old_span: {240, 720}, new_span: {480, 960}}
           ]}
        )

      assert Warp.at!(w, 300) == :undefined
      assert Warp.map_interval!(w, 0, 240) == :undefined
      assert Warp.at!(w, 800) == {:ok, {800, 1}}
    end

    test "identical segments from a multi-note batch deduplicate" do
      spans = %{1 => %{"n1" => {0, 480}, "n2" => {0, 480}}}
      wp = provider(spans)

      w =
        wp.(
          :tick,
          {2,
           [
             %Op.Retime{id: "n1", old_span: {0, 480}, new_span: {0, 240}},
             %Op.Retime{id: "n2", old_span: {0, 480}, new_span: {0, 240}}
           ]}
        )

      assert Warp.at!(w, 120) == {:ok, {60, 1}}
      assert Warp.map_interval!(w, 0, 480) == {:ok, {{0, 1}, {240, 1}}}
    end
  end

  describe "Delete holes" do
    test "deleted span has no image, surroundings stay identity" do
      spans = %{1 => %{"n1" => {480, 960}}}
      wp = provider(spans)

      w = wp.(:tick, {2, [%Op.Delete{id: "n1"}]})

      assert Warp.at!(w, 700) == :undefined
      assert Warp.at!(w, 100) == {:ok, {100, 1}}

      assert Warp.map_interval!(w, 240, 700) ==
               {:clip, [{{240, 1}, {480, 1}}], [{{480, 1}, {700, 1}}]}
    end

    test "delete of an id missing from the span table is identity" do
      wp = provider(%{1 => %{"n1" => {0, 480}}})

      assert Warp.identity() == wp.(:tick, {2, [%Op.Delete{id: "ghost"}]})
    end

    test "delete reads the pre-batch snapshot, not the latest" do
      # v2 retimed n1; v3 deletes it — the hole must use v2's span.
      spans = %{1 => %{"n1" => {0, 480}}, 2 => %{"n1" => {100, 580}}}
      wp = provider(spans)

      w = wp.(:tick, {3, [%Op.Delete{id: "n1"}]})

      assert Warp.at!(w, 300) == :undefined
      assert Warp.at!(w, 50) == {:ok, {50, 1}}
    end

    test "delete reads through sparse snapshots (Move-only batches write none)" do
      # v2 was Move-only, so the newest snapshot at or before v2 is v1's.
      spans = %{1 => %{"n1" => {0, 480}, "n2" => {480, 960}}}
      wp = provider(spans)

      w = wp.(:tick, {3, [%Op.Delete{id: "n1"}]})

      assert Warp.at!(w, 100) == :undefined
      assert Warp.at!(w, 600) == {:ok, {600, 1}}
    end
  end

  describe "domain bound" do
    test "extends to live patch anchors beyond all spans" do
      spans = %{1 => %{"n1" => {0, 480}}}

      patch = %Coconut.Patch{
        track_id: "vocal",
        channel: :energy,
        anchor: %Tamale.Anchor.Metric{coord: :tick, from: 4800, to: 5000, at_version: 1},
        patch: %Tamale.Patch{base_digest: "d", payload: %{}}
      }

      wp = provider(spans, [patch])

      w = wp.(:tick, {2, [%Op.Retime{id: "n1", old_span: {0, 480}, new_span: {0, 240}}]})

      assert Warp.map_interval!(w, 4800, 5000) == {:ok, {{4800, 1}, {5000, 1}}}
    end
  end

  test "supported_coords advertises :tick only" do
    assert WarpProvider.supported_coords() == [:tick]
  end

  describe "for_coord/3" do
    test ":tick dispatches to the tick builder" do
      spans = %{1 => %{"n1" => {480, 960}}, 2 => %{"n1" => {480, 720}}}
      wp = WarpProvider.for_coord(:tick, spans)

      w = wp.(:tick, {2, [%Op.Retime{id: "n1", old_span: {480, 960}, new_span: {480, 720}}]})

      assert Warp.at!(w, 700) == {:ok, {590, 1}}
    end

    test "a coord without a builder entry returns nil" do
      assert WarpProvider.for_coord(:frame, %{1 => %{"n1" => {0, 480}}}) == nil
      # ...and supported_coords/0 (the Patch.new guard source) agrees
      refute :frame in WarpProvider.supported_coords()
    end
  end
end
