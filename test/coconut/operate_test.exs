defmodule Coconut.OperateTest do
  use ExUnit.Case, async: true

  alias Coconut.{Operate, Workspace}
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

    {:ok, ws: ws}
  end

  describe "validate" do
    test "rejects unknown track", %{ws: ws} do
      assert {:error, {:unknown_track, :bad}} =
               Operate.validate({:insert_note, :bad, "n1", :head, {0, 480}, %{}}, ws)
    end

    test "insert: rejects duplicate id", %{ws: ws} do
      # insert first
      {:ok, ops, changes} = Operate.lower({:insert_note, @track, "n1", :head, {0, 480}, %{pitch: 60}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      # try insert same id again
      assert {:error, {:id_conflict, "n1"}} =
               Operate.validate({:insert_note, @track, "n1", :head, {480, 960}, %{}}, ws)
    end

    test "insert: rejects invalid span", %{ws: ws} do
      assert {:error, {:invalid_span, {480, 0}}} =
               Operate.validate({:insert_note, @track, "n1", :head, {480, 0}, %{}}, ws)
    end

    test "delete: rejects unknown id", %{ws: ws} do
      assert {:error, {:unknown_id, "nope"}} =
               Operate.validate({:delete_note, @track, "nope"}, ws)
    end

    test "move: rejects self-reference", %{ws: ws} do
      {:ok, ops, changes} = Operate.lower({:insert_note, @track, "n1", :head, {0, 480}, %{}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      assert {:error, {:self_referential, "n1"}} =
               Operate.validate({:move_note, @track, "n1", "n1"}, ws)
    end
  end

  describe "lower" do
    test "insert gives Insert op + element + span", %{ws: ws} do
      assert {:ok, [%Tamale.Op.Insert{id: "n1", after_id: :head}], changes} =
               Operate.lower({:insert_note, @track, "n1", :head, {0, 480}, %{pitch: 60}}, ws, %Operate.Config{})

      assert changes.elements == %{"n1" => %{pitch: 60}}
      assert changes.span_snapshot == %{"n1" => {0, 480}}
    end

    test "delete gives Delete op + tombstones", %{ws: ws} do
      assert {:ok, [%Tamale.Op.Delete{id: "n1"}], changes} =
               Operate.lower({:delete_note, @track, "n1"}, ws, %Operate.Config{})

      assert changes.elements == %{"n1" => :delete}
      assert changes.span_snapshot == %{"n1" => :delete}
    end

    test "move gives Move op only, no side changes", %{ws: ws} do
      assert {:ok, [%Tamale.Op.Move{id: "n1", after_id: "n2"}], changes} =
               Operate.lower({:move_note, @track, "n1", "n2"}, ws, %Operate.Config{})

      assert changes.elements == %{}
      assert changes.span_snapshot == %{}
    end

    test "drag gives Move + Retime + span update", %{ws: ws} do
      assert {:ok, ops, changes} =
               Operate.lower(
                 {:drag_note, @track, "n1", "n2", {0, 480}, {100, 580}},
                 ws,
                 %Operate.Config{}
               )

      assert length(ops) == 2
      assert %Tamale.Op.Move{id: "n1", after_id: "n2"} in ops
      assert %Tamale.Op.Retime{id: "n1", old_span: {0, 480}, new_span: {100, 580}} in ops
      assert changes.span_snapshot == %{"n1" => {100, 580}}
    end

    test "edit_note gives no ops, :touch marker", %{ws: ws} do
      assert {:ok, [], changes} =
               Operate.lower({:edit_note, @track, "n1", %{lyric: "ら"}}, ws, %Operate.Config{})

      assert changes.elements == %{"n1" => :touch}
      assert changes.span_snapshot == %{}
    end
  end

  describe "apply_batch" do
    test "version conflict rejects stale write", %{ws: ws} do
      {:ok, ops, changes} = Operate.lower({:insert_note, @track, "n1", :head, {0, 480}, %{}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      # try again with stale version
      assert {:error, {:version_conflict, _}} =
               Workspace.apply_batch(ws, @track, 0, ops, changes)
    end

    test "insert populates space + side", %{ws: ws} do
      {:ok, ops, changes} = Operate.lower({:insert_note, @track, "n1", :head, {0, 480}, %{pitch: 60}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      # Space updated
      space = ws.tracks[@track]
      assert space.version == 1
      assert space.ids == ["n1"]

      # Side updated
      assert ws.edit_version == 1
      assert ws.side.elements_by_id["n1"] == %{pitch: 60}
      assert ws.side.spans_by_version[@track][1] == %{"n1" => {0, 480}}
    end

    test "full insert-then-delete cycle", %{ws: ws} do
      # Insert
      {:ok, ops, changes} = Operate.lower({:insert_note, @track, "n1", :head, {0, 480}, %{pitch: 60}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)
      assert ws.side.elements_by_id["n1"] == %{pitch: 60}

      # Delete
      {:ok, ops2, changes2} = Operate.lower({:delete_note, @track, "n1"}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      # Gone from elements, span marked deleted
      refute Map.has_key?(ws.side.elements_by_id, "n1")
      refute Map.has_key?(ws.side.spans_by_version[@track][2], "n1")

      # Space has empty ids, "n1" in seen
      space = ws.tracks[@track]
      assert space.ids == []
      assert MapSet.member?(space.seen, "n1")
    end

    test "drag updates span_snapshot only, not elements", %{ws: ws} do
      # Insert a note first
      {:ok, ops, changes} = Operate.lower({:insert_note, @track, "n1", :head, {0, 480}, %{pitch: 60}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      # Drag it
      {:ok, ops2, changes2} =
        Operate.lower({:drag_note, @track, "n1", :head, {0, 480}, {100, 580}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      # Element unchanged
      assert ws.side.elements_by_id["n1"] == %{pitch: 60}
      # Span updated
      assert ws.side.spans_by_version[@track][2]["n1"] == {100, 580}
      # Old version's span preserved
      assert ws.side.spans_by_version[@track][1]["n1"] == {0, 480}
    end
  end


  describe "transport_patches" do
    test "ordinal anchor survives after insert", %{ws: ws} do
      # Insert a note, then attach a patch with an ordinal anchor
      {:ok, ops, changes} = Operate.lower({:insert_note, @track, "n1", :head, {0, 480}, %{pitch: 60}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, cp} = Coconut.Patch.new(%{
        track_id: @track,
        anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: 1},
        patch: %Tamale.Patch{base_digest: "abc", payload: %{lyric: "ら"}}
      })
      ws = put_in(ws.side.patches, [cp])

      {:ok, survivors, dead} = Workspace.transport_patches(ws, @track)
      assert length(survivors) == 1
      assert dead == []
      # anchor updated to head version (1, since no new ops)
      assert hd(survivors).anchor.at_version == 1
    end

    test "ordinal anchor dies after delete", %{ws: ws} do
      {:ok, ops, changes} = Operate.lower({:insert_note, @track, "n1", :head, {0, 480}, %{}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, cp} = Coconut.Patch.new(%{
        track_id: @track,
        anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: 1},
        patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
      })
      ws = put_in(ws.side.patches, [cp])

      # Delete the note
      {:ok, ops2, changes2} = Operate.lower({:delete_note, @track, "n1"}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      {:ok, survivors, dead} = Workspace.transport_patches(ws, @track)
      assert survivors == []
      assert length(dead) == 1
    end

    test "ordinal anchor survives move (identity follows)", %{ws: ws} do
      {:ok, ops, changes} = Operate.lower({:insert_note, @track, "n1", :head, {0, 480}, %{}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, ops2, changes2} = Operate.lower({:insert_note, @track, "n2", "n1", {480, 960}, %{}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      {:ok, cp} = Coconut.Patch.new(%{
        track_id: @track,
        anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: 2},
        patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
      })
      ws = put_in(ws.side.patches, [cp])

      # Move n1 after n2
      {:ok, ops3, changes3} = Operate.lower({:move_note, @track, "n1", "n2"}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 2, ops3, changes3)

      {:ok, survivors, dead} = Workspace.transport_patches(ws, @track)
      assert length(survivors) == 1
      assert dead == []
      assert hd(survivors).anchor.refs == ["n1"]
      assert hd(survivors).anchor.at_version == 3
    end

    test "metric anchor rejected without warp_provider", %{ws: ws} do
      {:ok, ops, changes} = Operate.lower({:insert_note, @track, "n1", :head, {0, 480}, %{}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, cp} = Coconut.Patch.new(%{
        track_id: @track,
        anchor: %Tamale.Anchor.Metric{
          coord: :tick,
          from: 100,
          to: 200,
          at_version: 1
        },
        patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
      })
      ws = put_in(ws.side.patches, [cp])

      {:ok, survivors, dead} = Workspace.transport_patches(ws, @track)
      assert survivors == []
      assert [{^cp, {:error, :warp_provider_required}}] = dead
    end

    test "patches for other tracks pass through", %{ws: ws} do
      other_track = :harmony
      ws = put_in(ws.tracks[other_track], %Tamale.Space{})

      # Insert in @track
      {:ok, ops, changes} = Operate.lower({:insert_note, @track, "n1", :head, {0, 480}, %{}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      # Attach patches to both tracks
      {:ok, cp1} = Coconut.Patch.new(%{
        track_id: @track,
        anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: 1},
        patch: %Tamale.Patch{base_digest: "a", payload: %{}}
      })
      {:ok, cp2} = Coconut.Patch.new(%{
        track_id: other_track,
        anchor: %Tamale.Anchor.Ordinal{refs: [], at_version: 0},
        patch: %Tamale.Patch{base_digest: "b", payload: %{}}
      })
      ws = put_in(ws.side.patches, [cp1, cp2])

      {:ok, survivors, dead} = Workspace.transport_patches(ws, @track)
      # cp1 (track @track) transported, cp2 (track :harmony) passed through
      assert length(survivors) == 2
      assert dead == []
    end
  end


    test "relative anchor survives move (ref follows, offsets preserved)", %{ws: ws} do
      {:ok, ops, changes} = Operate.lower({:insert_note, @track, "n1", :head, {0, 480}, %{pitch: 60}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, ops2, changes2} = Operate.lower({:insert_note, @track, "n2", "n1", {480, 960}, %{}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      {:ok, cp} = Coconut.Patch.new(%{
        track_id: @track,
        anchor: %Tamale.Anchor.Relative{ref: "n1", from_offset: 50, to_offset: 100, at_version: 2},
        patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
      })
      ws = put_in(ws.side.patches, [cp])

      # Move n1 after n2
      {:ok, ops3, changes3} = Operate.lower({:move_note, @track, "n1", "n2"}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 2, ops3, changes3)

      # Transport with warp_provider — Relative should NOT use it (dispatch to transport/2)
      wp = Coconut.WarpProvider.tick(ws.side.spans_by_version)
      {:ok, survivors, dead} = Workspace.transport_patches(ws, @track, wp)

      assert dead == []
      assert length(survivors) == 1
      survivor = hd(survivors)
      assert survivor.anchor.ref == "n1"
      assert survivor.anchor.from_offset == {50, 1}
      assert survivor.anchor.to_offset == {100, 1}
      assert survivor.anchor.at_version == 3
    end

    test "relative anchor dies when ref is deleted", %{ws: ws} do
      {:ok, ops, changes} = Operate.lower({:insert_note, @track, "n1", :head, {0, 480}, %{}}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, cp} = Coconut.Patch.new(%{
        track_id: @track,
        anchor: %Tamale.Anchor.Relative{ref: "n1", from_offset: 50, to_offset: 100, at_version: 1},
        patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
      })
      ws = put_in(ws.side.patches, [cp])

      {:ok, ops2, changes2} = Operate.lower({:delete_note, @track, "n1"}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      {:ok, survivors, dead} = Workspace.transport_patches(ws, @track)

      assert survivors == []
      assert length(dead) == 1
    end

end