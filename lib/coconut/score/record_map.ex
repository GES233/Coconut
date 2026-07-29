defmodule Coconut.Score.RecordMap do
  @moduledoc """
  Generic Record compiler and binary search engine.

  Compiles a series of positioned Records into a left-closed, right-open interval tuple
  and provides binary search over it.

  ## Compiled events

  Each compiled event must include `start_pos` and `end_pos` fields.
  Remaining fields are freely populated by the `reducer`.

  ## Example

      # TempoMap's compile
      reducer = fn start_pos, end_pos, event, current_sec ->
        end_tick = if end_pos == Record.open_end(), do: Tick.get_dynamic_tick(), else: end_pos
        with {:ok, strategy} <- Tempo.build_segment_from_event(event.module, start_tick, end_tick, event.context) do
          duration = Tempo.duration_sec(strategy, tpqn)
          {:ok, %{start_pos: start_pos, end_pos: end_tick, start_sec: current_sec, strategy: strategy},
           current_sec + duration}
        end
      end

      RecordMap.compile(tempo_events, reducer, 0.0)
  """

  alias Coconut.Score.Record

  @typedoc """
  A compiled event.

  Must include `start_pos` and `end_pos` for binary search.
  """
  @type compiled_event :: %{
          :start_pos => Record.position(),
          :end_pos => Record.end_position(),
          optional(atom()) => term()
        }

  @type t :: tuple()

  @typedoc """
  Reducer function signature.

  Receives the interval's start position, end position, Record value, and accumulated state.
  Returns `{:ok, compiled_event, new_acc}` or `{:error, reason}`.
  """
  @type reducer :: (Record.position(), Record.end_position(), Record.value(), term() ->
                      {:ok, compiled_event(), term()} | {:error, term()})

  # ---- Compiling ----

  @doc """
  Compiles a list of Records into a binary-searchable tuple.

  Returns `{:ok, compiled_tuple}` or `{:error, reason}`.
  """
  @spec compile(Record.records(), reducer(), term()) :: {:ok, t()} | {:error, term()}
  def compile(records_arg, reducer, initial_acc)

  def compile([], _reducer, _initial_acc), do: {:error, :empty_records}
  def compile({[], _last_pos}, _reducer, _initial_acc), do: {:error, :empty_records}

  def compile(records, reducer, initial_acc) when is_list(records),
    do: compile_normalized(records, Record.open_end(), reducer, initial_acc)

  def compile({records, last_pos}, reducer, initial_acc) when is_list(records),
    do: compile_normalized(records, last_pos, reducer, initial_acc)

  def compile(bad, _reducer, _initial_acc),
    do: {:error, {:invalid_records, bad}}

  defp compile_normalized(records, last_pos, reducer, initial_acc) do
    with :ok <- end_position_valid?(last_pos),
         :ok <- all_positions_numeric?(records),
         sorted = Enum.sort_by(records, fn {pos, _v} -> pos end),
         :ok <- no_duplicate_positions?(sorted),
         :ok <- first_record_at_zero?(sorted),
         {:ok, list_map} <- do_compile(sorted, last_pos, initial_acc, reducer, []) do
      {:ok, List.to_tuple(list_map)}
    end
  end

  # ---- Binary Search ----

  @doc """
  Finds the interval containing `target_pos` in the compiled tuple.

  Intervals are left-closed, right-open `[start_pos, end_pos)`.
  When `target_pos` falls outside all intervals, returns the last interval.
  """
  @spec find_by_position(t(), Record.position()) :: compiled_event()
  def find_by_position(tuple, target_pos) do
    do_find(tuple, target_pos, 0, tuple_size(tuple) - 1)
  end

  # ---- Inner functions ----

  # The final position is valid
  defp end_position_valid?(:open_end), do: :ok
  defp end_position_valid?(pos) when is_integer(pos) and pos >= 0, do: :ok
  defp end_position_valid?(pos), do: {:error, {:invalid_record_end_position, pos}}

  # All events must start at non-negative positions
  defp all_positions_numeric?(records) do
    case Enum.find(records, fn
           {pos, _v} -> not (is_integer(pos) and pos >= 0)
           _other -> true
         end) do
      nil -> :ok
      bad -> {:error, {:invalid_record_position, bad}}
    end
  end

  # No two events at the same position
  defp no_duplicate_positions?(sorted_records) do
    has_dup? =
      sorted_records
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [{p1, _}, {p2, _}] -> p1 == p2 end)

    if has_dup?, do: {:error, :duplicate_record_positions}, else: :ok
  end

  # Validate: end positions, then body, then head
  # First event must start at 0
  defp first_record_at_zero?([]), do: {:error, :empty_records}
  defp first_record_at_zero?([{0, _} | _]), do: :ok

  defp first_record_at_zero?([{pos, _v} | _rest]),
    do: {:error, {:first_record_must_start_at_zero, pos}}

  # The interval itself is valid
  defp range_valid?(start_pos, :open_end)
       when is_integer(start_pos) and start_pos >= 0,
       do: :ok

  defp range_valid?(start_pos, end_pos)
       when is_integer(start_pos) and is_integer(end_pos) and start_pos < end_pos,
       do: :ok

  defp range_valid?(start_pos, end_pos),
    do: {:error, {:invalid_record_range, start_pos, end_pos}}

  # Recursive compile: pair adjacent Records into intervals
  defp do_compile(
         [{start_pos, value}, {end_pos, _next_value} = next | rest],
         last_pos,
         acc_state,
         reducer,
         acc
       ) do
    with :ok <- range_valid?(start_pos, end_pos),
         {:ok, payload, new_acc} <- reducer.(start_pos, end_pos, value, acc_state) do
      compiled =
        payload
        |> Map.put(:start_pos, start_pos)
        |> Map.put(:end_pos, end_pos)

      do_compile([next | rest], last_pos, new_acc, reducer, [compiled | acc])
    end
  end

  # Last Record: extend to the dynamic end
  defp do_compile([{start_pos, value}], last_pos, acc_state, reducer, acc) do
    with :ok <- range_valid?(start_pos, last_pos),
         {:ok, payload, _new_acc} <- reducer.(start_pos, last_pos, value, acc_state) do
      compiled =
        payload
        |> Map.put(:start_pos, start_pos)
        |> Map.put(:end_pos, last_pos)

      {:ok, Enum.reverse([compiled | acc])}
    end
  end

  # Binary search: locate target_pos in the interval tuple
  defp do_find(tuple, target_pos, low, high) when low <= high do
    mid = div(low + high, 2)
    seg = elem(tuple, mid)

    cond do
      target_pos < seg.start_pos ->
        do_find(tuple, target_pos, low, mid - 1)

      is_integer(seg.end_pos) and target_pos >= seg.end_pos ->
        do_find(tuple, target_pos, mid + 1, high)

      true ->
        seg
    end
  end

  # Fallback: out of range, return the last interval
  defp do_find(tuple, _target_pos, _low, _high),
    do: elem(tuple, tuple_size(tuple) - 1)
end
