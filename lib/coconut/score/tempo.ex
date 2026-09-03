defmodule Coconut.Score.Tempo do
  @moduledoc """
  Entry point for duration utilities.
  """
  alias Coconut.Score.{Tempo, Tick}

  # For guard macros
  import Tick

  @typedoc "Physical time in seconds."
  @type physical_time :: float()

  # ---- Tempo Change Event ----

  defmodule Event do
    @moduledoc "Tempo change event."
    @type context :: term()
    @type t :: %__MODULE__{module: module(), context: context()}
    defstruct [:module, :context]
  end

  @typedoc "A tempo segment starting at a given tick."
  @type tempo_event :: {Tick.numeric_tick(), Event.t()}
  @type tempo_events :: [tempo_event()] | {[tempo_event()], last :: Tick.t()}

  # ---- Tempo Segment ----

  defmodule Segment do
    @moduledoc "Behaviour definition for tempo segments."
    @typedoc "A struct implementing a tempo segment."
    @type segment :: struct()
    @typedoc "Actual duration in seconds."
    @type duration :: float() | :infinity

    @callback build_from_event(
                start_tick :: Tick.numeric_tick(),
                end_tick :: Tick.t(),
                event :: Event.context()
              ) :: {:ok, segment()} | {:error, term()}
    @callback duration_sec(segment, tpqn :: pos_integer()) :: duration()
    @callback tick_to_sec(segment, tick_offset :: Tick.numeric_tick(), tpqn :: pos_integer()) ::
                duration()
    @callback sec_to_tick(segment, sec_offset :: Tempo.physical_time(), tpqn :: pos_integer()) ::
                Tick.numeric_tick()

    defmacro __using__(_opts) do
      quote do
        @behaviour Coconut.Score.Tempo.Segment
      end
    end
  end

  defmodule Step do
    @moduledoc "The simplest tempo segment — constant BPM (step)."
    alias Coconut.Score.Tempo.Segment
    use Segment
    defstruct [:start_tick, :end_tick, :bpm]

    @impl true
    def build_from_event(_, _, %{bpm: bpm}) when not is_number(bpm),
      do: {:error, {:invalid_bpm, bpm}}

    def build_from_event(_, _, %{bpm: bpm}) when bpm <= 0, do: {:error, {:bpm_is_negative, bpm}}

    def build_from_event(start_tick, end_tick, %{bpm: bpm}),
      do: {:ok, %__MODULE__{start_tick: start_tick, end_tick: end_tick, bpm: bpm}}

    def build_from_event(_, _, invalid_context),
      do: {:error, {:invalid_tempo_context, invalid_context}}

    @impl true
    def duration_sec(%{end_tick: end_tick}, _tpqn) when is_dynamic_tick(end_tick), do: :infinity
    def duration_sec(seg, tpqn), do: tick_to_sec(seg, seg.end_tick - seg.start_tick, tpqn)

    @impl true
    def tick_to_sec(seg, ticks, tpqn) do
      sec_per_quarter = 60.0 / seg.bpm
      ticks * (sec_per_quarter / tpqn)
    end

    @impl true
    def sec_to_tick(seg, offset_sec, tpqn) do
      round(offset_sec * (tpqn * seg.bpm / 60))
    end
  end

  # ---- Utility functions ----

  @spec build_segment_from_event(module(), Tick.t(), Tick.t(), any()) ::
          {:ok, Segment.segment()} | {:error, term()}
  def build_segment_from_event(_module, start_tick, _, _) when start_tick < 0,
    do: {:error, {:tick_invalid, %{start_tick: start_tick}}}

  def build_segment_from_event(module, start_tick, end_tick, payload)
      when is_dynamic_tick(end_tick), do: module.build_from_event(start_tick, end_tick, payload)

  def build_segment_from_event(_module, start_tick, end_tick, _) when start_tick >= end_tick,
    do: {:error, {:tick_invalid, %{start_tick: start_tick, end_tick: end_tick}}}

  def build_segment_from_event(module, start_tick, end_tick, payload),
    do: module.build_from_event(start_tick, end_tick, payload)

  @spec tick_to_sec(Segment.segment(), Tick.t(), pos_integer()) :: Segment.duration()
  def tick_to_sec(segment, tick, tpqn), do: impl(segment).tick_to_sec(segment, tick, tpqn)

  @spec duration_sec(Segment.segment(), pos_integer()) :: Segment.duration()
  def duration_sec(segment, tpqn), do: impl(segment).duration_sec(segment, tpqn)

  @spec sec_to_tick(Segment.segment(), physical_time(), pos_integer()) ::
          Tick.numeric_tick()
  def sec_to_tick(segment, sec, tpqn), do: impl(segment).sec_to_tick(segment, sec, tpqn)

  @doc """
  Normalize a bpm value into exact milli-bpm integer storage (`120.5` → `120_500`).

  This is the adapter-layer rationalization point (design doc §4/§6): bpm
  enters as a domain number and is stored as an exact integer, so tempo
  elements stay digestable (`Tamale.Digest` rejects floats) and no float
  dust crosses the kernel. Accepts positive integers, finite floats, and
  `{num, den}` rationals. The input is **bpm**, not milli-bpm; the ×1000
  rounding is the single defined rounding point.
  """
  @spec cast_bpm(term()) :: {:ok, pos_integer()} | {:error, {:invalid_bpm, term()}}
  def cast_bpm(bpm) when is_integer(bpm) and bpm > 0, do: {:ok, bpm * 1000}

  def cast_bpm(bpm) when is_float(bpm) and bpm > 0 do
    milli = round(bpm * 1000)
    if milli > 0, do: {:ok, milli}, else: {:error, {:invalid_bpm, bpm}}
  end

  def cast_bpm({num, den}) when is_integer(num) and is_integer(den) and num > 0 and den > 0 do
    milli = round(num * 1000 / den)
    if milli > 0, do: {:ok, milli}, else: {:error, {:invalid_bpm, {num, den}}}
  end

  def cast_bpm(other), do: {:error, {:invalid_bpm, other}}

  defp impl(%module{}), do: module
  defp impl(module) when is_atom(module), do: module
end
