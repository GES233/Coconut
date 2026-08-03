defmodule Coconut.Engines.Mock do
  @moduledoc """
  Minimal engine for exercising the edit pipeline end-to-end.

  info/1   — declares a few global knobs (`:gender`, `:depth`,
             `:phoneme_mode`) so the globals gate has something to judge.
  check/2  — always passes with no prepared state (`checked: nil`).
  render/3 — flat map of element data with resolved spans from all tracks,
             plus the request's folded overrides and globals so callers can
             assert the Resolve → Engine handoff and the globals pass-through.
  """

  @behaviour Coconut.Engine

  alias Coconut.Engine.Request

  @impl true
  def info(_),
    do: %{
      name: "Mock Engine",
      version: "dev",
      info: "",
      globals: %{
        gender: {:range, -1.0, 1.0},
        depth: {:range, 0.0, 2.0},
        phoneme_mode: {:enum, [:auto, :manual]}
      }
    }

  @impl true
  def check(%Request{}, _config), do: {:ok, %{passed: true, entries: [], checked: nil}}

  @impl true
  def render(%Request{} = request, _checked, _config) do
    ws = request.workspace

    notes =
      for {_track_id, track} <- ws.tracks,
          {id, span} <- Coconut.Track.latest_spans(track),
          into: %{} do
        data = Map.get(track.elements_by_id, id, %{})
        {id, Map.put(data, :span, span)}
      end

    {:ok, %{notes: notes, overrides: request.interventions, globals: request.globals}}
  end
end
