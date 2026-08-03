# Note → audio end-to-end: hanzi lyrics + an intervention → a wav file.
#
# Run:
#
#     mix run examples/sing.exs
#
# Paths are machine-specific; override with env vars when they differ:
# DS_VOICEBANK, DS_PYTHON.

alias Coconut.{Engine, Operate, Track, Workspace}
alias Coconut.Engine.Request
alias Coconut.Engines.DiffSinger
alias Coconut.Util.ID

voicebank =
  System.get_env("DS_VOICEBANK") ||
    "E:/ProgramAssets/OpenUTAUSingers/Qixuan_v2.5.0_DiffSinger_OpenUtau"

python = System.get_env("DS_PYTHON") || Path.expand(".venv/Scripts/python.exe")

config = %{
  voicebank_root: voicebank,
  python: [python],
  output_dir: Path.expand("out"),
  encoder: Coconut.Engines.DiffSinger.Encoder
}

# ---- 1. Score: tempo + notes (lyric + pitch, phonemes come from the encoder) ----
{:ok, tempo_track} = Track.new(%{id: "tempo", module: Track.Tempo})
{:ok, vocal_track} = Track.new(%{id: "vocal", module: Track.Vocal})

{:ok, ws} =
  Workspace.new(%{
    id: ID.generate_id("WSpc_"),
    edit_version: 0,
    tracks: %{"vocal" => vocal_track},
    tempo: tempo_track
  })

insert = fn ws, track, id, after_id, span, attrs ->
  {:ok, ops, changes} =
    Operate.lower({:insert_note, track, id, after_id, span, attrs}, ws, %Operate.Config{})

  {:ok, ws} = Workspace.apply_batch(ws, track, ws.edit_version, ops, changes)
  ws
end

# 120 BPM → 0.5 s per 480 ticks.
ws = insert.(ws, "tempo", "t0", :head, {0, 9600}, %{bpm: 120})

song = [
  {"两", 60},
  {"只", 62},
  {"老", 64},
  {"虎", 60},
  {"跑", 64},
  {"得", 65},
  {"快", 67}
]

{ws, _prev, _tick} =
  Enum.reduce(song, {ws, :head, 0}, fn {lyric, midi}, {ws, prev, tick} ->
    id = "n#{tick}"
    ws = insert.(ws, "vocal", id, prev, {tick, tick + 480}, %{pitch: midi, lyric: lyric})
    {ws, id, tick + 480}
  end)

# ---- 2. Interventions: a pitch slide on 老, a shorter initial on 跑 ----
interventions = %{
  {:port, "n960", :pitch} => %{input: [[960, 64], [1440, 65]]},
  {:port, "n1920", :duration} => %{input: [[0, 96]]}
}

{:ok, request} =
  Request.for_workspace(ws, globals: %{steps: 20}, interventions: interventions)

# ---- 3. Check, then render ----
IO.puts("check...")

case Engine.run_check({DiffSinger, config}, request) do
  {:ok, %{passed: true, checked: checked}} ->
    IO.puts("render... (diffusion takes a while)")
    {:ok, artifact} = Engine.run_render({DiffSinger, config}, request, checked)
    IO.puts("wav:      #{artifact.payload.path}")
    IO.puts("duration: #{Float.round(artifact.payload.duration_sec, 2)} s")

  {:ok, %{passed: false, entries: entries}} ->
    IO.puts("vetoed:")
    Enum.each(entries, &IO.inspect/1)

  {:error, reason} ->
    IO.puts("check could not execute: #{inspect(reason)}")
end
