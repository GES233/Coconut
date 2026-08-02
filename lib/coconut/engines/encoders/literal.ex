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

  @behaviour Coconut.Encoder

  @impl true
  def encode(notes, config) do
    default_lang = Map.get(config || %{}, :lang, "zh")

    Enum.reduce_while(notes, {:ok, %{}}, fn {id, data, _span}, {:ok, acc} ->
      case data.lyric do
        lyric when is_binary(lyric) ->
          case String.split(lyric) do
            [] ->
              {:halt, {:error, {:empty_lyric, id}}}

            parts ->
              lang = Map.get(data.metadata, "lang", default_lang)
              {:cont, {:ok, Map.put(acc, id, Enum.map(parts, &[lang, &1]))}}
          end

        _other ->
          {:halt, {:error, {:missing_lyric, id}}}
      end
    end)
  end
end
