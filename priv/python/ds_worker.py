"""DiffSinger stdio worker for coconut (NDJSON over stdin/stdout).

Adapted from zongzi-svs `diffsinger/engine.py`: loads the OpenUTAU-format
voicebank once at startup, then serves one JSON request per line.

  request:  {"id": int, "action": "check" | "render",
             "words": [[[lang, ph], ...], dur_sec, midi],
             "globals": {"gender": f, "velocity": f, "depth": f, "steps": i},
             "out_path": str (render only),
             "ph_dur": [int] (render only, from a prior check),
             "pitch_pred_midi": [float] (render only, from a prior check)}
  response: {"id": int, "ok": true, "result": {...}} |
            {"id": int, "ok": false, "error": str}

Startup (after the voicebank is loaded):
  {"ready": true, "sample_rate": int, "hop_size": int}

Requires: onnxruntime, soundfile, numpy, pyyaml.
"""

import json
import os
import sys

import numpy as np
import onnxruntime as ort
import soundfile as sf
import yaml

DEFAULT_GLOBALS = {"gender": 0.0, "velocity": 1.0, "depth": 1.0, "steps": 20}


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_yaml(path):
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


class DiffSingerEngine:
    def __init__(self, model_root) -> None:
        self.root = model_root
        self.acoustic_cfg = load_yaml(os.path.join(model_root, "dsconfig.yaml"))
        self.dur_cfg = load_yaml(os.path.join(model_root, "dsdur/dsconfig.yaml"))
        self.pitch_cfg = load_yaml(os.path.join(model_root, "dspitch/dsconfig.yaml"))
        self.var_cfg = load_yaml(os.path.join(model_root, "dsvariance/dsconfig.yaml"))
        self.vocoder_cfg = load_yaml(os.path.join(model_root, "dsvocoder/vocoder.yaml"))

        # phoneme/language dicts (may differ per model)
        self.dur_phonemes = load_json(os.path.join(model_root, "dsdur", self.dur_cfg["phonemes"]))
        self.dur_langs = load_json(os.path.join(model_root, "dsdur", self.dur_cfg["languages"]))
        self.pitch_phonemes = load_json(os.path.join(model_root, "dspitch", self.pitch_cfg["phonemes"]))
        self.pitch_langs = load_json(os.path.join(model_root, "dspitch", self.pitch_cfg["languages"]))
        self.var_phonemes = load_json(os.path.join(model_root, "dsvariance", self.var_cfg["phonemes"]))
        self.var_langs = load_json(os.path.join(model_root, "dsvariance", self.var_cfg["languages"]))
        self.acoustic_phonemes = load_json(os.path.join(model_root, self.acoustic_cfg["phonemes"]))
        self.acoustic_langs = load_json(os.path.join(model_root, self.acoustic_cfg["languages"]))

        # ONNX sessions
        self.sess_dur_ling = self._make_session(os.path.join(model_root, "dsdur", self.dur_cfg["linguistic"]))
        self.sess_dur = self._make_session(os.path.join(model_root, "dsdur", self.dur_cfg["dur"]))
        self.sess_pitch_ling = self._make_session(os.path.join(model_root, "dspitch", self.pitch_cfg["linguistic"]))
        self.sess_pitch = self._make_session(os.path.join(model_root, "dspitch", self.pitch_cfg["pitch"]))
        self.sess_var_ling = self._make_session(os.path.join(model_root, "dsvariance", self.var_cfg["linguistic"]))
        self.sess_var = self._make_session(os.path.join(model_root, "dsvariance", self.var_cfg["variance"]))
        self.sess_acoustic = self._make_session(os.path.join(model_root, self.acoustic_cfg["acoustic"]))
        self.sess_vocoder = self._make_session(os.path.join(model_root, "dsvocoder", self.vocoder_cfg["model"]))

        self.sample_rate = self.vocoder_cfg["sample_rate"]
        self.hop_size = self.vocoder_cfg["hop_size"]

    def _make_session(self, path):
        return ort.InferenceSession(path, providers=["CPUExecutionProvider"])

    def check(self, words, gl):
        """check: dur + pitch forward (deterministic)."""
        ph_dur = self._dur(words)
        pitch_pred = self._pitch(words, ph_dur, gl)
        return {
            "ph_dur": ph_dur[0].tolist(),
            "pitch_pred_midi": pitch_pred[0].tolist(),  # type: ignore
            "total_frames": int(ph_dur.sum()),
        }

    def render(self, words, out_path, gl, ph_dur=None, pitch_pred=None):
        """render: full pipeline → wav.

        `ph_dur` / `pitch_pred` (lists from a prior check) skip the
        dur / pitch forwards when supplied.
        """
        # 1. dur
        if ph_dur is None:
            ph_dur = self._dur(words)
        else:
            ph_dur = np.array([ph_dur], dtype=np.int64)
        # 2. pitch
        if pitch_pred is None:
            pitch_pred = self._pitch(words, ph_dur, gl)
        else:
            pitch_pred = np.array([pitch_pred], dtype=np.float32)
        f0 = self._midi_to_f0(pitch_pred)
        total_frames = int(ph_dur.sum())
        steps = np.array(gl["steps"], dtype=np.int64)

        # 3. variance
        tokens_v, langs_v, _, _, _ = self._encode(words, self.var_phonemes, self.var_langs)
        enc_out_v, _ = self.sess_var_ling.run(
            ["encoder_out", "x_masks"],
            {"tokens": tokens_v, "languages": langs_v, "ph_dur": ph_dur},
        )
        breathiness_pred, voicing_pred = self.sess_var.run(
            ["breathiness_pred", "voicing_pred"],
            {
                "encoder_out": enc_out_v,
                "ph_dur": ph_dur,
                "pitch": pitch_pred,
                "breathiness": np.zeros((1, total_frames), dtype=np.float32),
                "voicing": np.zeros((1, total_frames), dtype=np.float32),
                "retake": np.ones((1, total_frames, 2), dtype=bool),
                "steps": steps,
            },
        )

        # 4. acoustic
        tokens_a, langs_a, _, _, _ = self._encode(words, self.acoustic_phonemes, self.acoustic_langs)
        gender = np.full((1, total_frames), gl["gender"], dtype=np.float32)
        velocity = np.full((1, total_frames), gl["velocity"], dtype=np.float32)
        depth = np.array(gl["depth"], dtype=np.float32)
        # f0 here, not MIDI
        mel = self.sess_acoustic.run(
            ["mel"],
            {
                "tokens": tokens_a,
                "languages": langs_a,
                "durations": ph_dur,
                "f0": f0,
                "breathiness": breathiness_pred,
                "voicing": voicing_pred,
                "gender": gender,
                "velocity": velocity,
                "depth": depth,
                "steps": steps,
            },
        )[0]

        # 5. vocoder
        waveform = self.sess_vocoder.run(["waveform"], {"mel": mel, "f0": f0})[0]

        os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
        sf.write(out_path, waveform[0], self.sample_rate)  # type: ignore

        return {
            "path": out_path,
            "total_frames": total_frames,
            "duration_sec": total_frames * self.hop_size / self.sample_rate,
            "sample_rate": self.sample_rate,
        }

    # ------------------------------------------------------------------
    # shared forward passes
    # ------------------------------------------------------------------

    def _dur(self, words):
        tokens_d, langs_d, word_div, word_dur, ph_midi = self._encode(words, self.dur_phonemes, self.dur_langs)
        enc_out, x_masks = self.sess_dur_ling.run(
            ["encoder_out", "x_masks"],
            {"tokens": tokens_d, "languages": langs_d, "word_div": word_div, "word_dur": word_dur},
        )
        ph_dur_pred = self.sess_dur.run(
            ["ph_dur_pred"], {"encoder_out": enc_out, "x_masks": x_masks, "ph_midi": ph_midi}
        )[0]
        return np.round(ph_dur_pred).astype(np.int64)  # type: ignore

    def _pitch(self, words, ph_dur, gl):
        tokens_p, langs_p, _, _, _ = self._encode(words, self.pitch_phonemes, self.pitch_langs)
        enc_out_p, _ = self.sess_pitch_ling.run(
            ["encoder_out", "x_masks"],
            {"tokens": tokens_p, "languages": langs_p, "ph_dur": ph_dur},
        )
        total_frames = int(ph_dur.sum())
        note_midi = np.array([[w[2] for w in words for _ in w[0]]], dtype=np.float32)
        note_rest = np.zeros_like(note_midi, dtype=bool)
        pitch_in = np.zeros((1, total_frames), dtype=np.float32)
        expr = np.ones((1, total_frames), dtype=np.float32)
        retake = np.ones((1, total_frames), dtype=bool)
        steps = np.array(gl["steps"], dtype=np.int64)

        return self.sess_pitch.run(
            ["pitch_pred"],
            {
                "encoder_out": enc_out_p,
                "ph_dur": ph_dur,
                "note_midi": note_midi,
                "note_rest": note_rest,
                "note_dur": ph_dur,
                "pitch": pitch_in,
                "expr": expr,
                "retake": retake,
                "steps": steps,
            },
        )[0]

    def _encode(self, words, phoneme_dict, lang_dict):
        """Encode [[phonemes, dur_sec, midi], ...] into model inputs."""
        all_langs, all_toks, all_midis = [], [], []
        word_div, word_dur = [], []
        for phonemes, dur_sec, midi in words:
            ph_count = len(phonemes)
            word_div.append(ph_count)
            word_dur.append(int(round(dur_sec * self.sample_rate / self.hop_size)))
            for lang, ph in phonemes:
                all_langs.append(lang_dict[lang])
                all_toks.append(phoneme_dict[f"{lang}/{ph}"])
                all_midis.append(midi)

        return (
            np.array([all_toks], dtype=np.int64),
            np.array([all_langs], dtype=np.int64),
            np.array([word_div], dtype=np.int64),
            np.array([word_dur], dtype=np.int64),
            np.array([all_midis], dtype=np.int64),
        )

    def _midi_to_f0(self, midi):
        midi = np.asarray(midi)
        f0 = 440.0 * np.power(2.0, (midi - 69.0) / 12.0)
        f0[midi < 0] = 0.0
        return f0


# ----------------------------------------------------------------------
# NDJSON loop
# ----------------------------------------------------------------------


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def dispatch(engine, req):
    action = req.get("action")
    gl = {**DEFAULT_GLOBALS, **(req.get("globals") or {})}
    gl["steps"] = int(gl["steps"])

    if action == "check":
        return engine.check(req["words"], gl)
    if action == "render":
        return engine.render(
            req["words"],
            req["out_path"],
            gl,
            ph_dur=req.get("ph_dur"),
            pitch_pred=req.get("pitch_pred_midi"),
        )
    raise ValueError(f"unknown action: {action}")


def main():
    if len(sys.argv) < 2:
        print("usage: ds_worker.py <voicebank_root>", file=sys.stderr)
        sys.exit(2)

    engine = DiffSingerEngine(sys.argv[1])
    emit({"ready": True, "sample_rate": engine.sample_rate, "hop_size": engine.hop_size})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        req_id = None
        try:
            req = json.loads(line)
            req_id = req.get("id")
            emit({"id": req_id, "ok": True, "result": dispatch(engine, req)})
        except Exception as e:
            emit({"id": req_id, "ok": False, "error": f"{type(e).__name__}: {e}"})


if __name__ == "__main__":
    main()
