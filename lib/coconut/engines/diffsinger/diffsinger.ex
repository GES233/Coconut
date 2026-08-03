defmodule Coconut.Engines.DiffSinger do
  @moduledoc """
  DiffSinger engine adapter over the `lib/coconut/engines/diffsinger/worker.py` stdio worker.

  The heavy lifting (ONNX inference) lives in the Python worker; this module
  is the adaptation boundary:

  - **note assembly** — every element across every track, merged and
    sorted by start tick. Elements on note tracks are `Coconut.Score.Note`
    structs (cast at lowering): each must carry a `:key` (pitch) and
    phonemes — explicit `"phonemes"` metadata (`[[lang, ph], ...]` pairs,
    always wins) or derived by the configured encoder (see
    `Coconut.Encoder`), which runs once per track over the track's full
    note sequence so melisma and context-dependent readings have their
    phrase. Notes with neither are rejected at assembly time
    (`:missing_phonemes`, `:encoder_failed`, `:encoder_incomplete`).
  - **tick → second conversion** — via the snapshot's tempo map when a
    tempo track exists, else a flat 120 BPM fallback (the only place float
    seconds enter; design doc §4).
  - **globals** — `gender` / `velocity` / `depth` / `steps` are declared in
    `info/1` and forwarded to the worker from `Request.globals`.

  ## Interventions

  The adapter claims interventions at `{:port, note_id, :pitch}` and
  `{:port, note_id, :duration}` — the fold shapes produced by
  `Coconut.Engines.Channels.Pitch` / `Coconut.Engines.Channels.Duration`.

  Pitch values are sparse piecewise-linear curves, `[[tick, midi], ...]`
  in absolute ticks; points are converted to seconds here and sampled
  onto the engine's frame grid by the worker (`pitch_in` / `retake`).

  Duration values are sparse per-phoneme pins, `[[ph_index, dur_tick], ...]`;
  converted to seconds here. The worker renormalizes every word to its
  span-derived frame target — unpinned phonemes absorb the slack and the
  note's total stays on the score grid. Index out of range or a pinned
  total exceeding the note's span vetoes at check time.

  A port naming an unknown note vetoes at check time (`passed: false`);
  ports of other shapes are left for other engines and ignored. The raw
  interventions map is echoed in the artifact as `:overrides`.

  ## Config

    * `:voicebank_root` — OpenUTAU-format DiffSinger voicebank dir (required)
    * `:output_dir` — where `render/2` writes the wav (default `./out`)
    * `:python` — command + args prefix for the interpreter, as a list
      (default `["python"]`; e.g. `["uv", "run", "--project", "..."]`)
    * `:client` — module replacing the worker client (test seam),
      default `Coconut.Engines.DiffSinger.PortClient`
    * `:encoder` — `Coconut.Encoder` module or `{module, config}` deriving
      phonemes for notes that lack explicit `:phonemes`. The adapter's
      own config flows down to it (encoder-specific keys win). Bundled
      options: `Coconut.Engines.DiffSinger.Encoder` (worker-backed, uses
      the voicebank's dsdict) and `Coconut.Engines.Encoders.Literal`.
      Manual for v1; voicebank-derived auto-selection waits for the
      voicebank declaration layer.

  Client contract: `call(payload :: map(), config :: map()) ::
  {:ok, map()} | {:error, term()}`.
  """

  @behaviour Coconut.Engine

  alias Coconut.{Engine.Artifact, Engine.Request, Score.Key, Score.TempoMap}

  @default_client Coconut.Engines.DiffSinger.PortClient

  @impl true
  def info(_config) do
    %{
      name: "DiffSinger",
      version: "zongzi-svs",
      info: "Onnx DiffSinger runner.",
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
       %Artifact{
         engine: "DiffSinger",
         edit_version: request.snapshot.edit_version,
         globals: request.globals,
         overrides: request.interventions,
         payload: %{
           path: Map.get(result, "path", out_path),
           total_frames: Map.get(result, "total_frames"),
           duration_sec: Map.get(result, "duration_sec")
         }
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
    snapshot = request.snapshot
    tpqn = snapshot.tpqn

    with {:ok, to_sec} <- sec_converter(snapshot, tpqn),
         {:ok, notes} <- collect_notes(snapshot, config) do
      words =
        Enum.map(notes, fn {_id, data, {start_tick, end_tick}} ->
          [phonemes_of(data), to_sec.(end_tick) - to_sec.(start_tick), Key.to_midi(data.key)]
        end)

      {overrides, errors} = collect_overrides(request.interventions, notes, to_sec)
      {:ok, %{words: words, overrides: overrides, override_errors: errors}}
    end
  end

  # The adapter claims `{:port, note_id, :pitch|:duration}` interventions;
  # other port shapes belong to other engines and are ignored. Curve
  # points arrive in absolute ticks and leave in absolute seconds — the
  # worker owns the frame grid.
  defp collect_overrides(interventions, notes, to_sec) do
    index =
      notes
      |> Enum.with_index()
      |> Map.new(fn {{id, _data, _span}, i} -> {id, i} end)

    by_id = Map.new(notes, fn {id, data, span} -> {id, {data, span}} end)

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

        {{:port, note_id, :duration}, %{input: durations}}, {oks, errs} ->
          with {:ok, i} <- Map.fetch(index, note_id),
               {:ok, sec_durations} <-
                 convert_durations(durations, note_id, by_id[note_id], to_sec) do
            {[%{kind: "duration", note_index: i, durations: sec_durations} | oks], errs}
          else
            :error -> {oks, [%{kind: :unknown_note, note_id: note_id} | errs]}
            {:error, entries} -> {oks, entries ++ errs}
          end

        _foreign_port, acc ->
          acc
      end)

    {Enum.reverse(overrides), Enum.reverse(errors)}
  end

  # `[[ph_index, dur_tick], ...]` → `[[ph_index, dur_sec], ...]`.
  # Validations the adapter can own: index in range, pinned total within
  # the note's span.
  defp convert_durations(durations, note_id, {data, {start_tick, end_tick}}, to_sec) do
    phoneme_count = length(Map.get(data.metadata, "phonemes", []))
    note_sec = to_sec.(end_tick) - to_sec.(start_tick)

    {secs, errs} =
      Enum.reduce(durations, {[], []}, fn
        [idx, dur_tick], {ss, es}
        when is_integer(idx) and idx >= 0 and idx < phoneme_count and
               is_integer(dur_tick) and dur_tick >= 0 ->
          sec = to_sec.(start_tick + dur_tick) - to_sec.(start_tick)
          {[[idx, sec] | ss], es}

        [idx, _dur_tick], {ss, es} ->
          {ss, [%{kind: :bad_phoneme_index, note_id: note_id, index: idx} | es]}

        other, {ss, es} ->
          {ss, [%{kind: :bad_duration_point, note_id: note_id, point: other} | es]}
      end)

    pinned_sec = Enum.reduce(secs, 0.0, fn [_idx, sec], acc -> acc + sec end)

    cond do
      errs != [] -> {:error, Enum.reverse(errs)}
      pinned_sec > note_sec + 1.0e-6 -> {:error, [%{kind: :duration_overflow, note_id: note_id}]}
      true -> {:ok, Enum.reverse(secs)}
    end
  end

  # Notes come from the snapshot's per-track views (phrase context lives
  # within a track), phonemes resolved there (explicit `:phonemes` win;
  # the rest go to the configured encoder), then merged into one
  # score-ordered list. Only note-bearing tracks contribute — the tempo
  # track is not a score.
  defp collect_notes(snapshot, config) do
    per_track =
      snapshot.tracks
      |> Map.reject(fn {_track_id, view} -> view.module == Coconut.Track.Tempo end)
      |> Map.new(fn {track_id, view} -> {track_id, view.elements} end)

    with {:ok, per_track} <- resolve_phonemes(per_track, Map.get(config, :encoder), config) do
      notes =
        per_track
        |> Map.values()
        |> List.flatten()
        |> Enum.sort_by(fn {id, _data, {start_tick, _end}} -> {start_tick, id} end)

      missing_pitch =
        for {id, %Coconut.Score.Note{key: nil}, _span} <- notes, do: id

      case missing_pitch do
        [] -> {:ok, notes}
        _ -> {:error, {:missing_pitch, missing_pitch}}
      end
    end
  end

  # The encoder sees the track's full sequence (context), but only notes
  # lacking explicit `:phonemes` consume its result.
  defp resolve_phonemes(per_track, encoder, config) do
    Enum.reduce_while(per_track, {:ok, %{}}, fn {track_id, notes}, {:ok, acc} ->
      unresolved = for {id, data, _span} <- notes, not has_phonemes?(data), do: id

      case {unresolved, encoder} do
        {[], _any} ->
          {:cont, {:ok, Map.put(acc, track_id, notes)}}

        {_, nil} ->
          {:halt, {:error, {:missing_phonemes, unresolved}}}

        {_, encoder} ->
          case encode_all(encoder, notes, config) do
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

  defp fill_phonemes({id, %Coconut.Score.Note{} = note, span}, by_id) do
    if has_phonemes?(note) do
      {id, note, span}
    else
      {:ok, note} =
        Coconut.Score.Note.update_metadata(note, %{"phonemes" => Map.fetch!(by_id, id)})

      {id, note, span}
    end
  end

  # The adapter's own config flows down (voicebank_root / python / worker
  # / client apply to worker-backed encoders); encoder-specific config
  # wins on key conflicts.
  defp encode_all({module, encoder_config}, notes, config),
    do: module.encode(notes, Map.merge(config, encoder_config))

  defp encode_all(module, notes, config) when is_atom(module),
    do: module.encode(notes, config)

  defp has_phonemes?(%Coconut.Score.Note{metadata: metadata}),
    do: match?([_ | _], Map.get(metadata, "phonemes"))

  defp phonemes_of(%Coconut.Score.Note{metadata: %{"phonemes" => phonemes}}), do: phonemes

  # tick→sec via the snapshot's tempo map when available; flat 120 BPM
  # otherwise (the only place float seconds enter; design doc §4).
  defp sec_converter(%{tempo_map: nil}, tpqn),
    do: {:ok, fn tick -> tick / (tpqn * 2.0) end}

  defp sec_converter(%{tempo_map: tempo_map}, tpqn),
    do: {:ok, fn tick -> TempoMap.tick_to_sec(tempo_map, tick, tpqn) end}
end
