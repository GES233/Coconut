defmodule Coconut.EngineTest do
  use ExUnit.Case, async: true

  alias Coconut.{Engine, Workspace}
  alias Coconut.Engine.{MockEngine, Request}
  alias Coconut.Util.ID

  defmodule BareEngine do
    @moduledoc "Engine without a :globals declaration."
    @behaviour Coconut.Engine

    @impl true
    def info(_), do: %{name: "Bare", version: "dev"}

    @impl true
    def check(_request, _config), do: {:ok, nil}

    @impl true
    def render(_request, _checked, _config), do: {:ok, :rendered}
  end

  defp request(globals) do
    {:ok, request} = Request.new(%{workspace: nil, globals: globals})
    request
  end

  defp workspace do
    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        tracks: %{vocal: %Tamale.Space{}},
        side: %Workspace.Side{}
      })

    ws
  end

  test "valid globals pass the gate" do
    assert {:ok, nil} = Engine.run_check(MockEngine, request(%{gender: 0.5, phoneme_mode: :auto}))
  end

  test "empty globals always pass, declared or not" do
    assert {:ok, nil} = Engine.run_check(MockEngine, request(%{}))
    assert {:ok, nil} = Engine.run_check(BareEngine, request(%{}))
  end

  test "unknown global vetoes the round" do
    assert {:error, {:check_failed, [entry]}} =
             Engine.run_check(MockEngine, request(%{breathiness: 1}))

    assert entry == %{kind: :global, key: :breathiness, reason: :unknown_global}
  end

  test "out-of-range and non-number globals are reported" do
    assert {:error, {:check_failed, [entry]}} =
             Engine.run_check(MockEngine, request(%{gender: 2.0}))

    assert entry.reason == {:out_of_range, {-1.0, 1.0}}

    assert {:error, {:check_failed, [entry]}} =
             Engine.run_check(MockEngine, request(%{gender: "high"}))

    assert entry.reason == :not_a_number
  end

  test "enum global rejects values outside the set" do
    assert {:error, {:check_failed, [entry]}} =
             Engine.run_check(MockEngine, request(%{phoneme_mode: :semi}))

    assert entry.reason == {:not_in_enum, [:auto, :manual]}
  end

  test "failures are aggregated, not short-circuited" do
    assert {:error, {:check_failed, entries}} =
             Engine.run_check(MockEngine, request(%{gender: 9.0, breathiness: 1}))

    assert length(entries) == 2
    assert Enum.all?(entries, &(&1.kind == :global))
  end

  test "engine without a :globals declaration accepts none" do
    assert {:error, {:check_failed, [entry]}} =
             Engine.run_check(BareEngine, request(%{gender: 0.5}))

    assert entry.reason == :unknown_global
  end

  test "render passes globals through untouched" do
    {:ok, request} = Request.new(%{workspace: workspace(), globals: %{depth: 1.5}})

    assert {:ok, nil} = Engine.run_check(MockEngine, request)
    assert {:ok, artifact} = Engine.run_render(MockEngine, request, nil)
    assert artifact.globals == %{depth: 1.5}
    assert artifact.overrides == %{}
  end
end
