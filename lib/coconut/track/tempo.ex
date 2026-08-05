defmodule Coconut.Track.Tempo do
  @moduledoc """
  Tempo track: tick-domain, bare-map elements carrying exact milli-bpm.

  Tempo events are not notes — the element is `%{bpm: milli_bpm}` with
  bpm normalized to an integer milli-bpm at cast time (`cast_element/3`
  is the single place float bpm is rounded, design doc §6).

  The first tempo event is protected from deletion: the hole-inheritance
  convention (a gap inherits the previous event's bpm) needs a head to
  inherit from.
  """

  use Coconut.Track
  @behaviour Coconut.Track.TempoDerive

  alias Coconut.Score.Tempo
  alias Coconut.Track

  @impl Coconut.Track
  def coord_domain, do: :tick

  @impl Coconut.Track
  def cast_element(_id, _span, attrs) do
    with {:ok, milli_bpm} <- Tempo.cast_bpm(Map.get(attrs, :bpm)) do
      {:ok, Map.put(attrs, :bpm, milli_bpm)}
    end
  end

  @impl Coconut.Track
  def edit_element(element, changes) do
    cast_element(nil, nil, Map.merge(element || %{}, changes))
  end

  @impl Coconut.Track
  def validate_gesture(:delete, track, %{id: id}) do
    if track.space.ids == [] or hd(track.space.ids) != id do
      :ok
    else
      {:error, {:tempo_first_protected, id}}
    end
  end

  @impl Coconut.Track
  def split_inherit(element, _new_id), do: element || %{}

  # Pickle 能力回调（可选能力，同 tempo_events/1 的先例，不进 Track
  # behaviour 必需回调清单）：元素是 %{bpm: 整数 milli-bpm} 裸 map，
  # dump 校验形状后原样透传，load 同。
  def dump_element(%{bpm: bpm} = element) when is_integer(bpm), do: {:ok, element}

  def dump_element(other), do: {:error, {:invalid_tempo_element, other}}

  def load_element(%{bpm: bpm} = dumped) when is_integer(bpm), do: {:ok, dumped}

  def load_element(other), do: {:error, {:invalid_tempo_element_dump, other}}

  @impl Coconut.Track
  def view(track) do
    # Tempo events must follow the Space's sequence order (not span order):
    # Move permutes ids, and every live event must survive the flattening
    # without silent drops — TempoMap/RecordMap sorts by position itself.
    latest = Track.latest_spans(track)

    Enum.flat_map(track.space.ids, fn id ->
      case Map.get(latest, id) do
        {start, end_tick} ->
          element = Map.get(track.elements_by_id, id, %{})
          [{id, element, {start, end_tick}}]

        _no_span ->
          []
      end
    end)
  end

  @doc """
  Projects the track for `Coconut.Score.TempoMap.compile/2`:
  `{start_tick, Tempo.Event}` pairs in sequence order, bpm denormalized
  from milli-bpm back to plain bpm.

  This is the tempo track's capability marker — `Coconut.Workspace` binds
  its `tempo` field by `tempo_events/1` export, not by module identity.
  """
  @impl Coconut.Track.TempoDerive
  @spec tempo_events(Track.t()) :: [{Coconut.Score.Tick.numeric_tick(), Tempo.Event.t()}]
  def tempo_events(track) do
    track
    |> view()
    |> Enum.map(fn {_id, element, {start, _end}} ->
      {start, %Tempo.Event{module: Tempo.Step, context: %{bpm: element.bpm / 1000}}}
    end)
  end
end
