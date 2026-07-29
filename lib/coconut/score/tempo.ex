defmodule Coconut.Score.Tempo do
  @moduledoc """
  Entry point for duration utilities.
  """
  alias Coconut.Score.{Tick, Tempo}

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

  defmodule Linear do
    @moduledoc "Linear tempo ramp segment."
    alias Coconut.Score.Tempo.Segment
    alias Coconut.Score.Tick
    import Tick
    use Segment
    defstruct [:start_tick, :end_tick, :bpm_start, :bpm_end]

    @impl true
    def build_from_event(_start_tick, end_tick, _context) when is_dynamic_tick(end_tick),
      do: {:error, :linear_requires_finite_end_tick}

    def build_from_event(_start_tick, _end_tick, %{bpm_start: bs, bpm_end: _be})
        when not is_number(bs) or bs <= 0, do: {:error, {:invalid_bpm_start, bs}}

    def build_from_event(_start_tick, _end_tick, %{bpm_start: _bs, bpm_end: be})
        when not is_number(be) or be <= 0, do: {:error, {:invalid_bpm_end, be}}

    def build_from_event(start_tick, end_tick, %{bpm_start: bpm_start, bpm_end: bpm_end}),
      do:
        {:ok,
         %__MODULE__{
           start_tick: start_tick,
           end_tick: end_tick,
           bpm_start: bpm_start,
           bpm_end: bpm_end
         }}

    def build_from_event(_, _, invalid_context),
      do: {:error, {:invalid_tempo_context, invalid_context}}

    @impl true
    def duration_sec(%{end_tick: end_tick}, _tpqn) when is_dynamic_tick(end_tick), do: :infinity
    def duration_sec(seg, tpqn), do: tick_to_sec(seg, seg.end_tick - seg.start_tick, tpqn)

    @impl true
    def tick_to_sec(_seg, 0, _tpqn), do: 0.0

    def tick_to_sec(seg, ticks, tpqn) do
      rate = rate(seg)

      if rate == 0.0 do
        ticks * (60.0 / seg.bpm_start) / tpqn
      else
        bpm_at = seg.bpm_start + rate * ticks
        60.0 / (tpqn * rate) * :math.log(bpm_at / seg.bpm_start)
      end
    end

    @impl true
    def sec_to_tick(_seg, sec, _tpqn) when sec == 0.0, do: 0

    def sec_to_tick(seg, offset_sec, tpqn) do
      rate = rate(seg)

      if rate == 0.0 do
        round(offset_sec * seg.bpm_start * tpqn / 60.0)
      else
        bpm_at = seg.bpm_start * :math.exp(offset_sec * rate * tpqn / 60.0)
        round((bpm_at - seg.bpm_start) / rate)
      end
    end

    defp rate(%{bpm_start: bs, bpm_end: be, start_tick: st, end_tick: et}),
      do: (be - bs) / (et - st)
  end

  # defmodule Curve, do: nil
  # Stub — downstream apps should implement their own
  # (e.g. via NIF to integrate as small step/linear segments).
  # Do not use Coconut's built-in Curve module here —
  # it depends on it's own timeline mechanism.

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
          Segment.duration()
  def sec_to_tick(segment, sec, tpqn), do: impl(segment).sec_to_tick(segment, sec, tpqn)

  defp impl(%module{}), do: module
  defp impl(module) when is_atom(module), do: module
end
