defmodule Coconut.Edit.OperationTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.{Operation, Track, Workspace}
  alias Coconut.Edit.WarpProvider
  alias Coconut.Score.{Key.TwelveET, Note}
  alias Coconut.Util.ID

  @track "vocal"

  setup do
    {:ok, track} = Track.new(%{id: @track, module: Track.Vocal})

    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        tracks: %{@track => track}
      })

    {:ok, ws: ws}
  end

  describe "validate" do
    test "rejects unknown track", %{ws: ws} do
      assert {:error, {:unknown_track, "bad"}} =
               Operation.validate(
                 %Coconut.Edit.Operations.InsertNote{
                   track_id: "bad",
                   note_id: "n1",
                   after_id: :head,
                   span: {0, 480},
                   attrs: %{}
                 },
                 ws
               )
    end

    test "insert: rejects duplicate id", %{ws: ws} do
      # insert first
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{pitch: 60}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      # try insert same id again
      assert {:error, {:id_conflict, "n1"}} =
               Operation.validate(
                 %Coconut.Edit.Operations.InsertNote{
                   track_id: @track,
                   note_id: "n1",
                   after_id: :head,
                   span: {480, 960},
                   attrs: %{}
                 },
                 ws
               )
    end

    test "insert: rejects invalid span", %{ws: ws} do
      assert {:error, {:invalid_span, {480, 0}}} =
               Operation.validate(
                 %Coconut.Edit.Operations.InsertNote{
                   track_id: @track,
                   note_id: "n1",
                   after_id: :head,
                   span: {480, 0},
                   attrs: %{}
                 },
                 ws
               )
    end

    test "delete: rejects unknown id", %{ws: ws} do
      assert {:error, {:unknown_id, "nope"}} =
               Operation.validate(
                 %Coconut.Edit.Operations.DeleteNote{track_id: @track, note_id: "nope"},
                 ws
               )
    end

    test "move: rejects self-reference", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      assert {:error, {:self_referential, "n1"}} =
               Operation.validate(
                 %Coconut.Edit.Operations.MoveNote{
                   track_id: @track,
                   note_id: "n1",
                   after_id: "n1"
                 },
                 ws
               )
    end

    test "split: accepts a split point inside the note span", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      assert :ok =
               Operation.validate(
                 %Coconut.Edit.Operations.SplitNote{
                   track_id: @track,
                   note_id: "n1",
                   at_tick: 240,
                   new_id: "n2"
                 },
                 ws
               )
    end

    test "split: rejects a split point outside the note span", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      assert {:error, {:split_out_of_bounds, {0, 480, 480}}} =
               Operation.validate(
                 %Coconut.Edit.Operations.SplitNote{
                   track_id: @track,
                   note_id: "n1",
                   at_tick: 480,
                   new_id: "n2"
                 },
                 ws
               )
    end

    test "split: validates against the HEAD span version", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      # Drag moves the span to {100, 580}; the old span must no longer count.
      {:ok, ops2, changes2} =
        Operation.lower(
          %Coconut.Edit.Operations.DragNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            old_span: {0, 480},
            new_span: {100, 580}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      # 50 is inside the old span {0, 480} but outside the HEAD span.
      assert {:error, {:split_out_of_bounds, {100, 580, 50}}} =
               Operation.validate(
                 %Coconut.Edit.Operations.SplitNote{
                   track_id: @track,
                   note_id: "n1",
                   at_tick: 50,
                   new_id: "n2"
                 },
                 ws
               )

      assert :ok =
               Operation.validate(
                 %Coconut.Edit.Operations.SplitNote{
                   track_id: @track,
                   note_id: "n1",
                   at_tick: 300,
                   new_id: "n2"
                 },
                 ws
               )
    end
  end

  describe "lower" do
    test "insert gives Insert op + element + span", %{ws: ws} do
      assert {:ok, [%Tamale.Op.Insert{id: "n1", after_id: :head}], changes} =
               Operation.lower(
                 %Coconut.Edit.Operations.InsertNote{
                   track_id: @track,
                   note_id: "n1",
                   after_id: :head,
                   span: {0, 480},
                   attrs: %{pitch: 60}
                 },
                 ws,
                 %Operation.Config{}
               )

      assert %{"n1" => %Note{key: %TwelveET{midi: 60}}} = changes.elements
      assert changes.span_snapshot == %{"n1" => {0, 480}}
    end

    test "delete gives Delete op + tombstones", %{ws: ws} do
      assert {:ok, [%Tamale.Op.Delete{id: "n1"}], changes} =
               Operation.lower(
                 %Coconut.Edit.Operations.DeleteNote{track_id: @track, note_id: "n1"},
                 ws,
                 %Operation.Config{}
               )

      assert changes.elements == %{"n1" => :delete}
      assert changes.span_snapshot == %{"n1" => :delete}
    end

    test "move gives Move op only, no side changes", %{ws: ws} do
      assert {:ok, [%Tamale.Op.Move{id: "n1", after_id: "n2"}], changes} =
               Operation.lower(
                 %Coconut.Edit.Operations.MoveNote{
                   track_id: @track,
                   note_id: "n1",
                   after_id: "n2"
                 },
                 ws,
                 %Operation.Config{}
               )

      assert changes.elements == %{}
      assert changes.span_snapshot == %{}
    end

    test "drag gives Move + Retime + span update", %{ws: ws} do
      assert {:ok, ops, changes} =
               Operation.lower(
                 %Coconut.Edit.Operations.DragNote{
                   track_id: @track,
                   note_id: "n1",
                   after_id: "n2",
                   old_span: {0, 480},
                   new_span: {100, 580}
                 },
                 ws,
                 %Operation.Config{}
               )

      assert length(ops) == 2
      assert %Tamale.Op.Move{id: "n1", after_id: "n2"} in ops
      assert %Tamale.Op.Retime{id: "n1", old_span: {0, 480}, new_span: {100, 580}} in ops
      assert changes.span_snapshot == %{"n1" => {100, 580}}
    end

    test "edit_note gives no ops, upserts the re-cast element", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{pitch: 60}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      assert {:ok, [], changes} =
               Operation.lower(
                 %Coconut.Edit.Operations.EditNote{
                   track_id: @track,
                   note_id: "n1",
                   changes: %{lyric: "ら"}
                 },
                 ws,
                 %Operation.Config{}
               )

      # Partial merge: the lyric is written, the key carries over.
      assert %{"n1" => %Note{key: %TwelveET{midi: 60}, lyric: "ら"}} = changes.elements
      assert changes.span_snapshot == %{}
    end

    test "split gives both halves' spans + inherited element", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{pitch: 60}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      assert {:ok, [%Tamale.Op.Split{id: "n1", children: ["n1", "n2"]}], changes} =
               Operation.lower(
                 %Coconut.Edit.Operations.SplitNote{
                   track_id: @track,
                   note_id: "n1",
                   at_tick: 240,
                   new_id: "n2"
                 },
                 ws,
                 %Operation.Config{}
               )

      assert changes.span_snapshot == %{"n1" => {0, 240}, "n2" => {240, 480}}

      assert %{
               "n2" => %Note{
                 id: "n2",
                 key: %TwelveET{midi: 60}
               }
             } = changes.elements
    end

    test "split without span state is unreachable", %{ws: ws} do
      assert {:error, :unreachable} =
               Operation.lower(
                 %Coconut.Edit.Operations.SplitNote{
                   track_id: @track,
                   note_id: "ghost",
                   at_tick: 240,
                   new_id: "n2"
                 },
                 ws,
                 %Operation.Config{}
               )
    end

    test "merge gives composite span + tombstones", %{ws: ws} do
      {:ok, ops, ch} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{lyric: "ら"}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, ch)

      {:ok, ops, ch} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n2",
            after_id: "n1",
            span: {480, 960},
            attrs: %{lyric: "り"}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops, ch)

      assert {:ok, [%Tamale.Op.Merge{ids: ["n1", "n2"], into: "n1"}], changes} =
               Operation.lower(
                 %Coconut.Edit.Operations.MergeNotes{track_id: @track, note_ids: ["n1", "n2"]},
                 ws,
                 %Operation.Config{}
               )

      assert changes.span_snapshot == %{"n1" => {0, 960}, "n2" => :delete}
      assert changes.elements == %{"n2" => :delete}
    end
  end

  describe "apply_batch" do
    test "version conflict rejects stale write", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      # try again with stale version
      assert {:error, {:version_conflict, _}} =
               Workspace.apply_batch(ws, @track, 0, ops, changes)
    end

    test "insert populates space + side", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{pitch: 60}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      # Space updated
      space = ws.tracks[@track].space
      assert space.version == 1
      assert space.ids == ["n1"]

      # Side updated
      assert ws.edit_version == 1
      assert %Note{key: %TwelveET{midi: 60}} = ws.tracks[@track].elements_by_id["n1"]
      assert ws.tracks[@track].spans_by_version[1] == %{"n1" => {0, 480}}
    end

    test "full insert-then-delete cycle", %{ws: ws} do
      # Insert
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{pitch: 60}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)
      assert %Note{key: %TwelveET{midi: 60}} = ws.tracks[@track].elements_by_id["n1"]

      # Delete
      {:ok, ops2, changes2} =
        Operation.lower(
          %Coconut.Edit.Operations.DeleteNote{track_id: @track, note_id: "n1"},
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      # Gone from elements, span marked deleted
      refute Map.has_key?(ws.tracks[@track].elements_by_id, "n1")
      refute Map.has_key?(ws.tracks[@track].spans_by_version[2], "n1")

      # Space has empty ids, "n1" in seen
      space = ws.tracks[@track].space
      assert space.ids == []
      assert MapSet.member?(space.seen, "n1")
    end

    test "drag updates span_snapshot only, not elements", %{ws: ws} do
      # Insert a note first
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{pitch: 60}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      # Drag it
      {:ok, ops2, changes2} =
        Operation.lower(
          %Coconut.Edit.Operations.DragNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            old_span: {0, 480},
            new_span: {100, 580}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      # Element unchanged
      assert %Note{key: %TwelveET{midi: 60}} = ws.tracks[@track].elements_by_id["n1"]
      # Span updated
      assert ws.tracks[@track].spans_by_version[2]["n1"] == {100, 580}
      # Old version's span preserved
      assert ws.tracks[@track].spans_by_version[1]["n1"] == {0, 480}
    end

    test "split closes the loop: both halves get spans, re-split validates", %{ws: ws} do
      {:ok, ops, ch} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{pitch: 60}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, ch)

      :ok =
        Operation.validate(
          %Coconut.Edit.Operations.SplitNote{
            track_id: @track,
            note_id: "n1",
            at_tick: 240,
            new_id: "n2"
          },
          ws
        )

      {:ok, ops, ch} =
        Operation.lower(
          %Coconut.Edit.Operations.SplitNote{
            track_id: @track,
            note_id: "n1",
            at_tick: 240,
            new_id: "n2"
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops, ch)

      assert Track.latest_span(ws.tracks[@track], "n1") == {0, 240}
      assert Track.latest_span(ws.tracks[@track], "n2") == {240, 480}

      assert %Note{id: "n2", key: %TwelveET{midi: 60}} =
               ws.tracks[@track].elements_by_id["n2"]

      # The right half used to have no span at all — a second split validates now.
      assert :ok =
               Operation.validate(
                 %Coconut.Edit.Operations.SplitNote{
                   track_id: @track,
                   note_id: "n2",
                   at_tick: 360,
                   new_id: "n3"
                 },
                 ws
               )
    end

    test "merge writes composite span, removes absorbed ids", %{ws: ws} do
      {:ok, ops, ch} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{lyric: "ら"}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, ch)

      {:ok, ops, ch} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n2",
            after_id: "n1",
            span: {480, 960},
            attrs: %{lyric: "り"}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops, ch)

      :ok =
        Operation.validate(
          %Coconut.Edit.Operations.MergeNotes{track_id: @track, note_ids: ["n1", "n2"]},
          ws
        )

      {:ok, ops, ch} =
        Operation.lower(
          %Coconut.Edit.Operations.MergeNotes{track_id: @track, note_ids: ["n1", "n2"]},
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 2, ops, ch)

      assert Track.latest_span(ws.tracks[@track], "n1") == {0, 960}
      assert Track.latest_span(ws.tracks[@track], "n2") == nil
      refute Map.has_key?(ws.tracks[@track].elements_by_id, "n2")
      # `into` keeps its own payload — content merging is domain policy.
      assert %Note{lyric: "ら"} = ws.tracks[@track].elements_by_id["n1"]
    end

    test "edit_note merges changes, preserving untouched fields", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{pitch: 60}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.EditNote{
            track_id: @track,
            note_id: "n1",
            changes: %{lyric: "ら"}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops, changes)

      assert %Note{key: %TwelveET{midi: 60}, lyric: "ら"} =
               ws.tracks[@track].elements_by_id["n1"]
    end

    test "unknown track returns an error tuple, not bare :error", %{ws: ws} do
      changes = %{elements: %{}, span_snapshot: %{}, patches_add: [], patches_remove: []}

      assert {:error, {:unknown_track, "nope"}} =
               Workspace.apply_batch(ws, "nope", 0, [], changes)
    end
  end

  describe "workspace side accessors" do
    test "attach_patch appends single and multiple patches", %{ws: ws} do
      {:ok, cp1} =
        Coconut.Edit.Patch.new(%{
          track_id: @track,
          anchor: %Tamale.Anchor.Ordinal{refs: [], at_version: 0},
          patch: %Tamale.Patch{base_digest: "a", payload: %{}}
        })

      {:ok, cp2} =
        Coconut.Edit.Patch.new(%{
          track_id: @track,
          anchor: %Tamale.Anchor.Ordinal{refs: [], at_version: 0},
          patch: %Tamale.Patch{base_digest: "b", payload: %{}}
        })

      {:ok, ws, _minted} = Workspace.attach_patch(ws, cp1)
      assert [%{patch: %Tamale.Patch{base_digest: "a"}, id: id1}] = ws.tracks[@track].patches
      assert is_binary(id1)

      {:ok, ws, _minted} = Workspace.attach_patches(ws, [cp2])

      assert [
               %{patch: %Tamale.Patch{base_digest: "a"}},
               %{patch: %Tamale.Patch{base_digest: "b"}}
             ] =
               ws.tracks[@track].patches
    end

    test "latest_span falls back to the newest recorded version", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, ops2, changes2} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n2",
            after_id: "n1",
            span: {480, 960},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      # Move-only batch: no span snapshot is written at the head version.
      {:ok, ops3, changes3} =
        Operation.lower(
          %Coconut.Edit.Operations.MoveNote{track_id: @track, note_id: "n2", after_id: :head},
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 2, ops3, changes3)

      assert ws.tracks[@track].space.version == 3
      refute Map.has_key?(ws.tracks[@track].spans_by_version, 3)
      assert Track.latest_span(ws.tracks[@track], "n1") == {0, 480}
      assert Track.latest_spans(ws.tracks[@track]) == %{"n1" => {0, 480}, "n2" => {480, 960}}
      assert Track.latest_span(ws.tracks[@track], "nope") == nil
    end
  end

  describe "transport_patches" do
    test "ordinal anchor survives after insert", %{ws: ws} do
      # Insert a note, then attach a patch with an ordinal anchor
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{pitch: 60}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, cp} =
        Coconut.Edit.Patch.new(%{
          track_id: @track,
          anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: 1},
          patch: %Tamale.Patch{base_digest: "abc", payload: %{lyric: "ら"}}
        })

      ws = put_in(ws.tracks[@track].patches, [cp])

      {:ok, survivors, dead} = Track.transport_patches(ws.tracks[@track])
      assert length(survivors) == 1
      assert dead == []
      # anchor updated to head version (1, since no new ops)
      assert hd(survivors).anchor.at_version == 1
    end

    test "ordinal anchor dies after delete", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, cp} =
        Coconut.Edit.Patch.new(%{
          track_id: @track,
          anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: 1},
          patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
        })

      ws = put_in(ws.tracks[@track].patches, [cp])

      # Delete the note — write-time transport inside apply_batch kills it.
      {:ok, ops2, changes2} =
        Operation.lower(
          %Coconut.Edit.Operations.DeleteNote{track_id: @track, note_id: "n1"},
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      assert ws.tracks[@track].patches == []
      assert [{^cp, {:undefined, {:deleted, "n1"}}}] = ws.tracks[@track].dead_patches
    end

    test "ordinal anchor survives move (identity follows)", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, ops2, changes2} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n2",
            after_id: "n1",
            span: {480, 960},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      {:ok, cp} =
        Coconut.Edit.Patch.new(%{
          track_id: @track,
          anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: 2},
          patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
        })

      ws = put_in(ws.tracks[@track].patches, [cp])

      # Move n1 after n2
      {:ok, ops3, changes3} =
        Operation.lower(
          %Coconut.Edit.Operations.MoveNote{track_id: @track, note_id: "n1", after_id: "n2"},
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 2, ops3, changes3)

      {:ok, survivors, dead} = Track.transport_patches(ws.tracks[@track])
      assert length(survivors) == 1
      assert dead == []
      assert hd(survivors).anchor.refs == ["n1"]
      assert hd(survivors).anchor.at_version == 3
    end

    test "metric anchor rejected without warp_provider", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, cp} =
        Coconut.Edit.Patch.new(%{
          track_id: @track,
          anchor: %Tamale.Anchor.Metric{
            coord: :tick,
            from: 100,
            to: 200,
            at_version: 1
          },
          patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
        })

      ws = put_in(ws.tracks[@track].patches, [cp])

      {:ok, survivors, dead} = Track.transport_patches(ws.tracks[@track])
      assert survivors == []
      assert [{^cp, {:error, :warp_provider_required}}] = dead
    end

    test "warp_provider error surfaces as a dead patch, not a crash", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, cp} =
        Coconut.Edit.Patch.new(%{
          track_id: @track,
          anchor: %Tamale.Anchor.Metric{
            coord: :tick,
            from: 100,
            to: 200,
            at_version: 0
          },
          patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
        })

      ws = put_in(ws.tracks[@track].patches, [cp])

      wp = fn :tick, _entry -> {:error, {:warp_construction_failed, :boom}} end

      {:ok, survivors, dead} = Track.transport_patches(ws.tracks[@track], wp)
      assert survivors == []
      assert [{^cp, {:error, {:warp_construction_failed, :boom}}}] = dead
    end

    test "metric anchor follows its note's retime segment", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, cp} =
        Coconut.Edit.Patch.new(%{
          track_id: @track,
          anchor: %Tamale.Anchor.Metric{coord: :tick, from: 100, to: 200, at_version: 1},
          patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
        })

      ws = put_in(ws.tracks[@track].patches, [cp])

      {:ok, ops2, changes2} =
        Operation.lower(
          %Coconut.Edit.Operations.DragNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            old_span: {0, 480},
            new_span: {100, 580}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      wp =
        WarpProvider.tick(
          Track.spans(ws.tracks[@track]),
          ws.tracks[@track].patches
        )

      {:ok, survivors, dead} = Track.transport_patches(ws.tracks[@track], wp)

      assert dead == []
      assert [survivor] = survivors
      assert survivor.anchor.from == {200, 1}
      assert survivor.anchor.to == {300, 1}
      assert survivor.anchor.at_version == 2
    end

    test "metric anchor over a deleted note's span dies", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, cp} =
        Coconut.Edit.Patch.new(%{
          track_id: @track,
          anchor: %Tamale.Anchor.Metric{coord: :tick, from: 100, to: 200, at_version: 1},
          patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
        })

      ws = put_in(ws.tracks[@track].patches, [cp])

      {:ok, ops2, changes2} =
        Operation.lower(
          %Coconut.Edit.Operations.DeleteNote{track_id: @track, note_id: "n1"},
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      # Write-time transport folds the delete's warp hole: the anchor dies
      # inside apply_batch, no explicit transport_patches call needed.
      assert ws.tracks[@track].patches == []
      assert [{^cp, {:undefined, :outside_warp}}] = ws.tracks[@track].dead_patches
    end

    test "patches for other tracks pass through", %{ws: ws} do
      other_track = "harmony"
      {:ok, other} = Track.new(%{id: other_track, module: Track.Vocal})
      ws = put_in(ws.tracks[other_track], other)

      # Insert in @track
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      # Attach patches to both tracks
      {:ok, cp1} =
        Coconut.Edit.Patch.new(%{
          track_id: @track,
          anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: 1},
          patch: %Tamale.Patch{base_digest: "a", payload: %{}}
        })

      {:ok, cp2} =
        Coconut.Edit.Patch.new(%{
          track_id: other_track,
          anchor: %Tamale.Anchor.Ordinal{refs: [], at_version: 0},
          patch: %Tamale.Patch{base_digest: "b", payload: %{}}
        })

      ws = put_in(ws.tracks[@track].patches, [cp1, cp2])

      {:ok, survivors, dead} = Track.transport_patches(ws.tracks[@track])
      # cp1 (track @track) transported, cp2 (track "harmony") passed through
      assert length(survivors) == 2
      assert dead == []
    end
  end

  test "relative anchor survives move (ref follows, offsets preserved)", %{ws: ws} do
    {:ok, ops, changes} =
      Operation.lower(
        %Coconut.Edit.Operations.InsertNote{
          track_id: @track,
          note_id: "n1",
          after_id: :head,
          span: {0, 480},
          attrs: %{pitch: 60}
        },
        ws,
        %Operation.Config{}
      )

    {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

    {:ok, ops2, changes2} =
      Operation.lower(
        %Coconut.Edit.Operations.InsertNote{
          track_id: @track,
          note_id: "n2",
          after_id: "n1",
          span: {480, 960},
          attrs: %{}
        },
        ws,
        %Operation.Config{}
      )

    {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

    {:ok, cp} =
      Coconut.Edit.Patch.new(%{
        track_id: @track,
        anchor: %Tamale.Anchor.Relative{ref: "n1", from_offset: 50, to_offset: 100, at_version: 2},
        patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
      })

    ws = put_in(ws.tracks[@track].patches, [cp])

    # Move n1 after n2
    {:ok, ops3, changes3} =
      Operation.lower(
        %Coconut.Edit.Operations.MoveNote{track_id: @track, note_id: "n1", after_id: "n2"},
        ws,
        %Operation.Config{}
      )

    {:ok, ws} = Workspace.apply_batch(ws, @track, 2, ops3, changes3)

    # Transport with warp_provider — Relative should NOT use it (dispatch to transport/2)
    wp = WarpProvider.tick(Track.spans(ws.tracks[@track]))
    {:ok, survivors, dead} = Track.transport_patches(ws.tracks[@track], wp)

    assert dead == []
    assert length(survivors) == 1
    survivor = hd(survivors)
    assert survivor.anchor.ref == "n1"
    assert survivor.anchor.from_offset == {50, 1}
    assert survivor.anchor.to_offset == {100, 1}
    assert survivor.anchor.at_version == 3
  end

  test "relative anchor dies when ref is deleted", %{ws: ws} do
    {:ok, ops, changes} =
      Operation.lower(
        %Coconut.Edit.Operations.InsertNote{
          track_id: @track,
          note_id: "n1",
          after_id: :head,
          span: {0, 480},
          attrs: %{}
        },
        ws,
        %Operation.Config{}
      )

    {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

    {:ok, cp} =
      Coconut.Edit.Patch.new(%{
        track_id: @track,
        anchor: %Tamale.Anchor.Relative{ref: "n1", from_offset: 50, to_offset: 100, at_version: 1},
        patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
      })

    ws = put_in(ws.tracks[@track].patches, [cp])

    {:ok, ops2, changes2} =
      Operation.lower(
        %Coconut.Edit.Operations.DeleteNote{track_id: @track, note_id: "n1"},
        ws,
        %Operation.Config{}
      )

    {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

    # Write-time transport inside apply_batch kills it on the spot.
    assert ws.tracks[@track].patches == []
    assert [{^cp, {:undefined, {:deleted, "n1"}}}] = ws.tracks[@track].dead_patches
  end

  describe "write-time transport" do
    test "apply_batch transports and persists anchors (at_version advances)", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, cp} =
        Coconut.Edit.Patch.new(%{
          track_id: @track,
          anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: 1},
          patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
        })

      ws = put_in(ws.tracks[@track].patches, [cp])

      {:ok, ops2, changes2} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n2",
            after_id: "n1",
            span: {480, 960},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      # No explicit transport_patches call — the batch itself folded.
      assert [%{anchor: %{at_version: 2}}] = ws.tracks[@track].patches
      assert ws.tracks[@track].dead_patches == []
    end

    test "take_dead_patches returns the graveyard and clears it", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, cp} =
        Coconut.Edit.Patch.new(%{
          track_id: @track,
          anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: 1},
          patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
        })

      ws = put_in(ws.tracks[@track].patches, [cp])

      {:ok, ops2, changes2} =
        Operation.lower(
          %Coconut.Edit.Operations.DeleteNote{track_id: @track, note_id: "n1"},
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, ops2, changes2)

      {dead, ws} = Workspace.take_dead_patches(ws)
      assert [{^cp, {:undefined, {:deleted, "n1"}}}] = dead
      assert ws.tracks[@track].dead_patches == []
    end

    test "patches_add minted by a batch join untransported, removes land first", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: @track,
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, @track, 0, ops, changes)

      {:ok, old} =
        Coconut.Edit.Patch.new(%{
          track_id: @track,
          anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: 1},
          patch: %Tamale.Patch{base_digest: "old", payload: %{}}
        })

      {:ok, fresh} =
        Coconut.Edit.Patch.new(%{
          track_id: @track,
          anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: 1},
          patch: %Tamale.Patch{base_digest: "fresh", payload: %{}}
        })

      ws = put_in(ws.tracks[@track].patches, [old])

      # A content-edit-style batch: no ops, removes the old patch, mints one.
      changes = %{
        elements: %{},
        span_snapshot: %{},
        patches_add: [fresh],
        patches_remove: [old]
      }

      {:ok, ws} = Workspace.apply_batch(ws, @track, 1, [], changes)

      assert ws.tracks[@track].patches == [fresh]
      assert ws.tracks[@track].dead_patches == []
    end

    test "attach_patch mints an id when absent, keeps an explicit one", %{ws: ws} do
      anchor = %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: 1}
      tp = %Tamale.Patch{base_digest: "d", payload: %{}}

      {:ok, p1} = Coconut.Edit.Patch.new(%{track_id: @track, anchor: anchor, patch: tp})

      {:ok, p2} =
        Coconut.Edit.Patch.new(%{
          id: "Patch_explicit",
          track_id: @track,
          anchor: anchor,
          patch: tp
        })

      {:ok, ws, _minted} = Workspace.attach_patches(ws, [p1, p2])

      assert [%{id: minted}, %{id: "Patch_explicit"}] = ws.tracks[@track].patches
      assert is_binary(minted)
    end
  end

  describe "vocal same-track overlap constraint" do
    # n1 [0, 480)、n2 [960, 1440)，中间留缝；半开区间，相邻合法。
    setup %{ws: ws} do
      ws =
        ws
        |> apply_gesture(%Coconut.Edit.Operations.InsertNote{
          track_id: @track,
          note_id: "n1",
          after_id: :head,
          span: {0, 480},
          attrs: %{}
        })
        |> apply_gesture(%Coconut.Edit.Operations.InsertNote{
          track_id: @track,
          note_id: "n2",
          after_id: "n1",
          span: {960, 1440},
          attrs: %{}
        })

      {:ok, ws: ws}
    end

    test "insert overlapping an existing note is rejected", %{ws: ws} do
      assert {:error, {:vocal_overlap_rejected, %{span: {240, 720}, conflicting: ["n1"]}}} =
               Operation.validate(
                 %Coconut.Edit.Operations.InsertNote{
                   track_id: @track,
                   note_id: "n3",
                   after_id: "n1",
                   span: {240, 720},
                   attrs: %{}
                 },
                 ws
               )
    end

    test "low-level batch cannot bypass the whole-track invariant", %{ws: ws} do
      request = %Coconut.Edit.Operations.InsertNote{
        track_id: @track,
        note_id: "n3",
        after_id: "n1",
        span: {240, 720},
        attrs: %{}
      }

      {:ok, ops, changes} = Operation.lower(request, ws, %Operation.Config{})

      assert {:error,
              {:vocal_overlap_rejected, %{id: "n3", span: {240, 720}, conflicting: ["n1"]}}} =
               Workspace.apply_batch(ws, @track, ws.edit_version, ops, changes)
    end

    test "insert abutting existing notes is allowed", %{ws: ws} do
      assert :ok =
               Operation.validate(
                 %Coconut.Edit.Operations.InsertNote{
                   track_id: @track,
                   note_id: "n3",
                   after_id: "n1",
                   span: {480, 960},
                   attrs: %{}
                 },
                 ws
               )
    end

    test "drag onto a neighboring note is rejected", %{ws: ws} do
      assert {:error, {:vocal_overlap_rejected, %{span: {720, 1200}, conflicting: ["n2"]}}} =
               Operation.validate(
                 %Coconut.Edit.Operations.DragNote{
                   track_id: @track,
                   note_id: "n1",
                   after_id: :head,
                   old_span: {0, 480},
                   new_span: {720, 1200}
                 },
                 ws
               )
    end

    test "trim extending over the next note is rejected", %{ws: ws} do
      assert {:error, {:vocal_overlap_rejected, %{span: {0, 1000}, conflicting: ["n2"]}}} =
               Operation.validate(
                 %Coconut.Edit.Operations.TrimNote{
                   track_id: @track,
                   note_id: "n1",
                   old_span: {0, 480},
                   new_span: {0, 1000}
                 },
                 ws
               )
    end

    test "merge whose composite span swallows a third note is rejected", %{ws: ws} do
      ws =
        apply_gesture(ws, %Coconut.Edit.Operations.InsertNote{
          track_id: @track,
          note_id: "n3",
          after_id: "n2",
          span: {1920, 2400},
          attrs: %{}
        })

      # Move 把 n3 排到 n1 之后（序列 n1 n3 n2），merge [n1, n3] 的复合
      # span [0, 2400) 会压住 n2 [960, 1440)
      ws =
        apply_gesture(ws, %Coconut.Edit.Operations.MoveNote{
          track_id: @track,
          note_id: "n3",
          after_id: "n1"
        })

      assert {:error, {:vocal_overlap_rejected, %{span: {0, 2400}, conflicting: ["n2"]}}} =
               Operation.validate(
                 %Coconut.Edit.Operations.MergeNotes{track_id: @track, note_ids: ["n1", "n3"]},
                 ws
               )
    end

    test "merge of abutting notes stays legal", %{ws: ws} do
      assert :ok =
               Operation.validate(
                 %Coconut.Edit.Operations.MergeNotes{track_id: @track, note_ids: ["n1", "n2"]},
                 ws
               )
    end
  end

  defp apply_gesture(ws, req) do
    :ok = Operation.validate(req, ws)
    {:ok, ops, changes} = Operation.lower(req, ws, %Operation.Config{})
    {:ok, ws} = Workspace.apply_batch(ws, req.track_id, ws.edit_version, ops, changes)
    ws
  end
end
