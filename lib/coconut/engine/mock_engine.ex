defmodule Coconut.Engine.MockEngine do
  @moduledoc """
  Minimal engine for exercising the edit pipeline end-to-end.

  info/1   — declares a few global knobs (`:gender`, `:depth`,
             `:phoneme_mode`) so the globals gate has something to judge.
  check/2  — always passes (no engine to validate against yet).
  render/2 — flat map of element data with resolved spans from all tracks,
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
      globals: %{
        gender: {:range, -1.0, 1.0},
        depth: {:range, 0.0, 2.0},
        phoneme_mode: {:enum, [:auto, :manual]}
      }
    }

  @impl true
  def check(%Request{}, _config), do: :ok

  @impl true
  def render(%Request{} = request, _config) do
    ws = request.workspace
    all_spans = collect_latest_spans(ws.side.spans_by_version)

    notes =
      ws.side.elements_by_id
      |> Enum.map(fn {id, data} ->
        span = Map.get(all_spans, id)
        {id, Map.put(data, :span, span)}
      end)
      |> Map.new()

    {:ok, %{notes: notes, overrides: request.interventions, globals: request.globals}}
  end

  defp collect_latest_spans(spans_by_track) do
    Enum.reduce(spans_by_track, %{}, fn {_track_id, track_spans}, acc ->
      latest =
        case Enum.max(Map.keys(track_spans), fn -> nil end) do
          nil -> %{}
          v -> Map.get(track_spans, v, %{})
        end

      Map.merge(acc, latest)
    end)
  end
end
