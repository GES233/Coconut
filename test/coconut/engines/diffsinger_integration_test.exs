defmodule Coconut.Engines.DiffSingerIntegrationTest do
  @moduledoc """
  Real-worker integration: boots `lib/coconut/engines/diffsinger/worker.py` against the
  Qixuan voicebank and renders a short phrase. Excluded by default; run with

      mix test --include integration

  Paths are machine-specific; override with the `DS_PYTHON` / `DS_VOICEBANK`
  environment variables when they differ from the defaults below.
  """
  use ExUnit.Case, async: false

  alias Coconut.{Engine, Operate, Track, Workspace}
  alias Coconut.Engine.Request
  alias Coconut.Engines.DiffSinger
  alias Coconut.Util.ID

  @moduletag :integration
  @tag timeout: 600_000

  @voicebank "E:/ProgramAssets/OpenUTAUSingers/Qixuan_v2.5.0_DiffSinger_OpenUtau"
  @python Path.expand(".venv/Scripts/python.exe")

  # 两只老虎 — hanzi lyrics, phonemes derived by the worker encoder
  # (voicebank dsdict + pypinyin).
  @tigers [
    {"两", 0.5, 60},
    {"只", 0.5, 62},
    {"老", 0.5, 64},
    {"虎", 0.5, 60},
    {"两", 0.5, 60},
    {"只", 0.5, 62},
    {"老", 0.5, 64},
    {"虎", 0.5, 60},
    {"跑", 0.5, 64},
    {"得", 0.5, 65},
    {"快", 1.0, 67},
    {"跑", 0.5, 64},
    {"得", 0.5, 65},
    {"快", 1.0, 67}
  ]

  @tag tmp_dir: "ds_integration"
  test "check + render against the real voicebank", %{tmp_dir: tmp_dir} do
    voicebank = System.get_env("DS_VOICEBANK") || @voicebank
    python = System.get_env("DS_PYTHON") || @python

    if not File.dir?(voicebank), do: raise("voicebank not found: #{voicebank}")
    if not File.exists?(python), do: raise("python not found: #{python}")

    ws = tigers_workspace()

    config = %{
      voicebank_root: voicebank,
      python: [python],
      output_dir: tmp_dir,
      encoder: Coconut.Engines.DiffSinger.Encoder
    }

    # A pitch slide on the second note (spans tick 480..960 ⇒ 0.5..1.0 s)
    # forces the pitch re-run with pitch_in / retake injection; a duration
    # pin on the first note (phoneme 0 "l" shortened to 0.1 s) forces the
    # renormalized dur path.
    interventions = %{
      {:port, "n480", :pitch} => %{input: [[480, 62], [960, 64]]},
      {:port, "n0", :duration} => %{input: [[0, 96]]}
    }

    {:ok, request} =
      Request.for_workspace(ws,
        globals: %{gender: 0.2, steps: 10},
        interventions: interventions
      )

    assert {:ok, %{passed: true, checked: checked}} =
             Engine.run_check({DiffSinger, config}, request)

    assert {:ok, artifact} = Engine.run_render({DiffSinger, config}, request, checked)
    assert File.exists?(artifact.payload.path)
    assert artifact.globals == %{gender: 0.2, steps: 10}

    # Score timing is authoritative: with per-word renormalization the
    # rendered length matches the notated length (12×0.5 + 2×1.0 s),
    # overrides or not.
    assert_in_delta artifact.payload.duration_sec, 8.0, 0.05
  end

  # 120 BPM → 0.5 s per 480 ticks.
  defp tigers_workspace do
    {:ok, tempo} = Track.new(%{id: "tempo", module: Track.Tempo})
    {:ok, vocal} = Track.new(%{id: "vocal", module: Track.Vocal})

    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        tracks: %{"vocal" => vocal},
        tempo: tempo
      })

    ws = insert(ws, "tempo", "t0", :head, {0, 20_000}, %{bpm: 120})

    {ws, _prev, _tick} =
      Enum.reduce(@tigers, {ws, :head, 0}, fn {lyric, dur_sec, midi}, {ws, prev, tick} ->
        span_ticks = round(dur_sec * 960)
        id = "n#{tick}"

        ws =
          insert(ws, "vocal", id, prev, {tick, tick + span_ticks}, %{
            pitch: midi,
            lyric: lyric
          })

        {ws, id, tick + span_ticks}
      end)

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
end
