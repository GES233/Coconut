defmodule Coconut.Engines.DiffSinger.Encoder do
  @moduledoc """
  Worker-backed encoder: lyric → phonemes through the voicebank's own
  `dsdict-<lang>.yaml` dictionaries (hanzi goes through pypinyin first).

  Talks to the same persistent worker as check/render — the ONNX
  voicebank is loaded once and shared. Notes carry a `:lyric` string and
  an optional `:lang` (default `"zh"`); a note's lyric is a
  whitespace-separated sequence of hanzi words or ascii syllables.

  The adapter passes its full config down, so `:voicebank_root` /
  `:python` / `:worker` / `:client` all apply here unchanged.
  """

  @behaviour Coconut.Render.Encoder

  alias Coconut.Engines.DiffSinger.PortClient

  @impl true
  def encode(notes, config) do
    payload = %{
      action: "encode",
      notes:
        Enum.map(notes, fn {id, data, _span} ->
          %{id: id, lyric: data.lyric, lang: Map.get(data.metadata, "lang", "zh")}
        end)
    }

    client = Map.get(config, :client, PortClient)

    case client.call(payload, config) do
      {:ok, %{"tokens" => tokens}} -> {:ok, tokens}
      {:error, _} = error -> error
    end
  end
end
