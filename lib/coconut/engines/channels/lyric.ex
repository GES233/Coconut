defmodule Coconut.Engines.Channels.Lyric do
  @moduledoc """
  Built-in channel guarding element content (lyric and friends).

  The base slice is the current element's canonical projection: notes are
  fetched from `ws.side.elements_by_id` by the anchor's first Ordinal ref
  and reduced via `Coconut.Score.Note.to_canonical/1` (digests reject
  structs). The payload folds to the conventional `{:port, :synth, :lyric}`
  port. Callers wiring a different port can pass an ad-hoc spec map (or
  their own module) instead.
  """

  @behaviour Coconut.Channel

  alias Coconut.{Patch, Score.Note}

  @impl true
  def projection(%Coconut.Workspace{} = ws, %Patch{} = patch) do
    case patch.anchor do
      %Tamale.Anchor.Ordinal{refs: [id | _]} ->
        with {:ok, element} <- Map.fetch(ws.side.elements_by_id, id) do
          {:ok, canonicalize(element)}
        end

      _other ->
        {:error, :unsupported_anchor}
    end
  end

  @impl true
  def target, do: {:port, :synth, :lyric}

  defp canonicalize(%Note{} = note), do: Note.to_canonical(note)
  defp canonicalize(element), do: element
end
