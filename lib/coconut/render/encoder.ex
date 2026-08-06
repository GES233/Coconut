defmodule Coconut.Render.Encoder do
  @moduledoc """
  Encoder contract: note sequence → engine request tokens.

  The bridge from score to engine request. The contract is owned by
  coconut; concrete encoders are implemented by engine/voicebank
  developers and referenced from the engine adapter's `:encoder` config
  (manual for v1 — voicebank-derived auto-selection waits for the
  voicebank declaration layer).

  The contract fixes **only the invocation discipline**, not the data:

  - output is opaque: `%{note_id => term()}` — the token shape is defined
    by the consuming engine adapter (DiffSinger wants `[[lang, ph]]`
    phoneme pairs; another engine may want CV aliases, syllable trees, or
    raw lyrics for engine-side G2P);
  - the callback is **phrase-granular**, never per-note: melisma (one
    syllable spanning several notes) and context-dependent readings need
    the whole phrase;
  - the adapter invokes the encoder **once per track** with that track's
    full note sequence in score order — phrase context lives within a
    track, so tracks never mix;
  - notes the adapter already considers resolved (e.g. carrying explicit
    tokens) are included as context, but only unresolved notes consume
    the result; coverage gaps fail assembly as `{:encoder_incomplete, ids}`.

  Results are computed on the fly at check/render time — an edit
  re-derives tokens automatically. Caching is a later concern.
  """

  @typedoc "One note as the adapter assembled it: `{id, note, {start_tick, end_tick}}`."
  @type note ::
          {Tamale.id(), data :: Coconut.Score.Note.t(),
           span :: {non_neg_integer(), non_neg_integer()}}

  @callback encode(notes :: [note()], config :: term()) ::
              {:ok, %{Tamale.id() => term()}} | {:error, term()}
end
