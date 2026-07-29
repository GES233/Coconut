defmodule Coconut.Curve.Adapter.CatmullRom do
  @moduledoc "Catmull-Rom curve adapter (naive implementation)."

  alias Coconut.Curve.ControlPoint

  @type t :: %__MODULE__{
          points: [ControlPoint.t()],
          tension: float()
        }
  use Coconut.Curve.Adapter, keys: [points: [], tension: 0.5]

  @impl Coconut.Curve.Adapter
  def control_points(%__MODULE__{points: points}), do: points

  @impl Coconut.Curve.Adapter
  def span(%__MODULE__{points: []}), do: 0
  def span(%__MODULE__{points: points}), do: List.last(points).tick

  @impl Coconut.Curve.Adapter
  def rasterize(%__MODULE__{points: points, tension: tension}, tick_seq) do
    points = Enum.sort_by(points, & &1.tick)

    cond do
      points == [] ->
        for _ <- tick_seq, into: <<>>, do: <<0.0::float-32-native>>

      length(points) == 1 ->
        val = hd(points).value
        for _ <- tick_seq, into: <<>>, do: <<val::float-32-native>>

      true ->
        catmull_rasterize(points, tension, tick_seq)
    end
  end

  # ---- helpers ----

  defp catmull_rasterize(points, tension, tick_seq) do
    first_tick = hd(points).tick
    last_tick = List.last(points).tick
    padded = boundary_pad(points)

    for tick <- tick_seq, into: <<>> do
      value = sample_at(padded, tension, first_tick, last_tick, tick)
      <<value::float-32-native>>
    end
  end

  # Boundary padding: duplicate the first and last control points so the first
  # and last segments also have a full P0-P3 set.
  defp boundary_pad([p | _] = points) do
    last = List.last(points)
    [p | points] ++ [last]
  end

  # Sample at specific tick
  defp sample_at(points, tension, first_tick, last_tick, tick) do
    cond do
      tick <= first_tick -> hd(points).value
      tick >= last_tick -> List.last(points).value
      true -> interpolate_segment(points, tension, tick)
    end
  end

  # Finds the segment [P_i, P_{i+1}] containing the tick and performs Catmull-Rom interpolation.
  defp interpolate_segment([p0, p1, p2, p3 | _], tension, tick)
       when tick >= p1.tick and tick <= p2.tick do
    span = p2.tick - p1.tick
    t = if span == 0, do: 0.0, else: (tick - p1.tick) / span
    catmull_rom(p0.value, p1.value, p2.value, p3.value, t, tension)
  end

  defp interpolate_segment([_ | rest], tension, tick) do
    interpolate_segment(rest, tension, tick)
  end

  # Catmull-Rom interpolation (with tension).
  # Uses Hermite basis: compute tangents first, then perform cubic Hermite interpolation.
  # m_i = (1 - τ) * (P_{i+1} - P_{i-1}) / 2  (uniform parameterization)
  defp catmull_rom(p0, p1, p2, p3, t, tension) do
    m1 = (1.0 - tension) * (p2 - p0) / 2.0
    m2 = (1.0 - tension) * (p3 - p1) / 2.0

    t2 = t * t
    t3 = t2 * t

    h00 = 2.0 * t3 - 3.0 * t2 + 1.0
    h10 = t3 - 2.0 * t2 + t
    h01 = -2.0 * t3 + 3.0 * t2
    h11 = t3 - t2

    h00 * p1 + h10 * m1 + h01 * p2 + h11 * m2
  end
end
