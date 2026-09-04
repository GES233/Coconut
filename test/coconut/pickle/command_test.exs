defmodule Coconut.Pickle.CommandTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.{Command, Operation, Patch}
  alias Coconut.Edit.Operations.{DeleteNote, DragNote, InsertNote}
  alias Coconut.Pickle.Command, as: PickleCommand
  alias Coconut.Pickle.Track, as: PickleTrack
  alias Coconut.Scenario
  alias Coconut.Score.Note

  import Coconut.PickleHelper

  @registry PickleTrack.default_registry()

  defp roundtrip(command) do
    assert {:ok, dumped} = PickleCommand.dump(command, @registry)
    assert_pickle_conform(dumped)
    assert {:ok, loaded} = PickleCommand.load(dumped, @registry)
    assert loaded == command
  end

  # 经真实 lowering 产出 :batch payload（ops + side_changes）。
  defp lowered(ws, req) do
    :ok = Operation.validate(req, ws)
    {:ok, batches} = Operation.lower_batches(req, ws, %Operation.Config{})
    Command.batch(batches, req.__struct__ |> Module.split() |> List.last())
  end

  defp ws_with_note do
    Scenario.base_workspace()
    |> Scenario.insert_note("n1", :head, {0, 480}, %{pitch: 62, lyric: "ら"})
  end

  defp build_patch(ws, note_id) do
    track = Map.fetch!(ws.tracks, "vocal")
    element = Map.fetch!(track.elements_by_id, note_id)
    {:ok, tp} = Tamale.Patch.new(Note.to_canonical(element), %{lyric: "らん"})

    {:ok, patch} =
      Patch.new(%{
        id: "Patch_test1",
        track_id: "vocal",
        channel: :lyric,
        anchor: %Tamale.Anchor.Ordinal{refs: [note_id], at_version: track.space.version},
        patch: tp
      })

    patch
  end

  test ":batch（InsertNote lowering）往返" do
    ws = Scenario.base_workspace()

    req = %InsertNote{
      track_id: "vocal",
      note_id: "n1",
      after_id: :head,
      span: {0, 480},
      attrs: %{pitch: 62, lyric: "ら", metadata: %{"melisma" => "continue"}}
    }

    roundtrip(lowered(ws, req))
  end

  test ":batch（DragNote 的 Move+Retime lowering）往返" do
    ws = ws_with_note()

    req = %DragNote{
      track_id: "vocal",
      note_id: "n1",
      after_id: :head,
      old_span: {0, 480},
      new_span: {240, 720}
    }

    roundtrip(lowered(ws, req))
  end

  test ":batch（DeleteNote lowering，含墓碑 side_changes）往返" do
    ws = ws_with_note()
    roundtrip(lowered(ws, %DeleteNote{track_id: "vocal", note_id: "n1"}))
  end

  test ":attach_patches / :discard_patches / :repatch_patches 往返" do
    ws = ws_with_note()
    patch = build_patch(ws, "n1")

    roundtrip(Command.attach_patches([patch]))
    roundtrip(Command.discard_patches([{"vocal", "Patch_test1", :superseded}]))
    roundtrip(Command.repatch_patches([{"vocal", "Patch_test1", :rebased}], [patch]))
  end

  test ":add_track / :remove_track / :rename_track 往返" do
    {:ok, add} =
      Command.add_track(%{
        id: "harmony",
        module: Coconut.Edit.Track.Vocal,
        name: "和声",
        metadata: %{"color" => "blue"},
        extras: %{neume: %{globals: %{energy: 1.5}}}
      })

    roundtrip(add)
    roundtrip(Command.remove_track("harmony"))
    roundtrip(Command.rename_track("harmony", "和声"))
    roundtrip(Command.rename_track("harmony", nil))
  end

  test ":put_track_metadata / :put_track_extras 往返" do
    roundtrip(Command.put_track_metadata("vocal", %{"color" => "red"}))
    roundtrip(Command.put_track_extras("vocal", %{neume: %{globals: %{energy: 1.5}}}))
  end

  test ":set_time_sigs 往返" do
    roundtrip(Command.set_time_sigs([{1, {4, 4}}, {9, {3, 4}}]))
  end

  test ":consume_dead（resolved payload 含 drain 结果）往返" do
    ws = ws_with_note()
    patch = build_patch(ws, "n1")
    roundtrip(%Command{op: :consume_dead, payload: [{patch, :orphaned}], label: "ConsumeDead"})
  end

  test "load 拒绝未知 op 与非法形状" do
    assert {:error, {:invalid_command_dump, :teleport, _}} =
             PickleCommand.load(%{op: :teleport, payload: %{}}, @registry)

    assert {:error, {:invalid_command_dump, _}} = PickleCommand.load("nope", @registry)

    assert {:error, {:invalid_batch_entry_dump, _}} =
             PickleCommand.load(%{op: :batch, payload: [%{oops: true}]}, @registry)
  end

  test "dump 拒绝非 conform 的自由字段" do
    assert {:error, {:non_conform_put_track_extras, _}} =
             PickleCommand.dump(Command.put_track_extras("vocal", %{bad: {:tuple}}), @registry)
  end
end
