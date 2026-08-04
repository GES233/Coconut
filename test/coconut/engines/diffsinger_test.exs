defmodule Coconut.Engines.DiffSingerTest do
  use ExUnit.Case, async: true

  alias Coconut.{Engine, Operate, Track, Workspace}
  alias Coconut.Engine.Request
  alias Coconut.Engines.DiffSinger
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

        {_, "encode"} ->
          {:ok, %{"tokens" => Map.new(payload.notes, fn note -> {note.id, [["zh", "x"]]} end)}}

        {_, "render"} ->
          {:ok, %{"path" => payload.out_path, "total_frames" => 480, "duration_sec" => 5.0}}
      end
    end
  end

  defmodule RecordingEncoder do
    @moduledoc "Records the note sequence it receives, covers everything."
    @behaviour Coconut.Encoder

    @impl true
    def encode(notes, config) do
      if pid = config[:test_pid],
        do: send(pid, {:encoder_called, Enum.map(notes, fn {id, _data, _span} -> id end)})

      {:ok, Map.new(notes, fn {id, _data, _span} -> {id, [["zh", "x"]]} end)}
    end
  end

  defmodule PartialEncoder do
    @moduledoc "Covers nothing."
    @behaviour Coconut.Encoder

    @impl true
    def encode(_notes, _config), do: {:ok, %{}}
  end

  defp config(extra \\ %{}) do
    Map.merge(
      %{voicebank_root: "unused/fake", client: FakeClient, test_pid: self()},
      Map.new(extra)
    )
  end

  defp workspace(opts \\ []) do
    {:ok, vocal} = Track.new(%{id: "vocal", module: Track.Vocal})
    {:ok, harmony} = Track.new(%{id: "harmony", module: Track.Vocal})

    attrs = %{
      id: ID.generate_id("WSpc_"),
      edit_version: 0,
      tracks: %{"vocal" => vocal, "harmony" => harmony}
    }

    # tempo: false → default empty tempo track (tempo_map nil, engine fallback).
    attrs =
      if Keyword.get(opts, :tempo, true) do
        {:ok, tempo} = Track.new(%{id: "tempo", module: Track.Tempo})
        Map.put(attrs, :tempo, tempo)
      else
        attrs
      end

    {:ok, ws} = Workspace.new(attrs)
    ws
  end

  defp insert(ws, track, id, after_id, span, attrs) do
    {:ok, ops, changes} =
      Operate.lower(
        %Coconut.Operations.InsertNote{
          track_id: track,
          note_id: id,
          after_id: after_id,
          span: span,
          attrs: attrs
        },
        ws,
        %Operate.Config{}
      )

    {:ok, ws} = Workspace.apply_batch(ws, track, ws.edit_version, ops, changes)
    ws
  end

  # Two phonemized vocal notes over a flat 120 BPM tempo track.
  defp phonemized_ws(opts \\ []) do
    ws = workspace(opts)

    ws =
      if opts[:tempo] == false,
        do: ws,
        else: insert(ws, "tempo", "t0", :head, {0, 9600}, %{bpm: 120})

    ws
    |> insert("vocal", "n1", :head, {0, 480}, %{pitch: 60, phonemes: [["zh", "l"], ["zh", "a"]]})
    |> insert("vocal", "n2", "n1", {480, 960}, %{pitch: 62, phonemes: [["zh", "z"], ["zh", "i"]]})
  end

  test "check assembles words from phonemized notes over the tempo map" do
    {:ok, request} = Request.for_workspace(phonemized_ws())

    assert {:ok, %{passed: true}} = Engine.run_check({DiffSinger, config()}, request)

    assert_received {:fake_call, %{action: "check", words: words, globals: %{}}}
    assert [[ph1, dur1, midi1], [ph2, dur2, midi2]] = words
    assert ph1 == [["zh", "l"], ["zh", "a"]]
    assert_in_delta dur1, 0.5, 0.001
    assert midi1 == 60.0
    assert ph2 == [["zh", "z"], ["zh", "i"]]
    assert_in_delta dur2, 0.5, 0.001
    assert midi2 == 62.0
  end

  test "notes across tracks are merged and sorted by start tick" do
    ws =
      phonemized_ws()
      |> insert("harmony", "h1", :head, {0, 960}, %{
        pitch: 55,
        phonemes: [["zh", "h"], ["zh", "u"]]
      })

    {:ok, request} = Request.for_workspace(ws)

    assert {:ok, %{passed: true}} = Engine.run_check({DiffSinger, config()}, request)

    assert_received {:fake_call, %{words: words}}
    assert Enum.map(words, fn [_ph, _dur, midi] -> midi end) == [55.0, 60.0, 62.0]
  end

  test "check rejects notes without phonemes before calling the worker" do
    ws =
      workspace()
      |> insert("tempo", "t0", :head, {0, 9600}, %{bpm: 120})
      |> insert("vocal", "n1", :head, {0, 480}, %{pitch: 60})

    {:ok, request} = Request.for_workspace(ws)

    assert {:error, {:missing_phonemes, ["n1"]}} =
             Engine.run_check({DiffSinger, config()}, request)

    refute_received {:fake_call, _}
  end

  test "check rejects notes without pitch" do
    ws =
      workspace()
      |> insert("tempo", "t0", :head, {0, 9600}, %{bpm: 120})
      |> insert("vocal", "n1", :head, {0, 480}, %{phonemes: [["zh", "a"]]})

    {:ok, request} = Request.for_workspace(ws)

    assert {:error, {:missing_pitch, ["n1"]}} = Engine.run_check({DiffSinger, config()}, request)
    refute_received {:fake_call, _}
  end

  test "worker-backed encoder flows lyrics and adapter config through" do
    ws =
      workspace()
      |> insert("tempo", "t0", :head, {0, 9600}, %{bpm: 120})
      |> insert("vocal", "n1", :head, {0, 480}, %{pitch: 60, lyric: "两"})

    config = config(%{encoder: Coconut.Engines.DiffSinger.Encoder})
    {:ok, request} = Request.for_workspace(ws)

    assert {:ok, %{passed: true}} = Engine.run_check({DiffSinger, config}, request)

    # the encode call carries the lyric; adapter config (client, test_pid)
    # flowed down to the encoder
    assert_received {:fake_call,
                     %{action: "encode", notes: [%{id: "n1", lyric: "两", lang: "zh"}]}}

    assert_received {:fake_call, %{action: "check", words: [[phonemes, _dur, 60.0]]}}
    assert phonemes == [["zh", "x"]]
  end

  test "notes without phonemes go through the configured encoder" do
    ws =
      workspace()
      |> insert("tempo", "t0", :head, {0, 9600}, %{bpm: 120})
      |> insert("vocal", "n1", :head, {0, 480}, %{pitch: 60, lyric: "l iang"})

    config = config(%{encoder: {Coconut.Engines.Encoders.Literal, %{lang: "zh"}}})
    {:ok, request} = Request.for_workspace(ws)

    assert {:ok, %{passed: true}} = Engine.run_check({DiffSinger, config}, request)

    assert_received {:fake_call, %{words: [[phonemes, _dur, 60.0]]}}
    assert phonemes == [["zh", "l"], ["zh", "iang"]]
  end

  test "a note's :lang key overrides the encoder's configured language" do
    ws =
      workspace()
      |> insert("tempo", "t0", :head, {0, 9600}, %{bpm: 120})
      |> insert("vocal", "n1", :head, {0, 480}, %{pitch: 60, lyric: "a", lang: "ja"})

    config = config(%{encoder: {Coconut.Engines.Encoders.Literal, %{lang: "zh"}}})
    {:ok, request} = Request.for_workspace(ws)

    assert {:ok, %{passed: true}} = Engine.run_check({DiffSinger, config}, request)

    assert_received {:fake_call, %{words: [[phonemes, _dur, 60.0]]}}
    assert phonemes == [["ja", "a"]]
  end

  test "explicit phonemes win over the encoder" do
    ws =
      workspace()
      |> insert("tempo", "t0", :head, {0, 9600}, %{bpm: 120})
      |> insert("vocal", "n1", :head, {0, 480}, %{
        pitch: 60,
        lyric: "l iang",
        phonemes: [["zh", "manual"]]
      })

    config = config(%{encoder: {Coconut.Engines.Encoders.Literal, %{lang: "zh"}}})
    {:ok, request} = Request.for_workspace(ws)

    assert {:ok, %{passed: true}} = Engine.run_check({DiffSinger, config}, request)

    assert_received {:fake_call, %{words: [[phonemes, _dur, 60.0]]}}
    assert phonemes == [["zh", "manual"]]
  end

  test "the encoder is called once per track with the full score-ordered sequence" do
    ws =
      workspace()
      |> insert("tempo", "t0", :head, {0, 9600}, %{bpm: 120})
      |> insert("vocal", "n1", :head, {0, 480}, %{pitch: 60, lyric: "a"})
      |> insert("vocal", "n2", "n1", {480, 960}, %{pitch: 62, phonemes: [["zh", "i"]]})
      |> insert("harmony", "h1", :head, {0, 960}, %{pitch: 55, lyric: "u"})

    config = config(%{encoder: {RecordingEncoder, %{test_pid: self()}}})
    {:ok, request} = Request.for_workspace(ws)

    assert {:ok, %{passed: true}} = Engine.run_check({DiffSinger, config}, request)

    # one call per track, full sequence in score order — explicit-phoneme
    # notes included as context
    assert_received {:encoder_called, ids1}
    assert_received {:encoder_called, ids2}
    assert Enum.sort([ids1, ids2]) == Enum.sort([["n1", "n2"], ["h1"]])
  end

  test "encoder failure aborts assembly before calling the worker" do
    ws =
      workspace()
      |> insert("tempo", "t0", :head, {0, 9600}, %{bpm: 120})
      |> insert("vocal", "n1", :head, {0, 480}, %{pitch: 60, lyric: " "})

    config = config(%{encoder: Coconut.Engines.Encoders.Literal})
    {:ok, request} = Request.for_workspace(ws)

    assert {:error, {:encoder_failed, {:empty_lyric, "n1"}}} =
             Engine.run_check({DiffSinger, config}, request)

    refute_received {:fake_call, _}
  end

  test "encoder result not covering every note aborts assembly" do
    ws =
      workspace()
      |> insert("tempo", "t0", :head, {0, 9600}, %{bpm: 120})
      |> insert("vocal", "n1", :head, {0, 480}, %{pitch: 60, lyric: "a"})

    config = config(%{encoder: PartialEncoder})
    {:ok, request} = Request.for_workspace(ws)

    assert {:error, {:encoder_incomplete, ["n1"]}} =
             Engine.run_check({DiffSinger, config}, request)

    refute_received {:fake_call, _}
  end

  test "no tempo track falls back to flat 120 BPM" do
    ws =
      workspace(tempo: false)
      |> insert("vocal", "n1", :head, {0, 480}, %{pitch: 60, phonemes: [["zh", "a"]]})

    {:ok, request} = Request.for_workspace(ws)

    assert {:ok, %{passed: true}} = Engine.run_check({DiffSinger, config()}, request)

    assert_received {:fake_call, %{words: [[_ph, dur, 60.0]]}}
    assert_in_delta dur, 0.5, 0.0001
  end

  @tag tmp_dir: "ds_out"
  test "render returns artifact with path, frames, globals and overrides", %{tmp_dir: tmp_dir} do
    config = config(%{output_dir: tmp_dir})
    globals = %{gender: 0.5, steps: 40}
    interventions = %{{:port, :synth, :lyric} => %{input: "x"}}

    {:ok, request} =
      Request.for_workspace(phonemized_ws(), globals: globals, interventions: interventions)

    assert {:ok, %{passed: true, checked: checked}} =
             Engine.run_check({DiffSinger, config}, request)

    assert {:ok, artifact} = Engine.run_render({DiffSinger, config}, request, checked)

    assert artifact.globals == globals
    assert artifact.overrides == interventions
    assert artifact.payload.total_frames == 480
    assert String.starts_with?(artifact.payload.path, tmp_dir)

    # The check-stage probe (words + dur/pitch forwards) is handed to
    # render so the worker skips recomputing them.
    assert_received {:fake_call,
                     %{action: "render", out_path: out_path, globals: ^globals} = payload}

    assert out_path == artifact.payload.path
    assert payload.words == checked.words
    assert payload.ph_dur == [10, 20]
    assert payload.pitch_pred_midi == [60.0, 62.0]
  end

  test "pitch intervention becomes a second-domain override in the render payload" do
    interventions = %{{:port, "n2", :pitch} => %{input: [[480, 62], [960, 64]]}}

    {:ok, request} = Request.for_workspace(phonemized_ws(), interventions: interventions)

    assert {:ok, %{passed: true, checked: checked}} =
             Engine.run_check({DiffSinger, config()}, request)

    assert {:ok, _artifact} = Engine.run_render({DiffSinger, config()}, request, checked)

    assert_received {:fake_call, %{action: "render", overrides: [override]}}
    assert override.kind == "pitch"
    assert override.note_index == 1
    assert [[s1, m1], [s2, m2]] = override.points
    assert_in_delta s1, 0.5, 0.001
    assert m1 == 62
    assert_in_delta s2, 1.0, 0.001
    assert m2 == 64
  end

  test "intervention on an unknown note vetoes at check before calling the worker" do
    interventions = %{{:port, "nope", :pitch} => %{input: [[0, 60.0]]}}
    {:ok, request} = Request.for_workspace(phonemized_ws(), interventions: interventions)

    assert {:ok, %{passed: false, entries: [entry], checked: nil}} =
             Engine.run_check({DiffSinger, config()}, request)

    assert entry == %{kind: :unknown_note, note_id: "nope"}
    refute_received {:fake_call, _}
  end

  test "duration intervention becomes second-domain pins in the render payload" do
    interventions = %{{:port, "n1", :duration} => %{input: [[0, 96]]}}

    {:ok, request} = Request.for_workspace(phonemized_ws(), interventions: interventions)

    assert {:ok, %{passed: true, checked: checked}} =
             Engine.run_check({DiffSinger, config()}, request)

    assert {:ok, _artifact} = Engine.run_render({DiffSinger, config()}, request, checked)

    assert_received {:fake_call, %{action: "render", overrides: [override]}}
    assert override.kind == "duration"
    assert override.note_index == 0
    assert [[0, sec]] = override.durations
    assert_in_delta sec, 0.1, 0.001
  end

  test "duration pin with out-of-range phoneme index vetoes at check" do
    interventions = %{{:port, "n1", :duration} => %{input: [[5, 96]]}}
    {:ok, request} = Request.for_workspace(phonemized_ws(), interventions: interventions)

    assert {:ok, %{passed: false, entries: [entry]}} =
             Engine.run_check({DiffSinger, config()}, request)

    assert entry == %{kind: :bad_phoneme_index, note_id: "n1", index: 5}
    refute_received {:fake_call, _}
  end

  test "duration pins exceeding the note span veto at check" do
    # n1 spans 0.5 s; 0.5 + 0.25 s of pins overflows
    interventions = %{{:port, "n1", :duration} => %{input: [[0, 480], [1, 240]]}}
    {:ok, request} = Request.for_workspace(phonemized_ws(), interventions: interventions)

    assert {:ok, %{passed: false, entries: [entry]}} =
             Engine.run_check({DiffSinger, config()}, request)

    assert entry == %{kind: :duration_overflow, note_id: "n1"}
    refute_received {:fake_call, _}
  end

  test "foreign ports are ignored" do
    interventions = %{{:port, :synth, :lyric} => %{input: "x"}}
    {:ok, request} = Request.for_workspace(phonemized_ws(), interventions: interventions)

    assert {:ok, %{passed: true, checked: checked}} =
             Engine.run_check({DiffSinger, config()}, request)

    assert {:ok, _artifact} = Engine.run_render({DiffSinger, config()}, request, checked)

    assert_received {:fake_call, %{action: "render", overrides: []}}
  end

  test "worker error propagates" do
    {:ok, request} = Request.for_workspace(phonemized_ws())

    assert {:error, :boom} = Engine.run_check({DiffSinger, config(%{fail: true})}, request)
  end

  test "missing voicebank_root is rejected before calling the worker" do
    {:ok, request} = Request.for_workspace(phonemized_ws())
    config = config() |> Map.delete(:voicebank_root)

    assert {:error, {:missing_config, :voicebank_root}} =
             Engine.run_check({DiffSinger, config}, request)

    refute_received {:fake_call, _}
  end

  test "globals gate rejects undeclared knobs before any worker call" do
    {:ok, request} = Request.for_workspace(phonemized_ws(), globals: %{breathiness: 1})

    assert {:ok, %{passed: false, entries: [%{kind: :global, key: :breathiness} | _]}} =
             Engine.run_check({DiffSinger, config()}, request)

    refute_received {:fake_call, _}
  end
end
