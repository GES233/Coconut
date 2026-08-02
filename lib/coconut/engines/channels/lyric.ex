defmodule Coconut.Engines.Channels.Lyric do
  @moduledoc """
  Built-in channel guarding element content (lyric and friends).

  The base slice is the current element data, fetched from
  `ws.side.elements_by_id` by the anchor's first Ordinal ref; the payload
  folds to the conventional `{:port, :synth, :lyric}` port. Callers wiring a
  different port can pass an ad-hoc spec map (or their own module) instead.
  """

  @behaviour Coconut.Channel

  alias Coconut.Patch

  @impl true
  def projection(%Coconut.Workspace{} = ws, %Patch{} = patch) do
    case patch.anchor do
      %Tamale.Anchor.Ordinal{refs: [id | _]} -> Map.fetch(ws.side.elements_by_id, id)
      _other -> {:error, :unsupported_anchor}
    end
  end

  @impl true
  def target, do: {:port, :synth, :lyric}
end
