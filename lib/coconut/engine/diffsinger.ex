defmodule Coconut.Engine.DiffSinger do
  @moduledoc """
  DiffSinger engine adapter over the `priv/python/ds_worker.py` stdio worker.

  The heavy lifting (ONNX inference) lives in the Python worker; this module
  is the adaptation boundary:

  - **note assembly** — every element across every track, merged and
    sorted by start tick. Each note must carry `:pitch` (MIDI) and
    phonemes: either explicit `:phonemes` (`[[lang, ph], ...]` pairs —
    always wins) or derived by the configured encoder (see `Coconut.Encoder`),
    which runs once per track over the track's full note sequence so
    melisma and context-dependent readings have their phrase. Notes with
    neither are rejected at assembly time (`:missing_phonemes`,
    `:encoder_failed`, `:encoder_incomplete`).
  - **tick → second conversion** — via the workspace tempo map when a tempo
    track exists, else a flat 120 BPM fallback (the only place float
    seconds enter; design doc §4).
  - **globals** — `gender` / `velocity` / `depth` / `steps` are declared in
    `info/1` and forwarded to the worker from `Request.globals`.

  ## Interventions

  The adapter claims interventions at `{:port, note_id, :pitch}` — the
  fold shape produced by `Coconut.Channel.Pitch`. The value is a sparse
  piecewise-linear curve, `[[tick, midi], ...]` in absolute ticks; points
  are converted to seconds here and sampled onto the engine's frame grid
  by the worker (`pitch_in` / `retake` of the pitch model). A port naming
  an unknown note vetoes at check time (`passed: false`); ports of other
  shapes are left for other engines and ignored. The raw interventions
  map is echoed in the artifact as `:overrides`.

  ## Config

    * `:voicebank_root` — OpenUTAU-format DiffSinger voicebank dir (required)
    * `:output_dir` — where `render/2` writes the wav (default `./out`)
    * `:python` — command + args prefix for the interpreter, as a list
      (default `["python"]`; e.g. `["uv", "run", "--project", "..."]`)
    * `:client` — module replacing the worker client (test seam),
      default `Coconut.Engine.DiffSinger.PortClient`
    * `:encoder` — `Coconut.Encoder` module or `{module, config}` deriving
      phonemes for notes that lack explicit `:phonemes`. Manual for v1;
      voicebank-derived auto-selection waits for the voicebank
      declaration layer.
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
         {:ok, bundle} <- assemble(request, config) do
      case bundle.override_errors do
        [] ->
          with {:ok, probe} <-
                 call_client(
                   %{action: "check", words: bundle.words, globals: request.globals},
                   config
                 ) do
            {:ok,
             %{
               passed: true,
               entries: [],
               checked: %{words: bundle.words, overrides: bundle.overrides, probe: probe}
             }}
          end

        entries ->
          {:ok, %{passed: false, entries: entries, checked: nil}}
      end
    end
  end

  @impl true
  def render(%Request{} = request, checked, config) do
    with {:ok, config} <- normalize_config(config),
         {:ok, bundle} <- checked_bundle(checked, request, config),
         out_path = out_path(config),
         payload = render_payload(bundle, checked, request.globals, out_path),
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

  # Reuse what check assembled; reassemble when render is invoked without
  # a prior check (checked is nil or foreign).
  defp checked_bundle(%{words: _, overrides: _} = bundle, _request, _config), do: {:ok, bundle}
  defp checked_bundle(_checked, request, config), do: assemble(request, config)

  # The worker skips its own dur/pitch forwards when the probe from the
  # check stage is supplied (same Request ⇒ same words and globals).
  defp render_payload(bundle, checked, globals, out_path) do
    base = %{
      action: "render",
      words: bundle.words,
      overrides: bundle.overrides,
      globals: globals,
      out_path: out_path
    }

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

  # Assembles everything the worker needs from a Request: the word list
  # and the frame-bound overrides, plus any override validation errors.
  defp assemble(%Request{} = request, config) do
    tpqn = Map.get(config, :tpqn, @default_tpqn)
    ws = request.workspace

    with {:ok, to_sec} <- sec_converter(ws, tpqn),
         {:ok, notes} <- collect_notes(ws, Map.get(config, :encoder)) do
      words =
        Enum.map(notes, fn {_id, data, {start_tick, end_tick}} ->
          [data.phonemes, to_sec.(end_tick) - to_sec.(start_tick), data.pitch]
        end)

      {overrides, errors} = collect_overrides(request.interventions, notes, to_sec)
      {:ok, %{words: words, overrides: overrides, override_errors: errors}}
    end
  end

  # The adapter claims `{:port, note_id, :pitch}` interventions; other port
  # shapes belong to other engines and are ignored. Curve points arrive in
  # absolute ticks and leave in absolute seconds — the worker owns the
  # frame grid.
  defp collect_overrides(interventions, notes, to_sec) do
    index =
      notes
      |> Enum.with_index()
      |> Map.new(fn {{id, _data, _span}, i} -> {id, i} end)

    {overrides, errors} =
      Enum.reduce(interventions, {[], []}, fn
        {{:port, note_id, :pitch}, %{input: points}}, {oks, errs} ->
          case Map.fetch(index, note_id) do
            {:ok, i} ->
              points = Enum.map(points, fn [tick, midi] -> [to_sec.(tick), midi] end)
              {[%{kind: "pitch", note_index: i, points: points} | oks], errs}

            :error ->
              {oks, [%{kind: :unknown_note, note_id: note_id} | errs]}
          end

        _foreign_port, acc ->
          acc
      end)

    {Enum.reverse(overrides), Enum.reverse(errors)}
  end

  # Notes are collected per track (phrase context lives within a track),
  # phonemes resolved there (explicit `:phonemes` win; the rest go to the
  # configured encoder), then merged into one score-ordered list.
  defp collect_notes(ws, encoder) do
    per_track =
      Map.new(ws.tracks, fn {track_id, _space} ->
        notes =
          for {id, span} <- Workspace.latest_spans(ws, track_id),
              data = Map.get(ws.side.elements_by_id, id, %{}),
              is_map(data),
              do: {id, data, span}

        {track_id,
         Enum.sort_by(notes, fn {id, _data, {start_tick, _end}} -> {start_tick, id} end)}
      end)

    with {:ok, per_track} <- resolve_phonemes(per_track, encoder) do
      notes =
        per_track
        |> Map.values()
        |> List.flatten()
        |> Enum.sort_by(fn {id, _data, {start_tick, _end}} -> {start_tick, id} end)

      missing_pitch =
        for {id, data, _span} <- notes, not is_integer(Map.get(data, :pitch)), do: id

      case missing_pitch do
        [] -> {:ok, notes}
        _ -> {:error, {:missing_pitch, missing_pitch}}
      end
    end
  end

  # The encoder sees the track's full sequence (context), but only notes
  # lacking explicit `:phonemes` consume its result.
  defp resolve_phonemes(per_track, encoder) do
    Enum.reduce_while(per_track, {:ok, %{}}, fn {track_id, notes}, {:ok, acc} ->
      unresolved = for {id, data, _span} <- notes, not has_phonemes?(data), do: id

      case {unresolved, encoder} do
        {[], _any} ->
          {:cont, {:ok, Map.put(acc, track_id, notes)}}

        {_, nil} ->
          {:halt, {:error, {:missing_phonemes, unresolved}}}

        {_, encoder} ->
          case encode_all(encoder, notes) do
            {:ok, by_id} ->
              case Enum.reject(unresolved, &Map.has_key?(by_id, &1)) do
                [] ->
                  notes = Enum.map(notes, &fill_phonemes(&1, by_id))
                  {:cont, {:ok, Map.put(acc, track_id, notes)}}

                missing ->
                  {:halt, {:error, {:encoder_incomplete, missing}}}
              end

            {:error, reason} ->
              {:halt, {:error, {:encoder_failed, reason}}}
          end
      end
    end)
  end

  defp fill_phonemes({id, data, span}, by_id) do
    if has_phonemes?(data) do
      {id, data, span}
    else
      {id, Map.put(data, :phonemes, Map.fetch!(by_id, id)), span}
    end
  end

  defp encode_all({module, encoder_config}, notes), do: module.encode(notes, encoder_config)
  defp encode_all(module, notes) when is_atom(module), do: module.encode(notes, nil)

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
