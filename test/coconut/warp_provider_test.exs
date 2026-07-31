defmodule Coconut.WarpProviderTest do
  use ExUnit.Case, async: true

  alias Coconut.WarpProvider
  alias Tamale.{Op, Warp}

  describe "tick provider (v1: non-ripple)" do
    test "returns identity warp for all op types" do
      wp = WarpProvider.tick(%{})

      # Retime
      assert Warp.identity() ==
               wp.(:tick, {3, [%Op.Retime{id: "n1", old_span: {0, 480}, new_span: {100, 580}}]})

      # Delete
      assert Warp.identity() == wp.(:tick, {2, [%Op.Delete{id: "n1"}]})

      # Insert
      assert Warp.identity() == wp.(:tick, {1, [%Op.Insert{id: "n1", after_id: :head}]})

      # Move
      assert Warp.identity() == wp.(:tick, {3, [%Op.Move{id: "n1", after_id: "n2"}]})

      # Empty ops
      assert Warp.identity() == wp.(:tick, {0, []})
    end

    test "global tick is identity regardless of spans" do
      spans = %{0 => %{"n1" => {0, 480}}, 1 => %{"n1" => {100, 580}}}
      wp = WarpProvider.tick(spans)

      assert Warp.identity() ==
               wp.(:tick, {1, [%Op.Retime{id: "n1", old_span: {0, 480}, new_span: {100, 580}}]})
    end
  end
end
