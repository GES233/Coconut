defmodule Coconut.Edit.HistoryTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.{Command, History, Patch, Track}
  alias Coconut.Edit.Operations.{DeleteNote, InsertNote}
  alias Coconut.Scenario
  alias Coconut.Score.Note

  @track "vocal"

  # ---- Helpers ----

  defp base_history(opts \\ []), do: History.new(Scenario.base_workspace(), opts)

  defp track(hist, track_id \\ @track), do: Map.fetch!(hist.present.tracks, track_id)

  defp note_ids(hist, track_id \\ @track),
    do: hist |> track(track_id) |> Map.fetch!(:elements_by_id) |> Map.keys() |> Enum.sort()

  defp insert(hist, id, track_id \\ @track) do
    space_ids = Map.fetch!(hist.present.tracks, track_id).space.ids
    after_id = if space_ids == [], do: :head, else: List.last(space_ids)
    start = length(space_ids) * 480

    req = %InsertNote{
      track_id: track_id,
      note_id: id,
      after_id: after_id,
      span: {start, start + 480},
      attrs: %{pitch: 62}
    }

    {:ok, hist} = History.apply(hist, req)
    hist
  end

  defp delete(hist, id) do
    {:ok, hist} = History.apply(hist, %DeleteNote{track_id: @track, note_id: id})
    hist
  end

  defp mount(hist, note_id) do
    ws = hist.present
    track = Map.fetch!(ws.tracks, @track)
    element = Map.fetch!(track.elements_by_id, note_id)
    {:ok, tp} = Tamale.Patch.new(Note.to_canonical(element), %{lyric: "らん"})

    {:ok, patch} =
      Patch.new(%{
        track_id: @track,
        channel: :lyric,
        anchor: %Tamale.Anchor.Ordinal{refs: [note_id], at_version: track.space.version},
        patch: tp
      })

    {:ok, hist} = History.run(hist, Command.attach_patches([patch]))
    hist
  end

  defp add_track(hist, attrs) do
    {:ok, cmd} = Command.add_track(attrs)
    History.run(hist, cmd)
  end

  defp undo!(hist), do: elem(History.undo(hist), 1)
  defp redo!(hist), do: elem(History.redo(hist), 1)

  describe "write + traversal" do
    test "insert → undo → redo → undo: bitwise round-trip" do
      h0 = base_history()
      h2 = h0 |> insert("n1") |> insert("n2")
      ws2 = h2.present

      h = h2 |> undo!() |> redo!()
      assert h.present == ws2

      h = h |> undo!() |> undo!()
      assert h.present == h0.present
      assert {:error, :nothing_to_undo} = History.undo(h)

      h = h |> redo!() |> redo!()
      assert h.present == ws2
      assert {:error, :nothing_to_redo} = History.redo(h)
    end

    test "branch: global seq walk teleports across the fork, visits each state once" do
      h =
        base_history()
        |> insert("n1")
        |> insert("n2")
        |> insert("n3")
        |> insert("n4")
        |> insert("n5")
        |> undo!()
        |> undo!()
        |> insert("n6")
        |> insert("n7")

      # seqs 1..5 are the n1..n5 trunk; 6,7 forked off node 3
      assert {:error, :nothing_to_redo} = History.redo(h)
      assert note_ids(h) == ["n1", "n2", "n3", "n6", "n7"]

      # from the branch tip (seq 7), undo walks the global seq order —
      # crossing back into the old trunk at seq 5 (Vim g- semantics)
      expected = [
        {7, ~w(n1 n2 n3 n6 n7)},
        {6, ~w(n1 n2 n3 n6)},
        {5, ~w(n1 n2 n3 n4 n5)},
        {4, ~w(n1 n2 n3 n4)},
        {3, ~w(n1 n2 n3)},
        {2, ~w(n1 n2)},
        {1, ~w(n1)},
        {0, []}
      ]

      {h, walked} =
        Enum.reduce(Enum.drop(expected, 1), {h, [{h.cursor, note_ids(h)}]}, fn _expected,
                                                                               {acc, seen} ->
          acc = undo!(acc)
          {acc, [{acc.cursor, note_ids(acc)} | seen]}
        end)

      assert Enum.reverse(walked) == expected
      assert {:error, :nothing_to_undo} = History.undo(h)

      # every live state visited exactly once; node ids (pins) are unique
      assert length(walked) == map_size(h.nodes)

      # redo returns to the branch tip
      h = Enum.reduce(1..7, h, fn _, acc -> redo!(acc) end)
      assert note_ids(h) == ~w(n1 n2 n3 n6 n7)
    end
  end

  describe "track structural edges" do
    test "add/remove track round-trips with contents, bumps edit_version" do
      h = base_history()
      assert h.present.edit_version == 0

      {:ok, h} = add_track(h, %{id: "harmony", module: Track.Vocal, name: "和声"})
      assert h.present.edit_version == 1
      assert track(h, "harmony").name == "和声"

      h = insert(h, "x1", "harmony")
      {:ok, h} = History.run(h, Command.remove_track("harmony"))
      refute Map.has_key?(h.present.tracks, "harmony")

      # undo past the removal: the track returns with its note — no corpse on
      # the edge, the path before it rebuilds everything
      h = undo!(h)
      assert Map.has_key?(track(h, "harmony").elements_by_id, "x1")
      h = undo!(h)
      assert track(h, "harmony").elements_by_id == %{}
      h = undo!(h)
      refute Map.has_key?(h.present.tracks, "harmony")

      h = redo!(h)
      assert track(h, "harmony").elements_by_id == %{}
      h = redo!(h)
      assert Map.has_key?(track(h, "harmony").elements_by_id, "x1")
      h = redo!(h)
      refute Map.has_key?(h.present.tracks, "harmony")
      assert {:error, :nothing_to_redo} = History.redo(h)
    end

    test "guards" do
      h = base_history()

      assert {:error, {:track_id_taken, @track}} =
               add_track(h, %{id: @track, module: Track.Vocal})

      assert {:error, :tempo_track_in_tracks} =
               add_track(h, %{id: "t2", module: Track.Tempo})

      assert {:error, {:global_id_reserved, "global:tempo"}} =
               add_track(h, %{id: "global:tempo", module: Track.Vocal})

      assert {:error, {:unknown_track, "nope"}} = History.run(h, Command.remove_track("nope"))

      assert {:error, {:global_track_immutable, "global:tempo"}} =
               History.run(h, Command.remove_track("global:tempo"))
    end
  end

  describe "light field edges" do
    test "rename_track round-trips, no edit_version bump" do
      h = base_history() |> insert("n1")
      v = h.present.edit_version

      {:ok, h} = History.run(h, Command.rename_track(@track, "主唱"))
      assert track(h).name == "主唱"
      assert h.present.edit_version == v

      assert {:error, {:unknown_track, "nope"}} =
               History.run(h, Command.rename_track("nope", "x"))

      h = undo!(h)
      assert track(h).name == nil
      h = redo!(h)
      assert track(h).name == "主唱"
    end

    test "metadata/extras 经 History 往返，只有 extras 递增 edit_version" do
      h = base_history()
      v = h.present.edit_version

      {:ok, h} =
        History.run(h, Command.put_track_metadata(@track, %{"color" => "蓝", role: :lead}))

      assert track(h).metadata == %{"color" => "蓝", role: :lead}
      assert h.present.edit_version == v

      {:ok, h} =
        History.run(h, Command.put_track_extras(@track, %{neume: %{automation: [:pitch]}}))

      assert track(h).extras == %{neume: %{automation: [:pitch]}}
      assert h.present.edit_version == v + 1

      h = undo!(h)
      assert track(h).extras == %{}
      assert track(h).metadata == %{"color" => "蓝", role: :lead}

      h = undo!(h)
      assert track(h).metadata == %{}

      h = redo!(h) |> redo!()
      assert track(h).metadata == %{"color" => "蓝", role: :lead}
      assert track(h).extras == %{neume: %{automation: [:pitch]}}

      assert {:error, {:unknown_track, "nope"}} =
               History.run(h, Command.put_track_metadata("nope", %{}))
    end

    test "set_time_sigs round-trips, malformed rejected" do
      h = base_history()

      {:ok, h} = History.run(h, Command.set_time_sigs([{1, {4, 4}}, {3, {3, 4}}]))
      assert h.present.time_sigs == [{1, {4, 4}}, {3, {3, 4}}]

      assert {:error, {:invalid_time_sigs, _}} = History.run(h, Command.set_time_sigs([]))

      h = undo!(h)
      assert h.present.time_sigs == [{1, {4, 4}}]
    end
  end

  describe "patch edges" do
    test "attach → undo (gone) → redo (back with the same minted id)" do
      h = base_history() |> insert("n1") |> mount("n1")
      assert [%Patch{id: pid}] = track(h).patches

      h = undo!(h)
      assert track(h).patches == []

      h = h |> undo!() |> redo!() |> redo!()
      assert [%Patch{id: ^pid}] = track(h).patches
    end

    test "consume_dead: graveyard drains as an edge and revives on undo" do
      h = base_history() |> insert("n1") |> insert("n2") |> mount("n2") |> delete("n2")
      assert [{_patch, _reason}] = track(h).dead_patches

      {dead, h} = History.take_dead_patches(h)
      assert length(dead) == 1
      assert track(h).dead_patches == []

      h = undo!(h)
      assert [{_patch, _reason}] = track(h).dead_patches

      h = undo!(h)
      assert [%Patch{}] = track(h).patches
      assert track(h).dead_patches == []

      # an empty drain records no edge
      assert {[], ^h} = History.take_dead_patches(h)
    end
  end

  describe "version pin" do
    test "stale pins are rejected at the write entry" do
      h = base_history() |> insert("n1")
      stale_pin = History.current(h).node_id
      h = insert(h, "n2")

      req = %InsertNote{
        track_id: @track,
        note_id: "n3",
        after_id: "n2",
        span: {960, 1440},
        attrs: %{pitch: 60}
      }

      assert {:error, {:stale_pin, _}} = History.apply(h, req, :current, pin: stale_pin)

      assert {:ok, _h} = History.apply(h, req, :current, pin: History.current(h).node_id)
    end

    test "a pin from before an undo is stale afterwards" do
      h = base_history() |> insert("n1") |> insert("n2")
      pin = History.current(h).node_id
      h = undo!(h)

      assert {:error, {:stale_pin, _}} =
               History.run(h, Command.rename_track(@track, "x"), pin: pin)
    end
  end

  describe "checkpoints and squash" do
    test "squash bounds undo depth, keeps present intact, drops oldest states" do
      h = base_history(checkpoint_interval: 2, max_edges: 5)
      h = Enum.reduce(1..12, h, fn i, acc -> insert(acc, "s#{i}") end)

      assert h.seq == 12
      assert h.seq - h.base_seq <= 5
      assert length(note_ids(h)) == 12

      assert {:error, {:unknown_node, 0}} = History.state_at(h, 0)

      h = Enum.reduce(1..12, h, fn _, acc -> unwind_one(acc) end)
      # stopped at the squash frontier: 12 - 8 = 4 undo steps happened
      assert h.cursor == h.base_seq
      assert length(note_ids(h)) == 8

      h = Enum.reduce(1..12, h, fn _, acc -> rewind_one(acc) end)
      assert length(note_ids(h)) == 12
      assert {:error, :nothing_to_redo} = History.redo(h)
    end
  end

  describe "replay equivalence (§12.6 core property)" do
    test "random gestures and walks: present always equals a fresh replay" do
      :rand.seed(:exsss, {12, 34, 56})

      h0 = base_history(checkpoint_interval: 3, max_edges: 8)

      h =
        Enum.reduce(1..80, h0, fn step, acc ->
          acc
          |> random_step(step)
          |> assert_replay_consistent()
        end)

      # full undo sweep reaches the squash frontier, full redo returns
      h = Enum.reduce(1..200, h, fn _, acc -> unwind_one(acc) end)
      assert h.cursor == h.base_seq
      h = Enum.reduce(1..200, h, fn _, acc -> rewind_one(acc) end)
      assert h.cursor == h.seq
      assert_replay_consistent(h)
    end
  end

  defp unwind_one(h) do
    case History.undo(h) do
      {:ok, h} -> h
      {:error, :nothing_to_undo} -> h
    end
  end

  defp rewind_one(h) do
    case History.redo(h) do
      {:ok, h} -> h
      {:error, :nothing_to_redo} -> h
    end
  end

  defp assert_replay_consistent(h) do
    {:ok, replayed} = History.state_at(h, h.cursor)
    assert replayed == h.present
    h
  end

  defp random_step(h, step) do
    live = note_ids(h)

    case :rand.uniform(10) do
      n when n <= 4 ->
        insert(h, "r#{step}")

      n when n <= 6 and live != [] ->
        delete(h, Enum.random(live))

      n when n <= 7 and live != [] ->
        mount(h, Enum.random(live))

      n when n <= 9 ->
        unwind_one(h)

      _ ->
        rewind_one(h)
    end
  rescue
    _ -> h
  end
end
