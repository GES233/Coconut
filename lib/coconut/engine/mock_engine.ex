defmodule Coconut.Engine.MockEngine do
  @moduledoc """
  Minimal engine stub for exercising the edit pipeline end-to-end.

  check/1  — always passes (no engine to validate against yet).
  render/1 — collects elements_by_id with spans from all tracks.
  """

  def info(_),
    do: %{
      name: "Mock Engine",
      version: "dev"
    }

  @doc "Always ok in mock mode."
  def check(_ws), do: :ok

  @doc "Returns a flat map of note data with resolved spans from all tracks."
  def render(ws) do
    all_spans = collect_latest_spans(ws.side.spans_by_version)

    ws.side.elements_by_id
    |> Enum.map(fn {id, data} ->
      span = Map.get(all_spans, id)
      {id, Map.put(data, :span, span)}
    end)
    |> Map.new()
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
