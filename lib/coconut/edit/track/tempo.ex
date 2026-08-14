defmodule Coconut.Edit.Track.Tempo do
  @moduledoc """
  Tempo track: tick-domain, bare-map elements carrying exact milli-bpm.

  Tempo events are not notes — the element is `%{bpm: milli_bpm}` with
  bpm normalized to an integer milli-bpm at cast time (`cast_element/3`
  is the single place float bpm is rounded, design doc §6).

  The first tempo event is protected from deletion: the hole-inheritance
  convention (a gap inherits the previous event's bpm) needs a head to
  inherit from.
  """

  use Coconut.Edit.Track
  @behaviour Coconut.Edit.Track.TempoDerive

  alias Coconut.Edit.Track
  alias Coconut.Score.Tempo

  @impl Coconut.Edit.Track
  def coord_domain, do: :tick

  @impl Coconut.Edit.Track
  def cast_element(_id, _span, attrs) do
    with {:ok, milli_bpm} <- Tempo.cast_bpm(Map.get(attrs, :bpm)) do
      {:ok, Map.put(attrs, :bpm, milli_bpm)}
    end
  end

  @impl Coconut.Edit.Track
  def edit_element(element, changes) do
    cast_element(nil, nil, Map.merge(element || %{}, changes))
  end

  @impl Coconut.Edit.Track
  def validate_gesture(:delete, track, %{id: id}) do
    if track.space.ids == [] or hd(track.space.ids) != id do
      :ok
    else
      {:error, {:tempo_first_protected, id}}
    end
  end

  def validate_gesture(_gesture, _track, _info), do: :ok

  @impl Coconut.Edit.Track
  def split_elements(element, _context), do: {element || %{}, element || %{}}

  @impl Coconut.Edit.Track
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

  This is the tempo track's `:tempo_derive` capability —
  `Coconut.Edit.Workspace` binds its `tempo` field by capability
  (`Coconut.Edit.Track.supports?/2`), not by module identity.
  """
  @impl Coconut.Edit.Track.TempoDerive
  @spec tempo_events(Track.t()) :: [{Coconut.Score.Tick.numeric_tick(), Tempo.Event.t()}]
  def tempo_events(track) do
    track
    |> view()
    |> Enum.map(fn {_id, element, {start, _end}} ->
      {start, %Tempo.Event{module: Tempo.Step, context: %{bpm: element.bpm / 1000}}}
    end)
  end

  @doc """
  Versioned exact step projection for the frame-warp tempo pair
  (`Coconut.Edit.Workspace.tempo_steps_at/2`): `{start_tick, milli_bpm}`
  pairs from the span snapshot at `version`, sorted by tick.

  Stays in integer milli-bpm — warp coordinates reject floats, so this
  never goes through `tempo_events/1`'s denormalization. Element payloads
  are the current table (bpm value edits are unversioned content edits;
  documented limitation, design doc §5 item 4).
  """
  @impl Coconut.Edit.Track.TempoDerive
  @spec tempo_steps_at(Track.t(), Tamale.version()) ::
          [{Coconut.Score.Tick.numeric_tick(), pos_integer()}]
  def tempo_steps_at(track, version) do
    track
    |> Track.spans_at(version)
    |> Enum.flat_map(fn {id, {start, _end}} ->
      case Map.fetch(track.elements_by_id, id) do
        {:ok, %{bpm: milli}} when is_integer(milli) -> [{start, milli}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {tick, _milli} -> tick end)
  end
end
