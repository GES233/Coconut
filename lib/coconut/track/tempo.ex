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

  alias Coconut.Score.Tempo
  alias Coconut.Track

  @impl true
  def coord_domain, do: :tick

  @impl true
  def cast_element(_id, _span, attrs) do
    with {:ok, milli_bpm} <- Tempo.cast_bpm(Map.get(attrs, :bpm)) do
      {:ok, Map.put(attrs, :bpm, milli_bpm)}
    end
  end

  @impl true
  def validate_gesture(:delete, track, %{id: id}) do
    if track.space.ids == [] or hd(track.space.ids) != id do
      :ok
    else
      {:error, {:tempo_first_protected, id}}
    end
  end

  @impl true
  def split_inherit(element, _new_id), do: element || %{}

  @impl true
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
end
