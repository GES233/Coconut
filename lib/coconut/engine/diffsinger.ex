defmodule Coconut.Engine.DiffSinger do
  @moduledoc """
  DiffSinger engine adapter over the `priv/python/ds_worker.py` stdio worker.

  The heavy lifting (ONNX inference) lives in the Python worker; this module
  is the adaptation boundary:

  - **note assembly** — every element across every track, merged and sorted
    by start tick. Each note must carry `:phonemes` (`[[lang, ph], ...]`
    pairs) and `:pitch` (MIDI) in its element data: G2P is a separate,
    still-missing layer, and `check/2` rejects notes lacking them instead
    of guessing.
  - **tick → second conversion** — via the workspace tempo map when a tempo
    track exists, else a flat 120 BPM fallback (the only place float
    seconds enter; design doc §4).
  - **globals** — `gender` / `velocity` / `depth` / `steps` are declared in
    `info/1` and forwarded to the worker from `Request.globals`.

  Interventions are **not yet mapped** onto the diffusion inputs — `render/2`
  synthesizes the base score and echoes `request.interventions` in the
  artifact as `:overrides`.

  ## Config

    * `:voicebank_root` — OpenUTAU-format DiffSinger voicebank dir (required)
    * `:output_dir` — where `render/2` writes the wav (default `./out`)
    * `:python` — command + args prefix for the interpreter, as a list
      (default `["python"]`; e.g. `["uv", "run", "--project", "..."]`)
    * `:client` — module replacing the worker client (test seam),
      default `Coconut.Engine.DiffSinger.PortClient`
    * `:tpqn` — ticks per quarter note (default 480)

  Client contract: `call(payload :: map(), config :: map()) ::
  {:ok, map()} | {:error, term()}`.
  """

  @behaviour Coconut.Engine

  alias Coconut.{Engine.Request, Score.TempoMap, Workspace}

  @default_client Coconut.Engine.DiffSinger.PortClient
  @default_tpqn 480

  @impl true
  def info(_config) do
    %{
      name: "DiffSinger",
      version: "zongzi-svs",
      globals: %{
        gender: {:range, -1.0, 1.0},
        velocity: {:range, 0.1, 3.0},
        depth: {:range, 0.0, 2.0},
        steps: {:range, 1, 100}
      }
    }
  end

  @impl true
  def check(%Request{} = request, config) do
    with {:ok, config} <- normalize_config(config),
         {:ok, words} <- words(request.workspace, config),
         {:ok, probe} <-
           call_client(%{action: "check", words: words, globals: request.globals}, config) do
      {:ok, %{words: words, probe: probe}}
    end
  end

  @impl true
  def render(%Request{} = request, checked, config) do
    with {:ok, config} <- normalize_config(config),
         {:ok, words} <- checked_words(checked, request.workspace, config),
         out_path = out_path(config),
         payload = render_payload(words, checked, request.globals, out_path),
         {:ok, result} <- call_client(payload, config) do
      {:ok,
       %{
         path: Map.get(result, "path", out_path),
         total_frames: Map.get(result, "total_frames"),
         duration_sec: Map.get(result, "duration_sec"),
         globals: request.globals,
         overrides: request.interventions
       }}
    end
  end

  # Reuse the words assembled at check time; reassemble when render is
  # invoked without a prior check (checked is nil or foreign).
  defp checked_words(%{words: words}, _ws, _config), do: {:ok, words}
  defp checked_words(_checked, ws, config), do: words(ws, config)

  # The worker skips its own dur/pitch forwards when the probe from the
  # check stage is supplied (same Request ⇒ same words and globals).
  defp render_payload(words, checked, globals, out_path) do
    base = %{action: "render", words: words, globals: globals, out_path: out_path}

    case checked do
      %{probe: %{"ph_dur" => ph_dur, "pitch_pred_midi" => pitch_pred}} ->
        base |> Map.put(:ph_dur, ph_dur) |> Map.put(:pitch_pred_midi, pitch_pred)

      _other ->
        base
    end
  end

  # ---- Config ----

  defp normalize_config(config) do
    config = Map.new(config || [])

    case Map.get(config, :voicebank_root) do
      nil -> {:error, {:missing_config, :voicebank_root}}
      _ -> {:ok, config}
    end
  end

  defp out_path(config) do
    dir = Map.get(config, :output_dir, Path.join(File.cwd!(), "out"))
    Path.join(dir, "ds_#{System.unique_integer([:positive])}.wav")
  end

  defp call_client(payload, config) do
    client = Map.get(config, :client, @default_client)
    client.call(payload, config)
  end

  # ---- Note assembly ----

  defp words(%Workspace{} = ws, config) do
    tpqn = Map.get(config, :tpqn, @default_tpqn)

    with {:ok, to_sec} <- sec_converter(ws, tpqn),
         {:ok, notes} <- collect_notes(ws) do
      words =
        Enum.map(notes, fn {_id, data, {start_tick, end_tick}} ->
          [data.phonemes, to_sec.(end_tick) - to_sec.(start_tick), data.pitch]
        end)

      {:ok, words}
    end
  end

  defp collect_notes(ws) do
    notes =
      for {track_id, _space} <- ws.tracks,
          {id, span} <- Workspace.latest_spans(ws, track_id),
          data = Map.get(ws.side.elements_by_id, id, %{}),
          is_map(data),
          do: {id, data, span}

    # Deterministic across tracks: start tick first, id as tiebreak.
    notes = Enum.sort_by(notes, fn {id, _data, {start_tick, _end}} -> {start_tick, id} end)

    missing_phonemes = for {id, data, _span} <- notes, not has_phonemes?(data), do: id
    missing_pitch = for {id, data, _span} <- notes, not is_integer(Map.get(data, :pitch)), do: id

    cond do
      missing_phonemes != [] -> {:error, {:missing_phonemes, missing_phonemes}}
      missing_pitch != [] -> {:error, {:missing_pitch, missing_pitch}}
      true -> {:ok, notes}
    end
  end

  defp has_phonemes?(data), do: match?([_ | _], Map.get(data, :phonemes))

  # tick→sec via the tempo map when available; flat 120 BPM otherwise.
  defp sec_converter(ws, tpqn) do
    case Workspace.tempo_map(ws, tpqn: tpqn) do
      {:ok, tempo_map} -> {:ok, fn tick -> TempoMap.tick_to_sec(tempo_map, tick, tpqn) end}
      {:error, :no_tempo_track} -> {:ok, fn tick -> tick / (tpqn * 2.0) end}
      {:error, _} = error -> error
    end
  end
end
