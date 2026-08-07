defmodule Coconut.Engines.Encoders.Literal do
  @moduledoc """
  Literal encoder: the lyric *is* the token list.

  Each note's lyric string is split on whitespace into DiffSinger-shaped
  `[lang, symbol]` pairs. The language tag is this encoder's own policy,
  not a contract requirement: a note's `:lang` data key wins, falling
  back to the configured `:lang` (default `"zh"`). Notes are handled
  independently (no context use). Useful for romanized input and tests;
  it is not a dictionary G2P.
  """

  @behaviour Coconut.Render.Encoder

  @impl true
  def encode(notes, config) do
    default_lang = Map.get(config || %{}, :lang, "zh")

    Enum.reduce_while(notes, {:ok, %{}}, fn {id, data, _span}, {:ok, acc} ->
      case encode_note(data, default_lang) do
        {:ok, phonemes} -> {:cont, {:ok, Map.put(acc, id, phonemes)}}
        {:error, reason} -> {:halt, {:error, {reason, id}}}
      end
    end)
  end

  defp encode_note(%{lyric: lyric, metadata: metadata}, default_lang) when is_binary(lyric) do
    case String.split(lyric) do
      [] -> {:error, :empty_lyric}
      parts -> {:ok, Enum.map(parts, &[Map.get(metadata, "lang", default_lang), &1])}
    end
  end

  defp encode_note(_data, _default_lang), do: {:error, :missing_lyric}
end
