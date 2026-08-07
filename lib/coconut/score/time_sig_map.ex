defmodule Coconut.Score.TimeSigMap do
  @moduledoc """
  Compiled time signature map from time signature change events.

  Delegates to `RecordMap` for compilation and bar-based binary search.
  The compiled value carries its `tpqn`, so query functions take no
  resolution argument — compile-time and query-time can never disagree.
  """

  alias Coconut.Score.{Record, RecordMap, Tick, TimeSig}
  import Tick

  @type compiled_event :: %{
          start_pos: Record.position(),
          end_pos: Record.end_position(),
          start_bar: pos_integer(),
          start_tick: Tick.numeric_tick(),
          end_tick: Tick.t(),
          time_sig: TimeSig.t()
        }
  @type t :: %__MODULE__{segments: tuple(), tpqn: pos_integer()}

  defstruct [:segments, :tpqn]

  @spec compile(TimeSig.time_sig_events(), keyword()) :: {:ok, t()} | {:error, term()}
  def compile(events, opts \\ [])

  def compile([], _opts), do: {:error, :empty_time_sig_events}
  def compile({[], _last_bar}, _opts), do: {:error, :empty_time_sig_events}
  def compile([_ | _] = events, opts), do: compile({events, Record.open_end()}, opts)

  def compile({events, end_bar}, opts) do
    tpqn = Keyword.get(opts, :tpqn, 480)

    with {:ok, record_events} <- normalize_bar_events(events),
         {:ok, record_end} <- normalize_end_bar(end_bar) do
      reducer = &build_segment(&1, &2, &3, &4, tpqn)

      case RecordMap.compile({record_events, record_end}, reducer, 0) do
        {:ok, tuple} -> {:ok, %__MODULE__{segments: tuple, tpqn: tpqn}}
        {:error, reason} -> translate_compile_error(reason)
      end
    end
  end

  defp build_segment(start_pos, end_pos, time_sig, current_tick, tpqn) do
    build_segment_by_end(
      TimeSig.ticks_per_bar(time_sig, tpqn),
      start_pos,
      end_pos,
      time_sig,
      current_tick
    )
  end

  defp build_segment_by_end(nil, start_pos, end_pos, time_sig, current_tick) do
    {:ok,
     %{
       start_pos: start_pos,
       end_pos: end_pos,
       start_bar: start_pos + 1,
       start_tick: current_tick,
       end_tick: Tick.get_dynamic_tick(),
       time_sig: time_sig
     }, current_tick}
  end

  defp build_segment_by_end(tpb, start_pos, end_pos, time_sig, current_tick)
       when is_integer(tpb) and is_integer(end_pos) do
    num_bars = end_pos - start_pos
    end_tick = current_tick + tpb * num_bars

    {:ok,
     %{
       start_pos: start_pos,
       end_pos: end_pos,
       start_bar: start_pos + 1,
       start_tick: current_tick,
       end_tick: end_tick,
       time_sig: time_sig
     }, end_tick}
  end

  defp build_segment_by_end(tpb, start_pos, :open_end, time_sig, current_tick)
       when is_integer(tpb) do
    {:ok,
     %{
       start_pos: start_pos,
       end_pos: :open_end,
       start_bar: start_pos + 1,
       start_tick: current_tick,
       end_tick: Tick.get_dynamic_tick(),
       time_sig: time_sig
     }, current_tick}
  end

  defp translate_compile_error({:first_record_must_start_at_zero, pos}),
    do: {:error, {:first_time_sig_event_must_start_at_one, pos}}

  defp translate_compile_error({:invalid_record_position, bad}),
    do: {:error, {:invalid_time_sig_event_position, bad}}

  defp translate_compile_error(:duplicate_record_positions),
    do: {:error, :duplicate_time_sig_events}

  defp translate_compile_error(reason), do: {:error, reason}

  @spec bar_to_tick(t(), TimeSig.bar()) ::
          {:ok, Tick.numeric_tick()} | {:error, term()}
  def bar_to_tick(%__MODULE__{segments: segments, tpqn: tpqn}, target_bar) when target_bar >= 1 do
    pos = target_bar - 1
    seg = RecordMap.find_by_position(segments, pos)

    case TimeSig.ticks_per_bar(seg.time_sig, tpqn) do
      nil ->
        {:error, {:free_meter_at_bar, target_bar}}

      tpb ->
        bars_offset = pos - seg.start_pos
        {:ok, seg.start_tick + tpb * bars_offset}
    end
  end

  def bar_to_tick(_compiled, bad_bar), do: {:error, {:invalid_bar, bad_bar}}

  @spec tick_to_bar(t(), Tick.numeric_tick()) ::
          {:ok, TimeSig.bar()} | {:error, term()}
  def tick_to_bar(%__MODULE__{segments: segments, tpqn: tpqn}, target_tick)
      when is_numeric_tick(target_tick) do
    seg = find_by_tick(segments, target_tick)

    case TimeSig.ticks_per_bar(seg.time_sig, tpqn) do
      nil ->
        {:error, {:free_meter_at_tick, target_tick}}

      tpb ->
        tick_offset = target_tick - seg.start_tick
        bar_offset = div(tick_offset, tpb)
        {:ok, seg.start_bar + bar_offset}
    end
  end

  def tick_to_bar(_compiled, bad_tick), do: {:error, {:invalid_tick, bad_tick}}

  defp find_by_tick(tuple, target_tick, low, high) when low <= high do
    mid = div(low + high, 2)
    seg = elem(tuple, mid)

    cond do
      target_tick < seg.start_tick ->
        find_by_tick(tuple, target_tick, low, mid - 1)

      is_numeric_tick(seg.end_tick) and target_tick >= seg.end_tick ->
        find_by_tick(tuple, target_tick, mid + 1, high)

      true ->
        seg
    end
  end

  defp find_by_tick(tuple, _target_tick, _low, _high), do: elem(tuple, tuple_size(tuple) - 1)

  defp find_by_tick(tuple, target_tick),
    do: find_by_tick(tuple, target_tick, 0, tuple_size(tuple) - 1)

  defp normalize_bar_events(events) do
    normalized =
      Enum.map(events, fn
        {bar, time_sig} when is_integer(bar) and bar >= 1 -> {bar - 1, time_sig}
        bad -> bad
      end)

    {:ok, normalized}
  end

  defp normalize_end_bar(:open_end), do: {:ok, Record.open_end()}

  defp normalize_end_bar(end_bar) when is_integer(end_bar) and end_bar >= 1,
    do: {:ok, end_bar - 1}

  defp normalize_end_bar(bad), do: {:error, {:invalid_end_bar, bad}}
end
