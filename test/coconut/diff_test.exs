defmodule Coconut.Edit.DiffTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.{Diff, Operation, Patch, Track, Workspace}
  alias Coconut.Edit.Operations.{CoreComponents, InsertNote}
  alias Coconut.Score.Note
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

  defp insert(ws, id, span, attrs) do
    after_id =
      case track(ws).space.ids do
        [] -> :head
        ids -> List.last(ids)
      end

    req = %InsertNote{track_id: @track, note_id: id, after_id: after_id, span: span, attrs: attrs}
    :ok = Operation.validate(req, ws)
    {:ok, ops, changes} = Operation.lower(req, ws, %Operation.Config{})
    {:ok, ws} = Workspace.apply_batch(ws, @track, ws.edit_version, ops, changes)
    ws
  end

  defp track(ws) do
    {:ok, track} = Workspace.fetch_track(ws, @track)
    track
  end

  defp apply_diff(ws, news) do
    {:ok, ops, changes} = Diff.diff(track(ws), news)
    {:ok, ws} = Workspace.apply_batch(ws, @track, ws.edit_version, ops, changes)
    ws
  end

  describe "empty and unchanged states" do
    test "empty track: everything is an insert", %{ws: ws} do
      news = [{{0, 480}, %{pitch: 60}}, {{480, 960}, %{pitch: 62}}]
      {:ok, ops, changes} = Diff.diff(track(ws), news)

      assert [%Tamale.Op.Insert{after_id: :head}, %Tamale.Op.Insert{}] = ops
      assert map_size(changes.elements) == 2
      assert map_size(changes.span_snapshot) == 2

      ws = apply_diff(ws, news)
      t = track(ws)
      spans = Track.latest_spans(t)
      assert Enum.map(t.space.ids, &spans[&1]) == [{0, 480}, {480, 960}]
    end

    test "unchanged state produces no ops and empty changes", %{ws: ws} do
      ws = insert(ws, "n1", {0, 480}, %{pitch: 60})

      assert {:ok, [], changes} = Diff.diff(track(ws), [{{0, 480}, %{pitch: 60}}])
      assert changes == CoreComponents.empty_side_changes()
    end

    test "malformed new content is rejected at cast time", %{ws: ws} do
      assert {:error, {:invalid_key, _}} = Diff.diff(track(ws), [{{0, 480}, %{pitch: "c4"}}])
    end
  end

  describe "identity matching" do
    test "exact matches keep ids through a reorder (Move only)", %{ws: ws} do
      ws = insert(ws, "n1", {0, 480}, %{pitch: 60}) |> insert("n2", {480, 960}, %{pitch: 62})

      {:ok, ops, changes} =
        Diff.diff(track(ws), [{{480, 960}, %{pitch: 62}}, {{0, 480}, %{pitch: 60}}])

      assert [%Tamale.Op.Move{id: "n2", after_id: :head}] = ops
      assert changes.elements == %{}
      assert changes.span_snapshot == %{}
    end

    test "a span shift with identical content keeps the id (Retime)", %{ws: ws} do
      ws = insert(ws, "n1", {0, 480}, %{pitch: 60})

      {:ok, ops, changes} = Diff.diff(track(ws), [{{0, 240}, %{pitch: 60}}])

      assert [%Tamale.Op.Retime{id: "n1", old_span: {0, 480}, new_span: {0, 240}}] = ops
      assert changes.elements == %{}
      assert changes.span_snapshot == %{"n1" => {0, 240}}
    end

    test "a content change at the same span is a side-table upsert, no ops", %{ws: ws} do
      ws = insert(ws, "n1", {0, 480}, %{pitch: 60, lyric: "la"})

      {:ok, ops, changes} = Diff.diff(track(ws), [{{0, 480}, %{pitch: 60, lyric: "mi"}}])

      assert ops == []
      assert %{"n1" => %Note{lyric: "mi"}} = changes.elements
      assert changes.span_snapshot == %{}
    end

    test "tied overlap candidates fall back to Delete + Insert (no guessed identity)",
         %{ws: ws} do
      ws = insert(ws, "n1", {100, 300}, %{pitch: 60})

      # 两个新音符对 n1 的 score 完全相同（重叠 100、start 距离 100）：
      # 互为最优不成立，保守回退。
      news = [{{0, 200}, %{pitch: 62}}, {{200, 400}, %{pitch: 64}}]
      {:ok, ops, changes} = Diff.diff(track(ws), news)

      assert [%Tamale.Op.Delete{id: "n1"}, %Tamale.Op.Insert{}, %Tamale.Op.Insert{}] = ops
      assert changes.elements["n1"] == :delete
      assert changes.span_snapshot["n1"] == :delete

      fresh_ids = Map.keys(changes.elements) -- ["n1"]
      assert length(fresh_ids) == 2
      refute "n1" in fresh_ids
    end

    test "a far-away drag (zero overlap) is Delete + Insert, not a guessed Retime",
         %{ws: ws} do
      ws = insert(ws, "n1", {0, 480}, %{pitch: 60})

      {:ok, ops, _changes} = Diff.diff(track(ws), [{{1920, 2400}, %{pitch: 60}}])

      assert [%Tamale.Op.Delete{id: "n1"}, %Tamale.Op.Insert{}] = ops
    end
  end

  describe "intervention semantics" do
    test "patches on unmatched ids die visibly into the graveyard", %{ws: ws} do
      ws = insert(ws, "n1", {0, 480}, %{pitch: 60})

      {:ok, patch} =
        Patch.new(%{
          track_id: @track,
          channel: :lyric,
          anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: 1},
          patch: %Tamale.Patch{base_digest: "d", payload: %{}}
        })

      {:ok, ws, _minted} = Workspace.attach_patch(ws, patch)

      ws = apply_diff(ws, [{{960, 1440}, %{pitch: 62}}])

      assert track(ws).patches == []
      assert [{dead, {:undefined, _}}] = track(ws).dead_patches
      assert dead.anchor.refs == ["n1"]
    end
  end

  describe "round-trip" do
    test "applying the diff reproduces the target state, preserving matched ids",
         %{ws: ws} do
      ws =
        insert(ws, "n1", {0, 480}, %{pitch: 60, lyric: "a"})
        |> insert("n2", {480, 960}, %{pitch: 62, lyric: "b"})
        |> insert("n3", {960, 1440}, %{pitch: 64, lyric: "c"})

      news = [
        # n3 提前（pass 1 精确匹配 + Move）
        {{960, 1440}, %{pitch: 64, lyric: "c"}},
        # n1 缩尾（pass 2 重叠配对 + Retime）
        {{0, 240}, %{pitch: 60, lyric: "a"}},
        # n2 改内容（pass 2 配对 + 侧表 upsert）
        {{480, 960}, %{pitch: 67, lyric: "b+"}},
        # 全新音符（Insert）
        {{1440, 1920}, %{pitch: 65, lyric: "d"}}
      ]

      ws = apply_diff(ws, news)

      t = track(ws)
      # 匹配上的三个都保住旧 id；新音符铸新 id
      assert Enum.take(t.space.ids, 3) == ["n3", "n1", "n2"]
      assert [fresh] = t.space.ids -- ["n1", "n2", "n3"]
      assert is_binary(fresh)

      assert Enum.map(t.space.ids, &t.elements_by_id[&1].lyric) == ["c", "a", "b+", "d"]

      spans = Track.latest_spans(t)

      assert Enum.map(t.space.ids, &spans[&1]) == [
               {960, 1440},
               {0, 240},
               {480, 960},
               {1440, 1920}
             ]
    end
  end
end
