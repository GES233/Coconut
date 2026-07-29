defmodule Coconut.Score.Grid do
  @moduledoc """
  Timeline grid and quantization utilities. Snaps a free tick to the nearest grid line.

  This module is illustrative — grid logic typically belongs to the editor / UI layer.
  """

  alias Coconut.Score.Tick

  @type grid_type ::
          :quarter
          | :eighth
          | :sixteenth
          | {:triplet, 4}
          | {:triplet, 8}
          | :none

  @type grid_strategy :: :nearest | :floor | :ceil

  @doc "Snaps `raw_tick` to the nearest position on the given `grid_type`."
  @spec snap_tick(Tick.numeric_tick(), grid_type(), grid_strategy(), pos_integer()) ::
          Tick.numeric_tick()
  def snap_tick(raw_tick, grid_type, strategy \\ :nearest, tpqn \\ 480)

  def snap_tick(raw_tick, :none, _strategy, _tpqn), do: raw_tick

  def snap_tick(raw_tick, grid_type, strategy, tpqn) when raw_tick >= 0 do
    step = ticks_per_step(grid_type, tpqn)

    case strategy do
      :nearest ->
        round(raw_tick / step) * step

      :floor ->
        div(raw_tick, step) * step

      :ceil ->
        rem = rem(raw_tick, step)
        if rem == 0, do: raw_tick, else: raw_tick + step - rem
    end
  end

  @doc "Returns the number of ticks spanned by a single grid step."
  @spec ticks_per_step(grid_type(), pos_integer()) :: pos_integer()
  def ticks_per_step(:quarter, tpqn), do: tpqn
  def ticks_per_step(:eighth, tpqn), do: div(tpqn, 2)
  def ticks_per_step(:sixteenth, tpqn), do: div(tpqn, 4)
  def ticks_per_step({:triplet, 4}, tpqn), do: div(tpqn * 2, 3)
  def ticks_per_step({:triplet, 8}, tpqn), do: div(tpqn, 3)

  @doc "Snaps a tick relative to an original position, preserving the note's snapped absolute length."
  @spec snap_tick_relative(Tick.numeric_tick(), Tick.numeric_tick(), grid_type(), pos_integer()) ::
          Tick.numeric_tick()
  def snap_tick_relative(raw_tick, original_tick, grid_type, tpqn \\ 480) do
    step = ticks_per_step(grid_type, tpqn)
    delta_tick = raw_tick - original_tick
    snapped_delta = round(delta_tick / step) * step
    original_tick + snapped_delta
  end
end
