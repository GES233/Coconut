defmodule Coconut.TrackTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.{Operation, Track, Workspace}
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

  test "metadata/extras 只接受 conform plain map，默认空 map" do
    assert {:ok, track} =
             Track.new(%{
               id: "rich",
               module: Track.Vocal,
               metadata: %{"color" => "#88aaff", role: :lead},
               extras: %{neume: %{version: 1, automation: [:pitch, nil]}}
             })

    assert track.metadata.role == :lead
    assert track.extras.neume.version == 1

    assert {:error, {:invalid_metadata, []}} =
             Track.new(%{id: "bad-meta", module: Track.Vocal, metadata: []})

    assert {:error, {:non_conform_extras, _}} =
             Track.new(%{id: "bad-extra", module: Track.Vocal, extras: %{runtime: self()}})
  end

  defp apply_request(ws, request) do
    {:ok, ops, changes} = Operation.lower(request, ws, %Operation.Config{})
    {:ok, ws} = Workspace.apply_batch(ws, @track, ws.edit_version, ops, changes)
    ws
  end

  describe "truncate/2" do
    test "cuts the op log and old span snapshots, keeps the baseline", %{ws: ws} do
      ws =
        ws
        |> apply_request(%Coconut.Edit.Operations.InsertNote{
          track_id: @track,
          note_id: "n1",
          after_id: :head,
          span: {0, 480},
          attrs: %{pitch: 60}
        })
        |> apply_request(%Coconut.Edit.Operations.InsertNote{
          track_id: @track,
          note_id: "n2",
          after_id: "n1",
          span: {480, 960},
          attrs: %{pitch: 62}
        })
        |> apply_request(%Coconut.Edit.Operations.DragNote{
          track_id: @track,
          note_id: "n1",
          after_id: :head,
          old_span: {0, 480},
          new_span: {100, 480}
        })

      track = ws.tracks[@track]
      assert track.space.version == 3
      assert Map.has_key?(track.spans_by_version, 1)

      {:ok, ws} = Workspace.truncate(ws, @track, 2)
      track = ws.tracks[@track]

      # op log cut: version 1's Insert entry is gone, base_version moved up
      assert track.space.base_version == 2
      assert Enum.all?(track.space.log, fn {version, _ops} -> version > 2 end)

      # span snapshots: the pre-cut baseline (version 2) survives so
      # latest_spans/1 still resolves; version 1 is pruned
      refute Map.has_key?(track.spans_by_version, 1)
      assert Map.has_key?(track.spans_by_version, 2)
      assert Track.latest_span(track, "n2") == {480, 960}
      assert Track.latest_span(track, "n1") == {100, 480}
    end

    test "a Move-only tail still has a span baseline after truncation", %{ws: ws} do
      ws =
        ws
        |> apply_request(%Coconut.Edit.Operations.InsertNote{
          track_id: @track,
          note_id: "n1",
          after_id: :head,
          span: {0, 480},
          attrs: %{pitch: 60}
        })
        |> apply_request(%Coconut.Edit.Operations.InsertNote{
          track_id: @track,
          note_id: "n2",
          after_id: "n1",
          span: {480, 960},
          attrs: %{pitch: 62}
        })
        |> apply_request(%Coconut.Edit.Operations.MoveNote{
          track_id: @track,
          note_id: "n2",
          after_id: :head
        })

      # version 3 (Move) wrote no span snapshot; truncating at 3 must keep
      # version 2's snapshot as the baseline
      {:ok, ws} = Workspace.truncate(ws, @track, 3)
      track = ws.tracks[@track]

      assert track.spans_by_version == %{2 => %{"n1" => {0, 480}, "n2" => {480, 960}}}
      assert Track.latest_span(track, "n1") == {0, 480}
    end

    test "unknown track", %{ws: ws} do
      assert {:error, {:unknown_track, "nope"}} = Workspace.truncate(ws, "nope", 1)
    end
  end

  describe "supports?/2" do
    test ":tempo_derive binds by export, not module identity" do
      assert Track.supports?(Track.Tempo, :tempo_derive)
      refute Track.supports?(Track.Vocal, :tempo_derive)
    end
  end
end
