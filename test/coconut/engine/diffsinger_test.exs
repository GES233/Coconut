defmodule Coconut.Engine.DiffSingerTest do
  use ExUnit.Case, async: true

  alias Coconut.{Engine, Operate, Workspace}
  alias Coconut.Engine.{DiffSinger, Request}
  alias Coconut.Util.ID

  defmodule FakeClient do
    @moduledoc "Test seam standing in for the Python worker."
    def call(payload, config) do
      if pid = config[:test_pid], do: send(pid, {:fake_call, payload})

      case {config[:fail], payload.action} do
        {true, _} ->
          {:error, :boom}

        {_, "check"} ->
          {:ok, %{"ph_dur" => [10, 20], "pitch_pred_midi" => [60.0, 62.0], "total_frames" => 30}}

        {_, "render"} ->
          {:ok, %{"path" => payload.out_path, "total_frames" => 480, "duration_sec" => 5.0}}
      end
    end
  end

  defp config(extra \\ %{}) do
    Map.merge(
      %{voicebank_root: "unused/fake", client: FakeClient, test_pid: self()},
      Map.new(extra)
    )
  end

  defp workspace(opts \\ []) do
    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        tempo_space: if(Keyword.get(opts, :tempo, true), do: %Tamale.Space{}, else: nil),
        tracks: %{vocal: %Tamale.Space{}, harmony: %Tamale.Space{}},
        side: %Workspace.Side{}
      })

    ws
  end

  defp insert(ws, track, id, after_id, span, attrs) do
    {:ok, ops, changes} =
      Operate.lower({:insert_note, track, id, after_id, span, attrs}, ws, %Operate.Config{})

    {:ok, ws} = Workspace.apply_batch(ws, track, ws.edit_version, ops, changes)
    ws
  end

  # Two phonemized vocal notes over a flat 120 BPM tempo track.
  defp phonemized_ws(opts \\ []) do
    ws = workspace(opts)

    ws =
      if opts[:tempo] == false,
        do: ws,
        else: insert(ws, :tempo, "t0", :head, {0, 9600}, %{bpm: 120})

    ws
    |> insert(:vocal, "n1", :head, {0, 480}, %{pitch: 60, phonemes: [["zh", "l"], ["zh", "a"]]})
    |> insert(:vocal, "n2", "n1", {480, 960}, %{pitch: 62, phonemes: [["zh", "z"], ["zh", "i"]]})
  end

  test "check assembles words from phonemized notes over the tempo map" do
    {:ok, request} = Request.new(%{workspace: phonemized_ws()})

    assert {:ok, _checked} = Engine.run_check({DiffSinger, config()}, request)

    assert_received {:fake_call, %{action: "check", words: words, globals: %{}}}
    assert [[ph1, dur1, midi1], [ph2, dur2, midi2]] = words
    assert ph1 == [["zh", "l"], ["zh", "a"]]
    assert_in_delta dur1, 0.5, 0.001
    assert midi1 == 60
    assert ph2 == [["zh", "z"], ["zh", "i"]]
    assert_in_delta dur2, 0.5, 0.001
    assert midi2 == 62
  end

  test "notes across tracks are merged and sorted by start tick" do
    ws =
      phonemized_ws()
      |> insert(:harmony, "h1", :head, {0, 960}, %{
        pitch: 55,
        phonemes: [["zh", "h"], ["zh", "u"]]
      })

    {:ok, request} = Request.new(%{workspace: ws})

    assert {:ok, _checked} = Engine.run_check({DiffSinger, config()}, request)

    assert_received {:fake_call, %{words: words}}
    assert Enum.map(words, fn [_ph, _dur, midi] -> midi end) == [55, 60, 62]
  end

  test "check rejects notes without phonemes before calling the worker" do
    ws =
      workspace()
      |> insert(:tempo, "t0", :head, {0, 9600}, %{bpm: 120})
      |> insert(:vocal, "n1", :head, {0, 480}, %{pitch: 60})

    {:ok, request} = Request.new(%{workspace: ws})

    assert {:error, {:missing_phonemes, ["n1"]}} =
             Engine.run_check({DiffSinger, config()}, request)

    refute_received {:fake_call, _}
  end

  test "check rejects notes without pitch" do
    ws =
      workspace()
      |> insert(:tempo, "t0", :head, {0, 9600}, %{bpm: 120})
      |> insert(:vocal, "n1", :head, {0, 480}, %{phonemes: [["zh", "a"]]})

    {:ok, request} = Request.new(%{workspace: ws})

    assert {:error, {:missing_pitch, ["n1"]}} = Engine.run_check({DiffSinger, config()}, request)
    refute_received {:fake_call, _}
  end

  test "no tempo track falls back to flat 120 BPM" do
    ws =
      workspace(tempo: false)
      |> insert(:vocal, "n1", :head, {0, 480}, %{pitch: 60, phonemes: [["zh", "a"]]})

    {:ok, request} = Request.new(%{workspace: ws})

    assert {:ok, _checked} = Engine.run_check({DiffSinger, config()}, request)

    assert_received {:fake_call, %{words: [[_ph, dur, 60]]}}
    assert_in_delta dur, 0.5, 0.0001
  end

  @tag tmp_dir: "ds_out"
  test "render returns artifact with path, frames, globals and overrides", %{tmp_dir: tmp_dir} do
    config = config(%{output_dir: tmp_dir})
    globals = %{gender: 0.5, steps: 40}
    interventions = %{{:port, :synth, :lyric} => %{input: "x"}}

    {:ok, request} =
      Request.new(%{workspace: phonemized_ws(), globals: globals, interventions: interventions})

    assert {:ok, checked} = Engine.run_check({DiffSinger, config}, request)
    assert {:ok, artifact} = Engine.run_render({DiffSinger, config}, request, checked)

    assert artifact.globals == globals
    assert artifact.overrides == interventions
    assert artifact.total_frames == 480
    assert String.starts_with?(artifact.path, tmp_dir)

    # The check-stage probe (words + dur/pitch forwards) is handed to
    # render so the worker skips recomputing them.
    assert_received {:fake_call,
                     %{action: "render", out_path: out_path, globals: ^globals} = payload}

    assert out_path == artifact.path
    assert payload.words == checked.words
    assert payload.ph_dur == [10, 20]
    assert payload.pitch_pred_midi == [60.0, 62.0]
  end

  test "worker error propagates" do
    {:ok, request} = Request.new(%{workspace: phonemized_ws()})

    assert {:error, :boom} = Engine.run_check({DiffSinger, config(%{fail: true})}, request)
  end

  test "missing voicebank_root is rejected before calling the worker" do
    {:ok, request} = Request.new(%{workspace: phonemized_ws()})
    config = config() |> Map.delete(:voicebank_root)

    assert {:error, {:missing_config, :voicebank_root}} =
             Engine.run_check({DiffSinger, config}, request)

    refute_received {:fake_call, _}
  end

  test "globals gate rejects undeclared knobs before any worker call" do
    {:ok, request} = Request.new(%{workspace: phonemized_ws(), globals: %{breathiness: 1}})

    assert {:error, {:check_failed, [%{kind: :global, key: :breathiness} | _]}} =
             Engine.run_check({DiffSinger, config()}, request)

    refute_received {:fake_call, _}
  end
end
