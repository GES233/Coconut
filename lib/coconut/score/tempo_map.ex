defmodule Coconut.Score.TempoMap do
  @moduledoc """
  Compiled tempo map from tempo change events.

  Delegates to `RecordMap` for compilation and tick-based binary search.
  """

  alias Coconut.{Score.Tempo, Score.Tick, Score.RecordMap, Score.Record}
  import Tick

  @type compiled_event :: %{
          start_pos: Tick.numeric_tick(),
          end_pos: Tick.t(),
          start_sec: Tempo.physical_time(),
          strategy: Tempo.Segment.segment()
        }
  @type t :: tuple()

  @spec compile(Tempo.tempo_events(), keyword()) :: {:ok, t()} | {:error, term()}
  def compile(events, opts \\ [])

  def compile([], _opts), do: {:error, :empty_tempo_events}
  def compile({[], _last_tick}, _opts), do: {:error, :empty_tempo_events}

  def compile([_ | _] = tempo_events, opts),
    do: compile({tempo_events, Tick.get_dynamic_tick()}, opts)

  def compile({tempo_events, last_tick}, opts) do
    tpqn = Keyword.get(opts, :tpqn, 480)
    record_events = {tempo_events, record_end_from_tick(last_tick)}

    reducer = fn start_tick, end_pos, event, current_sec ->
      end_tick = tick_end_from_record(end_pos)

      with {:ok, strategy} <-
             Tempo.build_segment_from_event(event.module, start_tick, end_tick, event.context) do
        duration = Tempo.duration_sec(strategy, tpqn)
        next_sec = if duration == :infinity, do: current_sec, else: current_sec + duration

        {:ok,
         %{start_pos: start_tick, end_pos: end_tick, start_sec: current_sec, strategy: strategy},
         next_sec}
      end
    end

    case RecordMap.compile(record_events, reducer, 0.0) do
      {:ok, tuple} ->
        {:ok, tempoize_tuple(tuple)}

      {:error, {:first_record_must_start_at_zero, pos}} ->
        {:error, {:first_tempo_event_must_start_at_zero, pos}}

      {:error, {:invalid_record_position, bad}} ->
        {:error, {:invalid_tempo_event_tick, bad}}

      {:error, :duplicate_record_positions} ->
        {:error, :duplicate_tempo_event_ticks}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def tick_to_sec(compiled_tuple, target_tick, tpqn) when is_numeric_tick(target_tick) do
    seg = find_by_tick(compiled_tuple, target_tick)
    seg.start_sec + Tempo.tick_to_sec(seg.strategy, target_tick - seg.start_pos, tpqn)
  end

  def sec_to_tick(compiled_tuple, target_sec, tpqn) do
    seg = find_segment_by_sec(compiled_tuple, target_sec, 0, tuple_size(compiled_tuple) - 1, tpqn)
    offset_sec = target_sec - seg.start_sec
    seg.start_pos + Tempo.sec_to_tick(seg.strategy, offset_sec, tpqn)
  end

  @spec slice(t(), Tick.numeric_tick(), Tick.numeric_tick()) :: [compiled_event()]
  def slice(compiled_tuple, start_tick, end_tick)
      when is_numeric_tick(start_tick) and is_numeric_tick(end_tick) do
    size = tuple_size(compiled_tuple)

    Enum.reduce_while(0..(size - 1), {:cont, []}, fn i, {:cont, acc} ->
      seg = elem(compiled_tuple, i)

      cond do
        is_numeric_tick(seg.start_pos) and seg.start_pos >= end_tick -> {:halt, {:done, acc}}
        is_numeric_tick(seg.end_pos) and seg.end_pos <= start_tick -> {:cont, {:cont, acc}}
        true -> {:cont, {:cont, [seg | acc]}}
      end
    end)
    |> case do
      {:done, acc} -> Enum.reverse(acc)
      {:cont, acc} -> Enum.reverse(acc)
    end
  end

  defp find_by_tick(tuple, target_tick),
    do: find_by_tick(tuple, target_tick, 0, tuple_size(tuple) - 1)

  defp find_by_tick(tuple, target_tick, low, high) when low <= high do
    mid = div(low + high, 2)
    seg = elem(tuple, mid)

    cond do
      target_tick < seg.start_pos ->
        find_by_tick(tuple, target_tick, low, mid - 1)

      is_numeric_tick(seg.end_pos) and target_tick >= seg.end_pos ->
        find_by_tick(tuple, target_tick, mid + 1, high)

      true ->
        seg
    end
  end

  defp find_by_tick(tuple, _target_tick, _low, _high), do: elem(tuple, tuple_size(tuple) - 1)

  defp find_segment_by_sec(tuple, target_sec, low, high, tpqn) when low <= high do
    mid = div(low + high, 2)
    seg = elem(tuple, mid)
    duration = Tempo.duration_sec(seg.strategy, tpqn)

    cond do
      target_sec < seg.start_sec ->
        find_segment_by_sec(tuple, target_sec, low, mid - 1, tpqn)

      duration != :infinity and target_sec >= seg.start_sec + duration ->
        find_segment_by_sec(tuple, target_sec, mid + 1, high, tpqn)

      true ->
        seg
    end
  end

  defp find_segment_by_sec(tuple, _target_sec, _low, _high, _tpqn),
    do: elem(tuple, tuple_size(tuple) - 1)

  defp record_end_from_tick(:dynamic_tick), do: Record.open_end()
  defp record_end_from_tick(tick) when is_integer(tick) and tick >= 0, do: tick
  defp tick_end_from_record(:open_end), do: Tick.get_dynamic_tick()
  defp tick_end_from_record(pos) when is_integer(pos) and pos >= 0, do: pos

  defp tempoize_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&tempoize_segment/1) |> List.to_tuple()

  defp tempoize_segment(%{end_pos: :open_end} = seg),
    do: %{seg | end_pos: Tick.get_dynamic_tick()}

  defp tempoize_segment(seg), do: seg
end
