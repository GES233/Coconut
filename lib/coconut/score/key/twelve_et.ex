defmodule Coconut.Score.Key.TwelveET do
  @moduledoc """
  12-tone equal temperament pitch adapter.

  内部继续接受 MIDI number，以兼容钢琴卷帘和引擎 API；整数值 float 会
  归一成 integer。canonical/Pickle 边界把非整数值编码成规范化十进制
  字符串，因此不会把 float 送进 Tamale digest。

  更一般的微分音或非十二平均律应实现新的 `Coconut.Score.Key` adapter，
  用整数分子/分母或音律步级保存精确音高；`to_midi/1` 只负责在引擎边界
  生成近似 float。
  """

  use Coconut.Score.Key

  defstruct [:midi]

  # ---- Key behaviour ----

  @impl true
  def new(midi) when is_number(midi), do: {:ok, %__MODULE__{midi: normalize_midi(midi)}}
  def new(midi), do: {:error, {:invalid_midi, midi}}

  @impl true
  def from_midi(midi, _ctx), do: new(midi)

  @impl true
  def to_canonical(%__MODULE__{midi: midi}), do: %{midi: exact_midi(midi)}

  @impl true
  def dump(%__MODULE__{} = key), do: {:ok, to_canonical(key)}

  @impl true
  def load(%{midi: midi} = data) when map_size(data) == 1 do
    load_midi(midi)
  end

  def load(data), do: {:error, {:invalid_twelve_et_dump, data}}

  # ---- Inner protocol implementation ----

  defimpl Inner, for: __MODULE__ do
    def to_midi(%{midi: midi}), do: midi * 1.0

    def to_frequency(%{midi: midi}, reference), do: reference * :math.pow(2, (midi - 69) / 12)

    def to_score(_key, _type, _ctx), do: {:error, :not_implemented}
  end

  defp load_midi(midi) when is_number(midi), do: new(midi)

  defp load_midi(midi) when is_binary(midi) do
    case Float.parse(midi) do
      {value, ""} -> new(value)
      _other -> {:error, {:invalid_midi, midi}}
    end
  end

  defp load_midi(midi), do: {:error, {:invalid_midi, midi}}

  defp exact_midi(midi) do
    case normalize_midi(midi) do
      integer when is_integer(integer) -> integer
      fractional -> :erlang.float_to_binary(fractional, [:short])
    end
  end

  defp normalize_midi(midi) when is_float(midi) do
    integer = trunc(midi)
    if midi == integer, do: integer, else: midi
  end

  defp normalize_midi(midi), do: midi
end
