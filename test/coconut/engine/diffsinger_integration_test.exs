defmodule Coconut.Engine.DiffSingerIntegrationTest do
  @moduledoc """
  Real-worker integration: boots `priv/python/ds_worker.py` against the
  Qixuan voicebank and renders a short phrase. Excluded by default; run with

      mix test --include integration

  Paths are machine-specific; override with the `DS_PYTHON` / `DS_VOICEBANK`
  environment variables when they differ from the defaults below.
  """
  use ExUnit.Case, async: false

  alias Coconut.{Engine, Operate, Workspace}
  alias Coconut.Engine.{DiffSinger, Request}
  alias Coconut.Util.ID

  @moduletag :integration
  @tag timeout: 600_000

  @voicebank "E:/ProgramAssets/OpenUTAUSingers/Qixuan_v2.5.0_DiffSinger_OpenUtau"
  @python "D:/CodeRepo/SingingSynthesis/zongzi-svs/.venv/Scripts/python.exe"

  # 两只老虎, matching zongzi-svs scripts/render_ds_tigers.py.
  @tigers [
    {[["zh", "l"], ["zh", "iang"]], 0.5, 60},
    {[["zh", "zh"], ["zh", "i"]], 0.5, 62},
    {[["zh", "l"], ["zh", "ao"]], 0.5, 64},
    {[["zh", "h"], ["zh", "u"]], 0.5, 60},
    {[["zh", "l"], ["zh", "iang"]], 0.5, 60},
    {[["zh", "zh"], ["zh", "i"]], 0.5, 62},
    {[["zh", "l"], ["zh", "ao"]], 0.5, 64},
    {[["zh", "h"], ["zh", "u"]], 0.5, 60},
    {[["zh", "p"], ["zh", "ao"]], 0.5, 64},
    {[["zh", "d"], ["zh", "e"]], 0.5, 65},
    {[["zh", "k"], ["zh", "uai"]], 1.0, 67},
    {[["zh", "p"], ["zh", "ao"]], 0.5, 64},
    {[["zh", "d"], ["zh", "e"]], 0.5, 65},
    {[["zh", "k"], ["zh", "uai"]], 1.0, 67}
  ]

  @tag tmp_dir: "ds_integration"
  test "check + render against the real voicebank", %{tmp_dir: tmp_dir} do
    voicebank = System.get_env("DS_VOICEBANK") || @voicebank
    python = System.get_env("DS_PYTHON") || @python

    if not File.dir?(voicebank), do: raise("voicebank not found: #{voicebank}")
    if not File.exists?(python), do: raise("python not found: #{python}")

    ws = tigers_workspace()
    config = %{voicebank_root: voicebank, python: [python], output_dir: tmp_dir}

    # A pitch slide on the second note (spans tick 480..960 ⇒ 0.5..1.0 s)
    # forces the pitch re-run with pitch_in / retake injection.
    interventions = %{{:port, "n480", :pitch} => %{input: [[480, 62], [960, 64]]}}

    {:ok, request} =
      Request.new(%{
        workspace: ws,
        globals: %{gender: 0.2, steps: 10},
        interventions: interventions
      })

    assert {:ok, %{passed: true, checked: checked}} =
             Engine.run_check({DiffSinger, config}, request)

    assert {:ok, artifact} = Engine.run_render({DiffSinger, config}, request, checked)
    assert File.exists?(artifact.path)
    assert artifact.duration_sec > 0
    assert artifact.globals == %{gender: 0.2, steps: 10}
  end

  # 120 BPM → 0.5 s per 480 ticks.
  defp tigers_workspace do
    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        tempo_space: %Tamale.Space{},
        tracks: %{vocal: %Tamale.Space{}},
        side: %Workspace.Side{}
      })

    ws = insert(ws, :tempo, "t0", :head, {0, 20_000}, %{bpm: 120})

    {ws, _prev, _tick} =
      Enum.reduce(@tigers, {ws, :head, 0}, fn {phonemes, dur_sec, midi}, {ws, prev, tick} ->
        span_ticks = round(dur_sec * 960)
        id = "n#{tick}"

        ws =
          insert(ws, :vocal, id, prev, {tick, tick + span_ticks}, %{
            pitch: midi,
            phonemes: phonemes
          })

        {ws, id, tick + span_ticks}
      end)

    ws
  end

  defp insert(ws, track, id, after_id, span, attrs) do
    {:ok, ops, changes} =
      Operate.lower({:insert_note, track, id, after_id, span, attrs}, ws, %Operate.Config{})

    {:ok, ws} = Workspace.apply_batch(ws, track, ws.edit_version, ops, changes)
    ws
  end
end
