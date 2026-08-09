defmodule Coconut.Engines.Mock do
  @moduledoc """
  Minimal engine for exercising the edit pipeline end-to-end.

  Reference/test 引擎定位：它是契约的参照实现与测试桩，留在 lib 是因为
  `examples/` 下的脚本直接依赖它。

  info/1   — declares a few global knobs (`:gender`, `:depth`,
             `:phoneme_mode`) so the globals gate has something to judge.
  check/2  — always passes with no prepared state (`checked: nil`).
  render/3 — flat map of element data with resolved spans from all tracks,
             plus the request's folded overrides and globals so callers can
             assert the Resolve → Engine handoff and the globals pass-through.
  """

  @behaviour Coconut.Render.Engine

  alias Coconut.Render.Engine.{Artifact, Request}

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
    notes =
      for {_track_id, view} <- request.snapshot.tracks,
          {id, element, span} <- view.elements,
          into: %{} do
        {id, Map.put(element, :span, span)}
      end

    {:ok,
     %Artifact{
       engine: "Mock Engine",
       edit_version: request.snapshot.edit_version,
       globals: request.globals,
       overrides: request.interventions,
       payload: %{notes: notes}
     }}
  end
end
