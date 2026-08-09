defmodule Coconut.Score.TimeSig do
  @moduledoc "Domain model for time signature."

  alias Coconut.Score.Record

  @type tpqn :: pos_integer()

  # Simple meters
  @type standard ::
          {numerator :: pos_integer(), denominator :: pos_integer()}
          | {:standard, numerator :: pos_integer(), denominator :: pos_integer()}

  # Compound meters and irregular meters
  @type compound :: {:compound, groupings :: [pos_integer()], denominator :: pos_integer()}

  # 散拍子 (free meter)
  # 其实可以当成动态拍子来做（但前面插入了音符，后面也跟着变了）
  @type free :: :san

  @typedoc "Number of bars"
  @type bar :: pos_integer()

  @typedoc "Time signature"
  @type t :: standard() | compound() | free()

  @typedoc "Event with time signature update"
  @type time_sig_event :: {bar(), t()}

  @type time_sig_events :: [time_sig_event()] | {[time_sig_event()], Record.end_position()}

  @doc "Returns the total tick length within a specific bar."
  def ticks_per_bar({num, den}, tpqn) when is_integer(num) and is_integer(den),
    do: ticks_per_bar({:standard, num, den}, tpqn)

  def ticks_per_bar({:standard, num, den}, tpqn), do: div(total_notes(num, tpqn), den)

  def ticks_per_bar({:compound, groupings, den}, tpqn),
    do: div(total_notes(Enum.sum(groupings), tpqn), den)

  def ticks_per_bar(:san, _tpqn), do: nil

  @doc """
  Validates a time signature value's shape.

  Numerator, denominator, and compound groupings must be positive integers,
  and a compound meter needs at least one grouping. Invalid values fail here
  instead of blowing up downstream in `TimeSigMap.compile/2` arithmetic.
  """
  @spec validate(term()) :: :ok | {:error, {:invalid_time_sig, term()}}
  def validate(sig)

  def validate({num, den}) when is_integer(num) and num > 0 and is_integer(den) and den > 0,
    do: :ok

  def validate({:standard, num, den})
      when is_integer(num) and num > 0 and is_integer(den) and den > 0,
      do: :ok

  def validate({:compound, [_ | _] = groupings, den}) when is_integer(den) and den > 0 do
    if Enum.all?(groupings, &(is_integer(&1) and &1 > 0)) do
      :ok
    else
      {:error, {:invalid_time_sig, {:compound, groupings, den}}}
    end
  end

  def validate(:san), do: :ok
  def validate(other), do: {:error, {:invalid_time_sig, other}}

  defp total_notes(num, tpqn), do: tpqn * 4 * num
end
