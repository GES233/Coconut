defmodule Coconut.Edit.CrossTrackDragTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.{History, Operation, Patch, Track, Workspace}
  alias Coconut.Edit.Operations.{DragNoteAcrossTracks, InsertNote}
  alias Coconut.Score.{Key, Note}
  alias Coconut.Util.ID

  @a "vocal_a"
  @b "vocal_b"

  # ---- Helpers ----

  defp base_workspace do
    {:ok, a} = Track.new(%{id: @a, module: Track.Vocal})
    {:ok, b} = Track.new(%{id: @b, module: Track.Vocal})

    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        tracks: %{@a => a, @b => b}
      })

    ws
  end

  defp insert(ws, track_id, id, span) do
    req = %InsertNote{
      track_id: track_id,
      note_id: id,
      after_id: :head,
      span: span,
      attrs: %{pitch: 60, lyric: "ら"}
    }

    :ok = Operation.validate(req, ws)
    {:ok, ops, changes} = Operation.lower(req, ws, %Operation.Config{})
    {:ok, ws} = Workspace.apply_batch(ws, track_id, ws.edit_version, ops, changes)
    ws
  end

  defp drag_req(overrides \\ []) do
    fields =
      Map.merge(
        %{
          from_track: @a,
          note_id: "n1",
          to_track: @b,
          new_id: "n1_b",
          after_id: :head,
          span: {0, 960},
          attrs: %{pitch: 62, lyric: "ら"}
        },
        Map.new(overrides)
      )

    struct!(DragNoteAcrossTracks, fields)
  end

  defp track(ws, track_id), do: Map.fetch!(ws.tracks, track_id)

  defp mount_patch(ws, track_id, note_id) do
    track = track(ws, track_id)
    element = Map.fetch!(track.elements_by_id, note_id)
    {:ok, tp} = Tamale.Patch.new(Note.to_canonical(element), %{lyric: "らん"})

    {:ok, patch} =
      Patch.new(%{
        track_id: track_id,
        channel: :lyric,
        anchor: %Tamale.Anchor.Ordinal{refs: [note_id], at_version: track.space.version},
        patch: tp
      })

    {:ok, ws, minted} = Workspace.attach_patch(ws, patch)
    {ws, minted}
  end

  describe "validate" do
    test "accepts a well-formed cross-track drag" do
      ws = base_workspace() |> insert(@a, "n1", {0, 480})
      assert :ok = Operation.validate(drag_req(), ws)
    end

    test "rejects a same-track drag (use DragNote instead)" do
      ws = base_workspace() |> insert(@a, "n1", {0, 480})
      assert {:error, {:same_track, @a}} = Operation.validate(drag_req(to_track: @a), ws)
    end

    test "rejects unknown source/target tracks and an unknown note" do
      ws = base_workspace() |> insert(@a, "n1", {0, 480})

      assert {:error, {:unknown_track, "nope"}} =
               Operation.validate(drag_req(from_track: "nope"), ws)

      assert {:error, {:unknown_track, "nope"}} =
               Operation.validate(drag_req(to_track: "nope"), ws)

      assert {:error, {:unknown_id, "nope"}} = Operation.validate(drag_req(note_id: "nope"), ws)
    end

    test "rejects a taken new_id and an invalid span on the target" do
      ws = base_workspace() |> insert(@a, "n1", {0, 480}) |> insert(@b, "m1", {0, 480})

      assert {:error, {:id_conflict, "m1"}} = Operation.validate(drag_req(new_id: "m1"), ws)
      assert {:error, {:invalid_span, _}} = Operation.validate(drag_req(span: {960, 0}), ws)
    end

    test "rejects attrs the target module cannot cast" do
      ws = base_workspace() |> insert(@a, "n1", {0, 480})

      assert {:error, {:invalid_key, "high"}} =
               Operation.validate(drag_req(attrs: %{pitch: "high"}), ws)
    end
  end

  describe "apply via History" do
    test "one edge: source delete + target insert commit atomically" do
      ws = base_workspace() |> insert(@a, "n1", {0, 480})
      h = History.new(ws)
      version = ws.edit_version

      {:ok, h} = History.apply(h, drag_req())

      # exactly one edge, one version bump
      assert h.seq == 1
      assert h.present.edit_version == version + 1

      # source: n1 removed from the sequence, side tables tombstoned
      assert track(h.present, @a).space.ids == []
      refute Map.has_key?(track(h.present, @a).elements_by_id, "n1")

      # target: fresh id inserted with the cast element and span
      target = track(h.present, @b)
      assert target.space.ids == ["n1_b"]

      assert %Note{lyric: "ら", key: %Key.TwelveET{midi: 62}} = target.elements_by_id["n1_b"]
      assert target.spans_by_version[target.space.version]["n1_b"] == {0, 960}
    end

    test "a single undo restores both tracks bitwise" do
      ws = base_workspace() |> insert(@a, "n1", {0, 480})
      h = History.new(ws)

      {:ok, h} = History.apply(h, drag_req())
      {:ok, h} = History.undo(h)
      assert h.present == ws

      {:ok, h} = History.redo(h)
      assert track(h.present, @b).space.ids == ["n1_b"]
    end

    test "patches anchored to the dragged note die into the source graveyard" do
      ws = base_workspace() |> insert(@a, "n1", {0, 480})
      {ws, %Patch{id: pid}} = mount_patch(ws, @a, "n1")
      h = History.new(ws)

      {:ok, h} = History.apply(h, drag_req())

      source = track(h.present, @a)
      assert source.patches == []
      assert [{%Patch{id: ^pid}, _reason}] = source.dead_patches
    end

    test "replay equivalence: state_at matches present after the drag" do
      ws = base_workspace() |> insert(@a, "n1", {0, 480})
      h = History.new(ws)
      {:ok, h} = History.apply(h, drag_req())

      {:ok, replayed} = History.state_at(h, h.cursor)
      assert replayed == h.present
    end

    test "a stale expected_version is rejected" do
      ws = base_workspace() |> insert(@a, "n1", {0, 480})
      h = History.new(ws)

      assert {:error, {:version_conflict, _}} = History.apply(h, drag_req(), ws.edit_version + 1)
    end
  end

  describe "operation layer" do
    test "lower/3 rejects the multi-track request with a clear error" do
      ws = base_workspace() |> insert(@a, "n1", {0, 480})

      assert {:error, {:multi_track_request, DragNoteAcrossTracks}} =
               Operation.lower(drag_req(), ws, %Operation.Config{})
    end

    test "lower_batches produces source delete then target insert" do
      ws = base_workspace() |> insert(@a, "n1", {0, 480})

      assert {:ok,
              [{@a, [%Tamale.Op.Delete{id: "n1"}], del_ch}, {@b, [%Tamale.Op.Insert{}], ins_ch}]} =
               Operation.lower_batches(drag_req(), ws, %Operation.Config{})

      assert del_ch.elements == %{"n1" => :delete}
      assert del_ch.span_snapshot == %{"n1" => :delete}
      assert %{"n1_b" => %Note{}} = ins_ch.elements
      assert ins_ch.span_snapshot == %{"n1_b" => {0, 960}}
    end
  end

  describe "workspace apply_batches" do
    test "an empty batch list is rejected" do
      ws = base_workspace()
      assert {:error, :empty_batches} = Workspace.apply_batches(ws, ws.edit_version, [])
    end

    test "a failing batch fails the whole gesture (atomicity)" do
      ws = base_workspace() |> insert(@a, "n1", {0, 480})

      empty_changes = %{
        elements: %{},
        span_snapshot: %{},
        patches_add: [],
        patches_remove: []
      }

      delete_changes = %{
        empty_changes
        | elements: %{"n1" => :delete},
          span_snapshot: %{"n1" => :delete}
      }

      assert {:error, {:unknown_track, "nope"}} =
               Workspace.apply_batches(ws, ws.edit_version, [
                 {@a, [%Tamale.Op.Delete{id: "n1"}], delete_changes},
                 {"nope", [], empty_changes}
               ])
    end
  end
end
