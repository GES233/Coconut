defmodule Coconut.TempoTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.{Operation, Track, WarpProvider, Workspace}
  alias Coconut.Score
  alias Coconut.Util.ID

  setup do
    {:ok, tempo} = Track.new(%{id: "global:tempo", module: Track.Tempo})

    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        globals: %{"global:tempo" => tempo}
      })

    {:ok, ws: ws}
  end

  describe "tempo insert" do
    test "inserts tempo event into the tempo track", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: "global:tempo",
            note_id: "t0",
            after_id: :head,
            span: {0, 1920},
            attrs: %{bpm: 120}
          },
          ws,
          %Operation.Config{}
        )

      assert [%Tamale.Op.Insert{id: "t0", after_id: :head}] = ops
      assert changes.elements == %{"t0" => %{bpm: 120_000}}
      assert changes.span_snapshot == %{"t0" => {0, 1920}}

      {:ok, ws} = Workspace.apply_batch(ws, "global:tempo", 0, ops, changes)
      assert ws.globals["global:tempo"].space.version == 1
      assert ws.globals["global:tempo"].space.ids == ["t0"]
      assert ws.globals["global:tempo"].elements_by_id["t0"] == %{bpm: 120_000}
    end

    test "second tempo event inserted after first", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: "global:tempo",
            note_id: "t0",
            after_id: :head,
            span: {0, 1920},
            attrs: %{bpm: 120}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, "global:tempo", 0, ops, changes)

      {:ok, ops2, changes2} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: "global:tempo",
            note_id: "t1",
            after_id: "t0",
            span: {1920, 3840},
            attrs: %{bpm: 140}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, "global:tempo", 1, ops2, changes2)

      assert ws.globals["global:tempo"].space.ids == ["t0", "t1"]
      assert ws.globals["global:tempo"].spans_by_version[2]["t0"] == {0, 1920}
      assert ws.globals["global:tempo"].spans_by_version[2]["t1"] == {1920, 3840}
    end
  end

  describe "tempo delete" do
    test "rejects delete of first tempo event", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: "global:tempo",
            note_id: "t0",
            after_id: :head,
            span: {0, 1920},
            attrs: %{bpm: 120}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, "global:tempo", 0, ops, changes)

      assert {:error, {:tempo_first_protected, "t0"}} =
               Operation.validate(
                 %Coconut.Edit.Operations.DeleteNote{track_id: "global:tempo", note_id: "t0"},
                 ws
               )
    end

    test "allows delete of non-first tempo event", %{ws: ws} do
      {:ok, ops, ch} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: "global:tempo",
            note_id: "t0",
            after_id: :head,
            span: {0, 1920},
            attrs: %{bpm: 120}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, "global:tempo", 0, ops, ch)

      {:ok, ops2, ch2} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: "global:tempo",
            note_id: "t1",
            after_id: "t0",
            span: {1920, 3840},
            attrs: %{bpm: 140}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, "global:tempo", 1, ops2, ch2)

      assert :ok =
               Operation.validate(
                 %Coconut.Edit.Operations.DeleteNote{track_id: "global:tempo", note_id: "t1"},
                 ws
               )
    end
  end

  describe "tempo transport" do
    test "transports patches on tempo track (warp is identity)", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: "global:tempo",
            note_id: "t0",
            after_id: :head,
            span: {0, 1920},
            attrs: %{bpm: 120}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, "global:tempo", 0, ops, changes)

      {:ok, cp} =
        Coconut.Edit.Patch.new(%{
          track_id: "global:tempo",
          anchor: %Tamale.Anchor.Ordinal{refs: ["t0"], at_version: 1},
          patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
        })

      ws = put_in(ws.globals["global:tempo"].patches, [cp])

      {:ok, survivors, dead} = Track.transport_patches(ws.globals["global:tempo"])
      assert length(survivors) == 1
      assert dead == []
    end

    test "metric anchor on tempo track always gets identity warp", %{ws: ws} do
      {:ok, ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: "global:tempo",
            note_id: "t0",
            after_id: :head,
            span: {0, 1920},
            attrs: %{bpm: 120}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, "global:tempo", 0, ops, changes)

      {:ok, cp} =
        Coconut.Edit.Patch.new(%{
          track_id: "global:tempo",
          anchor: %Tamale.Anchor.Metric{coord: :tick, from: 100, to: 200, at_version: 1},
          patch: %Tamale.Patch{base_digest: "abc", payload: %{}}
        })

      ws = put_in(ws.globals["global:tempo"].patches, [cp])

      wp = WarpProvider.tick(Track.spans(ws.globals["global:tempo"]))
      {:ok, survivors, dead} = Track.transport_patches(ws.globals["global:tempo"], wp)
      assert length(survivors) == 1
      assert dead == []
      # coordinates unchanged (identity warp)
      assert hd(survivors).anchor.from == {100, 1}
    end
  end

  describe "tempo_map" do
    test "builds from default single tempo event", %{ws: ws} do
      {:ok, ops, ch} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: "global:tempo",
            note_id: "t0",
            after_id: :head,
            span: {0, 9600},
            attrs: %{bpm: 120}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, "global:tempo", 0, ops, ch)

      {:ok, tm} = Workspace.tempo_map(ws)
      # At tick 0, seconds should be 0
      assert Score.TempoMap.tick_to_sec(tm, 0) == 0.0
      # At 480 ticks (one quarter at 120 BPM), should be 0.5 seconds
      assert_in_delta Score.TempoMap.tick_to_sec(tm, 480), 0.5, 0.01
    end

    test "handles multiple tempo changes", %{ws: ws} do
      {:ok, ops, ch} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: "global:tempo",
            note_id: "t0",
            after_id: :head,
            span: {0, 1920},
            attrs: %{bpm: 120}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, "global:tempo", 0, ops, ch)

      {:ok, ops2, ch2} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: "global:tempo",
            note_id: "t1",
            after_id: "t0",
            span: {1920, 3840},
            attrs: %{bpm: 60}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, "global:tempo", 1, ops2, ch2)

      {:ok, tm} = Workspace.tempo_map(ws)
      # First section: 1920 ticks at 120 BPM = 1920/(120*480/60) = 2.0 sec
      assert_in_delta Score.TempoMap.tick_to_sec(tm, 1920), 2.0, 0.01
      # Second section: 1920 ticks at 60 BPM = 1920/(60*480/60) = 4.0 sec
      # Total at tick 3840 = 2.0 + 4.0 = 6.0 sec
      assert_in_delta Score.TempoMap.tick_to_sec(tm, 3840), 6.0, 0.01
    end

    test "round-trip: sec_to_tick then tick_to_sec", %{ws: ws} do
      {:ok, ops, ch} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: "global:tempo",
            note_id: "t0",
            after_id: :head,
            span: {0, 9600},
            attrs: %{bpm: 120}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, "global:tempo", 0, ops, ch)

      {:ok, tm} = Workspace.tempo_map(ws)
      tick = Score.TempoMap.sec_to_tick(tm, 3.5)
      sec = Score.TempoMap.tick_to_sec(tm, tick)
      assert_in_delta sec, 3.5, 0.01
    end

    test "tempo_map keeps every event after a Move permutes tempo ids", %{ws: ws} do
      ws =
        [
          {"t0", :head, {0, 1920}, 120},
          {"t1", "t0", {1920, 3840}, 60},
          {"t2", "t1", {3840, 5760}, 140}
        ]
        |> Enum.reduce(ws, fn {id, after_id, span, bpm}, ws ->
          {:ok, ops, ch} =
            Operation.lower(
              %Coconut.Edit.Operations.InsertNote{
                track_id: "global:tempo",
                note_id: id,
                after_id: after_id,
                span: span,
                attrs: %{bpm: bpm}
              },
              ws,
              %Operation.Config{}
            )

          {:ok, ws} = Workspace.apply_batch(ws, "global:tempo", ws.edit_version, ops, ch)
          ws
        end)

      # Move permutes ids but leaves spans untouched.
      {:ok, ops, ch} =
        Operation.lower(
          %Coconut.Edit.Operations.MoveNote{
            track_id: "global:tempo",
            note_id: "t2",
            after_id: "t0"
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, "global:tempo", ws.edit_version, ops, ch)
      assert ws.globals["global:tempo"].space.ids == ["t0", "t2", "t1"]

      {:ok, tm} = Workspace.tempo_map(ws)
      assert tuple_size(tm.segments) == 3
      # 1920 ticks @120bpm = 2.0s; +1920 ticks @60bpm = 4.0s; total 6.0s at tick 3840.
      assert_in_delta Score.TempoMap.tick_to_sec(tm, 3840), 6.0, 0.01
    end

    test "slice returns [] for zero-width ranges", %{ws: ws} do
      {:ok, ops, ch} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: "global:tempo",
            note_id: "t0",
            after_id: :head,
            span: {0, 9600},
            attrs: %{bpm: 120}
          },
          ws,
          %Operation.Config{}
        )

      {:ok, ws} = Workspace.apply_batch(ws, "global:tempo", 0, ops, ch)

      {:ok, tm} = Workspace.tempo_map(ws)
      assert Score.TempoMap.slice(tm, 100, 100) == []
    end
  end

  describe "region duration" do
    setup %{ws: ws} do
      ws =
        [
          {"t0", :head, {0, 1920}, 120},
          {"t1", "t0", {1920, 3840}, 60}
        ]
        |> Enum.reduce(ws, fn {id, after_id, span, bpm}, ws ->
          {:ok, ops, ch} =
            Operation.lower(
              %Coconut.Edit.Operations.InsertNote{
                track_id: "global:tempo",
                note_id: id,
                after_id: after_id,
                span: span,
                attrs: %{bpm: bpm}
              },
              ws,
              %Operation.Config{}
            )

          {:ok, ws} = Workspace.apply_batch(ws, "global:tempo", ws.edit_version, ops, ch)
          ws
        end)

      {:ok, ws: ws}
    end

    test "returns 0.0 for zero-width and reversed ranges", %{ws: ws} do
      {:ok, tm} = Workspace.tempo_map(ws)
      assert Score.TempoMap.duration_sec(tm, 480, 480) == 0.0
      assert Score.TempoMap.duration_sec(tm, 960, 480) == 0.0
    end

    test "elapsed time within a single segment", %{ws: ws} do
      {:ok, tm} = Workspace.tempo_map(ws)
      # 480 ticks (one quarter) at 120 BPM = 0.5 sec
      assert_in_delta Score.TempoMap.duration_sec(tm, 0, 480), 0.5, 0.01
      assert_in_delta Score.TempoMap.duration_sec(tm, 480, 960), 0.5, 0.01
    end

    test "elapsed time across a tempo boundary", %{ws: ws} do
      {:ok, tm} = Workspace.tempo_map(ws)
      # 960→1920 at 120 BPM = 1.0 sec; 1920→2880 at 60 BPM = 2.0 sec
      assert_in_delta Score.TempoMap.duration_sec(tm, 960, 2880), 3.0, 0.01
    end

    test "Workspace.region_duration_sec delegates to the tempo map", %{ws: ws} do
      assert {:ok, sec} = Workspace.region_duration_sec(ws, 960, 2880)
      assert_in_delta sec, 3.0, 0.01
    end
  end

  describe "region duration with empty tempo track" do
    test "propagates :missing_tempo_track", %{ws: ws} do
      assert {:error, :missing_tempo_track} = Workspace.region_duration_sec(ws, 0, 480)
    end
  end

  describe "bpm normalization" do
    test "cast_bpm accepts integer bpm" do
      assert Score.Tempo.cast_bpm(120) == {:ok, 120_000}
    end

    test "cast_bpm rationalizes float bpm to milli-bpm" do
      assert Score.Tempo.cast_bpm(120.5) == {:ok, 120_500}
      assert Score.Tempo.cast_bpm(87.25) == {:ok, 87_250}
    end

    test "cast_bpm accepts {num, den} rationals" do
      assert Score.Tempo.cast_bpm({241, 2}) == {:ok, 120_500}
    end

    test "cast_bpm rejects non-positive and non-numeric bpm" do
      assert {:error, {:invalid_bpm, 0}} = Score.Tempo.cast_bpm(0)
      assert {:error, {:invalid_bpm, -3}} = Score.Tempo.cast_bpm(-3)
      assert Score.Tempo.cast_bpm(0.0) == {:error, {:invalid_bpm, 0.0}}
      assert {:error, {:invalid_bpm, "fast"}} = Score.Tempo.cast_bpm("fast")
      assert {:error, {:invalid_bpm, nil}} = Score.Tempo.cast_bpm(nil)
    end

    test "lower normalizes tempo insert attrs to milli-bpm", %{ws: ws} do
      {:ok, _ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: "global:tempo",
            note_id: "t0",
            after_id: :head,
            span: {0, 1920},
            attrs: %{bpm: 120.5}
          },
          ws,
          %Operation.Config{}
        )

      assert changes.elements == %{"t0" => %{bpm: 120_500}}
    end

    test "validate rejects un-castable bpm on tempo insert", %{ws: ws} do
      assert {:error, {:invalid_bpm, "fast"}} =
               Operation.validate(
                 %Coconut.Edit.Operations.InsertNote{
                   track_id: "global:tempo",
                   note_id: "t0",
                   after_id: :head,
                   span: {0, 1920},
                   attrs: %{bpm: "fast"}
                 },
                 ws
               )

      assert {:error, {:invalid_bpm, nil}} =
               Operation.validate(
                 %Coconut.Edit.Operations.InsertNote{
                   track_id: "global:tempo",
                   note_id: "t0",
                   after_id: :head,
                   span: {0, 1920},
                   attrs: %{}
                 },
                 ws
               )
    end

    test "lower rejects un-castable bpm directly", %{ws: ws} do
      assert {:error, {:invalid_bpm, -1.5}} =
               Operation.lower(
                 %Coconut.Edit.Operations.InsertNote{
                   track_id: "global:tempo",
                   note_id: "t0",
                   after_id: :head,
                   span: {0, 1920},
                   attrs: %{bpm: -1.5}
                 },
                 ws,
                 %Operation.Config{}
               )
    end

    test "note inserts on regular tracks are untouched by bpm rules", %{ws: ws} do
      {:ok, vocal} = Track.new(%{id: "vocal", module: Track.Vocal})
      ws = put_in(ws.tracks["vocal"], vocal)

      {:ok, _ops, changes} =
        Operation.lower(
          %Coconut.Edit.Operations.InsertNote{
            track_id: "vocal",
            note_id: "n1",
            after_id: :head,
            span: {0, 480},
            attrs: %{lyric: "ら"}
          },
          ws,
          %Operation.Config{}
        )

      assert %{"n1" => %Coconut.Score.Note{lyric: "ら", key: nil}} = changes.elements
    end
  end

  describe "globals validation" do
    test "rejects a tempo-incapable module in the tempo slot" do
      {:ok, vocal} = Track.new(%{id: "global:tempo", module: Track.Vocal})

      assert {:error, {:invalid_tempo_track, Track.Vocal}} =
               Workspace.new(%{
                 id: ID.generate_id("WSpc_"),
                 edit_version: 0,
                 globals: %{"global:tempo" => vocal}
               })
    end

    test "rejects a tempo-capable track inside tracks" do
      {:ok, tempo} = Track.new(%{id: "tempo2", module: Track.Tempo})

      assert {:error, :tempo_track_in_tracks} =
               Workspace.new(%{
                 id: ID.generate_id("WSpc_"),
                 edit_version: 0,
                 tracks: %{"tempo2" => tempo}
               })
    end

    test "rejects a tracks key in the reserved global namespace" do
      {:ok, vocal} = Track.new(%{id: "global:tempo", module: Track.Vocal})

      assert {:error, {:global_id_reserved, "global:tempo"}} =
               Workspace.new(%{
                 id: ID.generate_id("WSpc_"),
                 edit_version: 0,
                 tracks: %{"global:tempo" => vocal}
               })
    end

    test "rejects a global whose key differs from its track id" do
      {:ok, tempo} = Track.new(%{id: "global:swing", module: Track.Tempo})

      assert {:error, {:invalid_global_track, "global:tempo", "global:swing"}} =
               Workspace.new(%{
                 id: ID.generate_id("WSpc_"),
                 edit_version: 0,
                 globals: %{"global:tempo" => tempo}
               })
    end
  end
end
