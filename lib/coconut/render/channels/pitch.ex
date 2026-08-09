defmodule Coconut.Render.Channels.Pitch do
  @moduledoc """
  Built-in channel for per-note pitch-curve overrides.

  Payload contract: `[[tick, midi], ...]` — a sparse piecewise-linear curve
  in absolute ticks. The base slice is the current element data (same as
  `Coconut.Render.Channels.Lyric`): the digest guards the note the curve edits.

  Folds to `{:port, note_id, :pitch}` — the note id taken from the anchor's
  first Ordinal ref — so simultaneous overrides on different notes coexist
  instead of clobbering one shared port. The engine adapter (e.g.
  `CoconutDiffsinger` in the sibling `coconut_diffsinger` package) samples
  the curve onto the engine's frame grid.
  """

  @behaviour Coconut.Render.Channel

  alias Coconut.Edit.Patch
  alias Coconut.Render.Channels.Lyric

  @impl true
  def projection(ws, patch), do: Lyric.projection(ws, patch)

  @impl true
  def target(%Patch{anchor: %Tamale.Anchor.Ordinal{refs: [id | _]}}), do: {:port, id, :pitch}
  def target(_patch), do: {:port, :synth, :pitch}
end
