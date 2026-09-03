defmodule Coconut.AudioTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.{Operation, Patch, Track, Workspace}

  alias Coconut.Edit.Operations.{
    DeleteNote,
    DragNote,
    InsertNote,
    MergeNotes,
    SplitNote,
    TrimNote
  }

  alias Coconut.Edit.Track.Audio
  alias Coconut.Edit.Track.Audio.Clip
  alias Coconut.Util.ID

  @track "audio"

  setup do
    {:ok, audio} = Track.new(%{id: @track, module: Audio})

    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        tracks: %{@track => audio}
      })

    {:ok, ws: ws}
  end

  defp apply_request(ws, %{track_id: track_id} = req) do
    :ok = Operation.validate(req, ws)
    {:ok, ops, changes} = Operation.lower(req, ws, %Operation.Config{})
    {:ok, ws} = Workspace.apply_batch(ws, track_id, ws.edit_version, ops, changes)
    ws
  end

  defp insert_clip(ws, id, span, attrs \\ %{}) do
    attrs = Map.merge(%{source: "a.wav", duration_frames: elem(span, 1) - elem(span, 0)}, attrs)

    apply_request(ws, %InsertNote{
      track_id: @track,
      note_id: id,
      after_id: :head,
      span: span,
      attrs: attrs
    })
  end

  defp audio_track(ws) do
    {:ok, track} = Workspace.fetch_track(ws, @track)
    track
  end

  describe "insert" do
    test "inserts a clip addressed in frames", %{ws: ws} do
      ws = insert_clip(ws, "c1", {100, 260}, %{source_offset_frames: 40})

      track = audio_track(ws)
      assert Track.coord_domain(track) == :frame

      assert track.elements_by_id["c1"] == %Clip{
               source: "a.wav",
               source_offset_frames: 40,
               duration_frames: 160
             }

      assert Track.latest_span(track, "c1") == {100, 260}
    end

    test "source offset defaults to zero", %{ws: ws} do
      ws = insert_clip(ws, "c1", {0, 100})
      assert audio_track(ws).elements_by_id["c1"].source_offset_frames == 0
    end

    test "rejects a duration/span mismatch (no time-stretch)", %{ws: ws} do
      assert {:error, {:clip_duration_span_mismatch, %{duration_frames: 90, span_frames: 100}}} =
               Operation.validate(
                 %InsertNote{
                   track_id: @track,
                   note_id: "c1",
                   after_id: :head,
                   span: {0, 100},
                   attrs: %{source: "a.wav", duration_frames: 90}
                 },
                 ws
               )
    end

    test "rejects malformed clip fields", %{ws: ws} do
      for {attrs, reason} <- [
            {%{duration_frames: 100}, :invalid_clip_source},
            {%{source: "", duration_frames: 100}, :invalid_clip_source},
            {%{source: "a.wav", source_offset_frames: -1, duration_frames: 100},
             :invalid_clip_offset},
            {%{source: "a.wav", duration_frames: 0}, :invalid_clip_duration}
          ] do
        assert {:error, {^reason, _}} =
                 Operation.validate(
                   %InsertNote{
                     track_id: @track,
                     note_id: "c1",
                     after_id: :head,
                     span: {0, 100},
                     attrs: attrs
                   },
                   ws
                 )
      end
    end
  end

  describe "drag" do
    test "same-extent drag moves the span, element untouched", %{ws: ws} do
      ws = insert_clip(ws, "c1", {0, 160}, %{source_offset_frames: 10})
      before = audio_track(ws).elements_by_id["c1"]

      ws =
        apply_request(ws, %DragNote{
          track_id: @track,
          note_id: "c1",
          after_id: :head,
          old_span: {0, 160},
          new_span: {480, 640}
        })

      track = audio_track(ws)
      assert Track.latest_span(track, "c1") == {480, 640}
      assert track.elements_by_id["c1"] == before
    end

    test "extent-changing drag is rejected (no time-stretch)", %{ws: ws} do
      ws = insert_clip(ws, "c1", {0, 160})

      assert {:error, {:audio_stretch_rejected, _}} =
               Operation.validate(
                 %DragNote{
                   track_id: @track,
                   note_id: "c1",
                   after_id: :head,
                   old_span: {0, 160},
                   new_span: {0, 100}
                 },
                 ws
               )
    end

    test "low-level batch cannot bypass no-stretch", %{ws: ws} do
      ws = insert_clip(ws, "c1", {0, 160})

      request = %DragNote{
        track_id: @track,
        note_id: "c1",
        after_id: :head,
        old_span: {0, 160},
        new_span: {0, 100}
      }

      {:ok, ops, changes} = Operation.lower(request, ws, %Operation.Config{})

      assert {:error, {:clip_duration_span_mismatch, %{duration_frames: 160, span_frames: 100}}} =
               Workspace.apply_batch(ws, @track, ws.edit_version, ops, changes)
    end
  end

  describe "trim" do
    test "right-edge trim shrinks the duration, offset untouched", %{ws: ws} do
      ws = insert_clip(ws, "c1", {0, 160}, %{source_offset_frames: 10})

      ws =
        apply_request(ws, %TrimNote{
          track_id: @track,
          note_id: "c1",
          old_span: {0, 160},
          new_span: {0, 100}
        })

      track = audio_track(ws)

      assert track.elements_by_id["c1"] == %Clip{
               source: "a.wav",
               source_offset_frames: 10,
               duration_frames: 100
             }

      assert Track.latest_span(track, "c1") == {0, 100}
    end

    test "left-edge trim shifts the source offset", %{ws: ws} do
      ws = insert_clip(ws, "c1", {0, 160}, %{source_offset_frames: 10})

      ws =
        apply_request(ws, %TrimNote{
          track_id: @track,
          note_id: "c1",
          old_span: {0, 160},
          new_span: {40, 160}
        })

      assert audio_track(ws).elements_by_id["c1"] == %Clip{
               source: "a.wav",
               source_offset_frames: 50,
               duration_frames: 120
             }
    end

    test "left-edge extension underflows at the source start", %{ws: ws} do
      ws = insert_clip(ws, "c1", {100, 260}, %{source_offset_frames: 10})

      assert {:error, {:audio_source_underflow, -10}} =
               Operation.validate(
                 %TrimNote{
                   track_id: @track,
                   note_id: "c1",
                   old_span: {100, 260},
                   new_span: {80, 260}
                 },
                 ws
               )
    end

    test "right-edge extension grows the duration (source length is asset-layer knowledge)",
         %{ws: ws} do
      ws = insert_clip(ws, "c1", {0, 160})

      ws =
        apply_request(ws, %TrimNote{
          track_id: @track,
          note_id: "c1",
          old_span: {0, 160},
          new_span: {0, 200}
        })

      assert audio_track(ws).elements_by_id["c1"].duration_frames == 200
    end
  end

  describe "split" do
    test "re-addresses both halves in frames", %{ws: ws} do
      ws = insert_clip(ws, "c1", {0, 160}, %{source_offset_frames: 10})

      ws =
        apply_request(ws, %SplitNote{track_id: @track, note_id: "c1", at_tick: 60, new_id: "c2"})

      track = audio_track(ws)

      assert track.elements_by_id["c1"] == %Clip{
               source: "a.wav",
               source_offset_frames: 10,
               duration_frames: 60
             }

      assert track.elements_by_id["c2"] == %Clip{
               source: "a.wav",
               source_offset_frames: 70,
               duration_frames: 100
             }

      assert Track.latest_span(track, "c1") == {0, 60}
      assert Track.latest_span(track, "c2") == {60, 160}
    end
  end

  describe "merge" do
    test "is rejected (v1)", %{ws: ws} do
      ws = insert_clip(ws, "c1", {0, 100})

      ws =
        apply_request(ws, %InsertNote{
          track_id: @track,
          note_id: "c2",
          after_id: "c1",
          span: {100, 200},
          attrs: %{source: "a.wav", duration_frames: 100}
        })

      assert {:error, {:audio_merge_unsupported, ["c1", "c2"]}} =
               Operation.validate(%MergeNotes{track_id: @track, note_ids: ["c1", "c2"]}, ws)
    end
  end

  describe "patch lifecycle on a frame track (nil warp provider)" do
    test "ordinal patches die with their clip instead of crashing", %{ws: ws} do
      ws = insert_clip(ws, "c1", {0, 100})

      {:ok, patch} =
        Patch.new(%{
          track_id: @track,
          channel: :default,
          anchor: %Tamale.Anchor.Ordinal{refs: ["c1"], at_version: 1},
          patch: %Tamale.Patch{base_digest: "d", payload: %{}}
        })

      {:ok, ws, _minted} = Workspace.attach_patch(ws, patch)
      ws = apply_request(ws, %DeleteNote{track_id: @track, note_id: "c1"})

      track = audio_track(ws)
      assert track.elements_by_id == %{}
      assert track.patches == []
      assert [{dead_patch, {:undefined, _}}] = track.dead_patches
      assert dead_patch.anchor.refs == ["c1"]
    end

    test "tick Metric anchors are rejected at mount (domain guard)", %{ws: ws} do
      {:ok, patch} =
        Patch.new(%{
          track_id: @track,
          channel: :default,
          anchor: %Tamale.Anchor.Metric{coord: :tick, from: 0, to: 100, at_version: 0},
          patch: %Tamale.Patch{base_digest: "d", payload: %{}}
        })

      assert {:error, {:anchor_coord_mismatch, :tick, :frame}} =
               Workspace.attach_patch(ws, patch)
    end

    test "frame Metric anchors mount and transport with the native frame warp", %{ws: ws} do
      ws = insert_clip(ws, "c1", {0, 100})

      {:ok, patch} =
        Patch.new(%{
          track_id: @track,
          channel: :default,
          anchor: %Tamale.Anchor.Metric{coord: :frame, from: 0, to: 100, at_version: 0},
          patch: %Tamale.Patch{base_digest: "d", payload: %{}}
        })

      {:ok, ws, _minted} = Workspace.attach_patch(ws, patch)

      ws =
        apply_request(ws, %TrimNote{
          track_id: @track,
          note_id: "c1",
          old_span: {0, 100},
          new_span: {0, 60}
        })

      assert [%{anchor: %{coord: :frame, from: {0, 1}, to: {60, 1}}}] = audio_track(ws).patches
    end
  end

  describe "view" do
    test "orders clips by span start", %{ws: ws} do
      ws = insert_clip(ws, "c1", {100, 200})

      ws =
        apply_request(ws, %InsertNote{
          track_id: @track,
          note_id: "c2",
          after_id: "c1",
          span: {0, 50},
          attrs: %{source: "b.wav", duration_frames: 50}
        })

      assert [{"c2", %Clip{source: "b.wav"}, {0, 50}}, {"c1", %Clip{source: "a.wav"}, {100, 200}}] =
               Audio.view(audio_track(ws))
    end
  end

  describe "edit_element" do
    test "merges changes and revalidates field shapes" do
      clip = %Clip{source: "a.wav", source_offset_frames: 10, duration_frames: 100}

      assert {:ok, %Clip{source: "b.wav", source_offset_frames: 10, duration_frames: 100}} =
               Audio.edit_element(clip, %{source: "b.wav"})

      assert {:error, {:invalid_clip_offset, -1}} =
               Audio.edit_element(clip, %{source_offset_frames: -1})

      assert {:ok, ^clip} = Audio.edit_element(clip, %{unknown_field: "ignored"})
    end

    test "rejects duration_frames changes — resize only via trim/split" do
      clip = %Clip{source: "a.wav", source_offset_frames: 10, duration_frames: 100}

      assert {:error, :audio_duration_edit_rejected} =
               Audio.edit_element(clip, %{duration_frames: 50})

      assert {:error, :audio_duration_edit_rejected} =
               Audio.edit_element(clip, %{source: "b.wav", duration_frames: 100})
    end
  end

  describe "pickle" do
    test "track archive roundtrip through the default registry", %{ws: ws} do
      ws = insert_clip(ws, "c1", {0, 160}, %{source_offset_frames: 10})
      track = audio_track(ws)

      registry = Coconut.Pickle.Track.default_registry()

      assert {:ok, dumped} = Coconut.Pickle.Track.dump(track, registry)
      assert dumped.module == "audio"
      assert {:ok, loaded} = Coconut.Pickle.Track.load(dumped, registry)
      assert loaded == track
    end
  end
end
