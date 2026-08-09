defmodule Coconut.Render.Channels.Duration do
  @moduledoc """
  Built-in channel for per-phoneme duration overrides within a note.

  Payload contract: `[[ph_index, dur_tick], ...]` — sparse pins into the
  note's phoneme list, durations in ticks. Unpinned phonemes absorb the
  slack proportionally: the note's total stays on the score grid (the
  engine worker renormalizes every word to its span-derived target).

  The base slice is the current element data (same as
  `Coconut.Render.Channels.Lyric`): the digest guards the note being retimed.
  Folds to `{:port, note_id, :duration}`.
  """

  @behaviour Coconut.Render.Channel

  alias Coconut.Edit.Patch
  alias Coconut.Render.Channels.Lyric

  @impl true
  def projection(ws, patch), do: Lyric.projection(ws, patch)

  @impl true
  def target(%Patch{anchor: %Tamale.Anchor.Ordinal{refs: [id | _]}}),
    do: {:port, id, :duration}

  def target(_patch), do: {:port, :synth, :duration}
end
