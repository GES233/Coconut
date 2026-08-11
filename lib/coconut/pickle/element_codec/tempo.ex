defmodule Coconut.Pickle.ElementCodec.Tempo do
  @moduledoc """
  `Coconut.Edit.Track.Tempo` 的元素 codec。

  元素是 `%{bpm: 整数 milli-bpm}` 裸 map，dump 校验形状后原样透传，load 同。
  """

  @behaviour Coconut.Pickle.ElementCodec

  @impl true
  def dump_element(%{bpm: bpm} = element) when is_integer(bpm), do: {:ok, element}

  def dump_element(other), do: {:error, {:invalid_tempo_element, other}}

  @impl true
  def load_element(%{bpm: bpm} = dumped) when is_integer(bpm), do: {:ok, dumped}

  def load_element(other), do: {:error, {:invalid_tempo_element_dump, other}}
end
