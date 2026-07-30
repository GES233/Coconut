defmodule Coconut.WarpProviderTest do
  use ExUnit.Case, async: true

  alias Coconut.{Operate, WarpProvider, Workspace}
  alias Coconut.Util.ID

  @track :vocal

  setup do
    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        tracks: %{@track => %Tamale.Space{}},
        side: %Workspace.Side{}
      })

    wp = WarpProvider.tick(%{})
    {:ok, ws: ws, wp: wp}
  end

  describe "tick/1 closure" do
    test "empty entry returns identity", %{wp: wp} do
      assert wp.(:tick, {1, []}) == Tamale.Warp.identity()
    end

    test "unsupported coord returns error", %{wp: wp} do
      assert wp.(:frames, {1, []}) == {:error, :unsupported_coord}
    end
  end

  describe "Retime" do
    test "produces a warp segment from old_span to new_span", %{wp: wp} do
      warp = wp.(:tick, {1, [%Tamale.Op.Retime{id: "n1", old_span: {0, 480}, new_span: {100, 580}}]})
      refute warp == Tamale.Warp.identity()

      assert Tamale.Warp.at(warp, {0, 1}) == {:ok, {100, 1}}
      assert Tamale.Warp.at(warp, {480, 1}) == {:ok, {580, 1}}
      assert Tamale.Warp.at(warp, {500, 1}) == {:ok, {500, 1}}
    end
  end

  describe "Delete" do
    test "is identity in non-ripple tick space", %{wp: wp} do
      warp = wp.(:tick, {1, [%Tamale.Op.Delete{id: "n1"}]})
      assert warp == Tamale.Warp.identity()
    end
  end

  describe "Insert / Move / Split / Merge" do
    test "all produce identity warp in v1", %{wp: wp} do
      for op <- [
            %Tamale.Op.Insert{id: "n1", after_id: :head},
            %Tamale.Op.Move{id: "n1", after_id: "n2"},
            %Tamale.Op.Split{id: "n1", children: ["n1", "n2"]},
            %Tamale.Op.Merge{ids: ["n1", "n2"], into: "n1"}
          ] do
        assert wp.(:tick, {1, [op]}) == Tamale.Warp.identity()
      end
    end
  end

  describe "transport integration" do
    test "metric anchor follows Retime via warp", %{ws: ws} do
      {:ok, ops, changes} = Operate.lower({:insert_note, @track, "n1", :head, {0, 480}, %{}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, ops2, changes2} =
        Operate.lower({:drag_note, @track, "n1", :head, {0, 480}, {100, 580}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      {:ok, cp} = Coconut.Patch.new(%{
        track_id: @track,
        anchor: %Tamale.Anchor.Metric{coord: :tick, from: 200, to: 300, at_version: 1},
        patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
      })
      ws = put_in(ws.side.patches, [cp])

      wp = WarpProvider.tick(Workspace.track_spans(ws, @track))
      {:ok, survivors, dead} = Workspace.transport_patches(ws, @track, wp)

      assert dead == []
      assert length(survivors) == 1
      survivor = hd(survivors)
      assert survivor.anchor.from == {300, 1}
      assert survivor.anchor.to == {400, 1}
    end

    test "metric anchor survives Delete (non-ripple, coordinates unchanged)", %{ws: ws} do
      {:ok, ops, changes} = Operate.lower({:insert_note, @track, "n1", :head, {0, 480}, %{}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, cp} = Coconut.Patch.new(%{
        track_id: @track,
        anchor: %Tamale.Anchor.Metric{coord: :tick, from: 200, to: 300, at_version: 1},
        patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
      })
      ws = put_in(ws.side.patches, [cp])

      {:ok, ops2, changes2} = Operate.lower({:delete_note, @track, "n1"}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      wp = WarpProvider.tick(Workspace.track_spans(ws, @track))
      {:ok, survivors, dead} = Workspace.transport_patches(ws, @track, wp)

      # Metric anchor survives at same coordinates (non-ripple: coords don't move)
      assert length(survivors) == 1
      assert dead == []
      assert hd(survivors).anchor.from == {200, 1}
    end
  end
end
