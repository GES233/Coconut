defmodule Coconut.TempoTest do
  use ExUnit.Case, async: true

  alias Coconut.{Operate, Score, WarpProvider, Workspace}
  alias Coconut.Util.ID

  setup do
    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        tempo_space: %Tamale.Space{},
        tracks: %{},
        side: %Workspace.Side{}
      })

    {:ok, ws: ws}
  end

  describe "tempo insert" do
    test "inserts tempo event into tempo_space", %{ws: ws} do
      {:ok, ops, changes} =
        Operate.lower(
          {:insert_note, :tempo, "t0", :head, {0, 1920}, %{bpm: 120_000}},
          ws,
          %Operate.Config{}
        )

      assert [%Tamale.Op.Insert{id: "t0", after_id: :head}] = ops
      assert changes.elements == %{"t0" => %{bpm: 120_000}}
      assert changes.span_snapshot == %{"t0" => {0, 1920}}

      {:ok, ws} = Workspace.apply_batch(ws, :tempo, 0, ops, changes)
      assert ws.tempo_space.version == 1
      assert ws.tempo_space.ids == ["t0"]
      assert ws.side.elements_by_id["t0"] == %{bpm: 120_000}
    end

    test "second tempo event inserted after first", %{ws: ws} do
      {:ok, ops, changes} =
        Operate.lower(
          {:insert_note, :tempo, "t0", :head, {0, 1920}, %{bpm: 120_000}},
          ws,
          %Operate.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, :tempo, 0, ops, changes)

      {:ok, ops2, changes2} =
        Operate.lower(
          {:insert_note, :tempo, "t1", "t0", {1920, 3840}, %{bpm: 140_000}},
          ws,
          %Operate.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, :tempo, 1, ops2, changes2)

      assert ws.tempo_space.ids == ["t0", "t1"]
      assert ws.side.spans_by_version[:tempo][2]["t0"] == {0, 1920}
      assert ws.side.spans_by_version[:tempo][2]["t1"] == {1920, 3840}
    end
  end

  describe "tempo delete" do
    test "rejects delete of first tempo event", %{ws: ws} do
      {:ok, ops, changes} =
        Operate.lower(
          {:insert_note, :tempo, "t0", :head, {0, 1920}, %{bpm: 120_000}},
          ws,
          %Operate.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, :tempo, 0, ops, changes)

      assert {:error, {:tempo_first_protected, "t0"}} =
               Operate.validate({:delete_note, :tempo, "t0"}, ws)
    end

    test "allows delete of non-first tempo event", %{ws: ws} do
      {:ok, ops, ch} =
        Operate.lower(
          {:insert_note, :tempo, "t0", :head, {0, 1920}, %{bpm: 120_000}},
          ws,
          %Operate.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, :tempo, 0, ops, ch)

      {:ok, ops2, ch2} =
        Operate.lower(
          {:insert_note, :tempo, "t1", "t0", {1920, 3840}, %{bpm: 140_000}},
          ws,
          %Operate.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, :tempo, 1, ops2, ch2)

      assert :ok = Operate.validate({:delete_note, :tempo, "t1"}, ws)
    end
  end

  describe "tempo transport" do
    test "transports patches on tempo track (warp is identity)", %{ws: ws} do
      {:ok, ops, changes} =
        Operate.lower(
          {:insert_note, :tempo, "t0", :head, {0, 1920}, %{bpm: 120_000}},
          ws,
          %Operate.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, :tempo, 0, ops, changes)

      {:ok, cp} =
        Coconut.Patch.new(%{
          track_id: :tempo,
          anchor: %Tamale.Anchor.Ordinal{refs: ["t0"], at_version: 1},
          patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
        })

      ws = put_in(ws.side.patches, [cp])

      {:ok, survivors, dead} = Workspace.transport_patches(ws, :tempo)
      assert length(survivors) == 1
      assert dead == []
    end

    test "metric anchor on tempo track always gets identity warp", %{ws: ws} do
      {:ok, ops, changes} =
        Operate.lower(
          {:insert_note, :tempo, "t0", :head, {0, 1920}, %{bpm: 120_000}},
          ws,
          %Operate.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, :tempo, 0, ops, changes)

      {:ok, cp} =
        Coconut.Patch.new(%{
          track_id: :tempo,
          anchor: %Tamale.Anchor.Metric{coord: :tick, from: 100, to: 200, at_version: 1},
          patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
        })

      ws = put_in(ws.side.patches, [cp])

      wp = WarpProvider.tick(Workspace.track_spans(ws, :tempo))
      {:ok, survivors, dead} = Workspace.transport_patches(ws, :tempo, wp)
      assert length(survivors) == 1
      assert dead == []
      # coordinates unchanged (identity warp)
      assert hd(survivors).anchor.from == {100, 1}
    end
  end

  describe "tempo_map" do
    test "builds from default single tempo event", %{ws: ws} do
      {:ok, ops, ch} =
        Operate.lower(
          {:insert_note, :tempo, "t0", :head, {0, 9600}, %{bpm: 120_000}},
          ws,
          %Operate.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, :tempo, 0, ops, ch)

      {:ok, tm} = Workspace.tempo_map(ws)
      # At tick 0, seconds should be 0
      assert Score.TempoMap.tick_to_sec(tm, 0, 480) == 0.0
      # At 480 ticks (one quarter at 120 BPM), should be 0.5 seconds
      assert_in_delta Score.TempoMap.tick_to_sec(tm, 480, 480), 0.5, 0.01
    end

    test "handles multiple tempo changes", %{ws: ws} do
      {:ok, ops, ch} =
        Operate.lower(
          {:insert_note, :tempo, "t0", :head, {0, 1920}, %{bpm: 120_000}},
          ws,
          %Operate.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, :tempo, 0, ops, ch)

      {:ok, ops2, ch2} =
        Operate.lower(
          {:insert_note, :tempo, "t1", "t0", {1920, 3840}, %{bpm: 60_000}},
          ws,
          %Operate.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, :tempo, 1, ops2, ch2)

      {:ok, tm} = Workspace.tempo_map(ws)
      # First section: 1920 ticks at 120 BPM = 1920/(120*480/60) = 2.0 sec
      assert_in_delta Score.TempoMap.tick_to_sec(tm, 1920, 480), 2.0, 0.01
      # Second section: 1920 ticks at 60 BPM = 1920/(60*480/60) = 4.0 sec
      # Total at tick 3840 = 2.0 + 4.0 = 6.0 sec
      assert_in_delta Score.TempoMap.tick_to_sec(tm, 3840, 480), 6.0, 0.01
    end

    test "round-trip: sec_to_tick then tick_to_sec", %{ws: ws} do
      {:ok, ops, ch} =
        Operate.lower(
          {:insert_note, :tempo, "t0", :head, {0, 9600}, %{bpm: 120_000}},
          ws,
          %Operate.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, :tempo, 0, ops, ch)

      {:ok, tm} = Workspace.tempo_map(ws)
      tick = Score.TempoMap.sec_to_tick(tm, 3.5, 480)
      sec = Score.TempoMap.tick_to_sec(tm, tick, 480)
      assert_in_delta sec, 3.5, 0.01
    end

    test "tempo_map keeps every event after a Move permutes tempo ids", %{ws: ws} do
      ws =
        [
          {"t0", :head, {0, 1920}, 120_000},
          {"t1", "t0", {1920, 3840}, 60_000},
          {"t2", "t1", {3840, 5760}, 140_000}
        ]
        |> Enum.reduce(ws, fn {id, after_id, span, bpm}, ws ->
          {:ok, ops, ch} =
            Operate.lower(
              {:insert_note, :tempo, id, after_id, span, %{bpm: bpm}},
              ws,
              %Operate.Config{}
            )

          {:ok, ws} = Workspace.apply_batch(ws, :tempo, ws.edit_version, ops, ch)
          ws
        end)

      # Move permutes ids but leaves spans untouched.
      {:ok, ops, ch} = Operate.lower({:move_note, :tempo, "t2", "t0"}, ws, %Operate.Config{})
      {:ok, ws} = Workspace.apply_batch(ws, :tempo, ws.edit_version, ops, ch)
      assert ws.tempo_space.ids == ["t0", "t2", "t1"]

      {:ok, tm} = Workspace.tempo_map(ws)
      assert tuple_size(tm) == 3
      # 1920 ticks @120bpm = 2.0s; +1920 ticks @60bpm = 4.0s; total 6.0s at tick 3840.
      assert_in_delta Score.TempoMap.tick_to_sec(tm, 3840, 480), 6.0, 0.01
    end

    test "slice returns [] for zero-width ranges", %{ws: ws} do
      {:ok, ops, ch} =
        Operate.lower(
          {:insert_note, :tempo, "t0", :head, {0, 9600}, %{bpm: 120_000}},
          ws,
          %Operate.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, :tempo, 0, ops, ch)

      {:ok, tm} = Workspace.tempo_map(ws)
      assert Score.TempoMap.slice(tm, 100, 100) == []
    end
  end
end
