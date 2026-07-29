defmodule Coconut.Curve.Adapter.Bezier do
  @moduledoc """
  Cubic Bezier curve adapter.

  Each `ControlPoint` may carry optional `handle_left` / `handle_right`
  fields which are relative offsets from the anchor (e.g. `%{tick: 50, value: 0.2}`).
  When `nil`, the 1/3 rule auto-computes a horizontal handle.

  Rasterization uses binary bisection on the parameter `t` (40 iterations) to invert
  the x(t) cubic, then evaluates y(t).
  """

  alias Coconut.Curve.ControlPoint

  @type t :: %__MODULE__{points: [ControlPoint.t()]}

  use Coconut.Curve.Adapter, keys: [points: []]

  @impl Coconut.Curve.Adapter
  def control_points(%__MODULE__{points: pts}), do: pts

  @impl Coconut.Curve.Adapter
  def span(%__MODULE__{points: []}), do: 0
  def span(%__MODULE__{points: pts}), do: List.last(pts).tick

  # ---- rasterize ----

  @impl Coconut.Curve.Adapter
  def rasterize(%__MODULE__{points: []}, tick_seq) do
    for _ <- tick_seq, into: <<>>, do: <<0.0::float-32-native>>
  end

  def rasterize(%__MODULE__{points: [single]}, tick_seq) do
    v = single.value
    for _ <- tick_seq, into: <<>>, do: <<v::float-32-native>>
  end

  def rasterize(%__MODULE__{points: points}, tick_seq) do
    points = Enum.sort_by(points, & &1.tick)
    first_tick = hd(points).tick
    last_tick = List.last(points).tick
    segs = build_segments(points)

    for tick <- tick_seq, into: <<>> do
      v = sample(segs, first_tick, last_tick, tick)
      <<v::float-32-native>>
    end
  end

  # ---- segment construction ----
  # Segment: {{x0,y0}, {cx1,cy1}, {cx2,cy2}, {x1,y1}}

  defp build_segments([p | rest]), do: build_segments(rest, p, [])
  defp build_segments([], _prev, acc), do: Enum.reverse(acc)

  defp build_segments([p1 | rest], p0, acc) do
    dx = p1.tick - p0.tick
    dx3 = if dx > 0, do: div(dx, 3), else: 0

    cp1 = resolve_handle(p0, :right, dx3)
    cp2 = resolve_handle(p1, :left, -dx3)

    seg = {
      {p0.tick, p0.value},
      {p0.tick + cp1.tick, p0.value + cp1.value},
      {p1.tick + cp2.tick, p1.value + cp2.value},
      {p1.tick, p1.value}
    }

    build_segments(rest, p1, [seg | acc])
  end

  defp resolve_handle(pt, side, default_tick) do
    h =
      case side do
        :right -> pt.handle_right
        :left -> pt.handle_left
      end

    case h do
      nil -> %{tick: default_tick, value: 0.0}
      %{tick: t, value: v} -> %{tick: t, value: v}
    end
  end

  # ---- sampling ----

  defp sample([first_seg | _rest], first_tick, _last_tick, tick)
       when tick <= first_tick do
    {{_, y0}, _, _, _} = first_seg
    y0
  end

  defp sample(segs, _first_tick, last_tick, tick) when tick >= last_tick do
    {_, _, _, {_, y1}} = List.last(segs)
    y1
  end

  defp sample(segs, _ft, _lt, tick) do
    seg =
      Enum.find(segs, fn {{x0, _}, _, _, {x1, _}} ->
        tick >= x0 and tick <= x1
      end)

    case seg do
      nil ->
        {_, _, _, {_, y1}} = List.last(segs)
        y1

      {{x0, _}, _, _, {x1, _}} when x0 == x1 ->
        {{_, y0}, _, _, _} = seg
        y0

      _ ->
        bisect_and_eval(seg, tick)
    end
  end

  # ---- bisection ----

  defp bisect_and_eval({p0, p1, p2, p3}, target_x) do
    {x0, _} = p0
    {cx1, _} = p1
    {cx2, _} = p2
    {x1, _} = p3

    t = bisect_t(x0, cx1, cx2, x1, target_x, 0.0, 1.0, 40)

    {_, y0} = p0
    {_, cy1} = p1
    {_, cy2} = p2
    {_, y1} = p3
    cubic1d(y0, cy1, cy2, y1, t)
  end

  defp bisect_t(_x0, _cx1, _cx2, _x1, _target, lo, hi, 0), do: (lo + hi) / 2.0

  defp bisect_t(x0, cx1, cx2, x1, target, lo, hi, n) do
    t = (lo + hi) / 2.0
    bx = cubic1d(x0, cx1, cx2, x1, t)

    if bx > target do
      bisect_t(x0, cx1, cx2, x1, target, lo, t, n - 1)
    else
      bisect_t(x0, cx1, cx2, x1, target, t, hi, n - 1)
    end
  end

  # ---- cubic polynomial ----

  @compile {:inline, cubic1d: 5}
  defp cubic1d(p0, p1, p2, p3, t) do
    u = 1.0 - t
    u2 = u * u
    t2 = t * t
    u3 = u2 * u
    t3 = t2 * t
    u3 * p0 + 3.0 * u2 * t * p1 + 3.0 * u * t2 * p2 + t3 * p3
  end
end
