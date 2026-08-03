defmodule Coconut.ScenariosTest do
  use ExUnit.Case, async: false

  alias Coconut.Scenario

  # One describe per G-* scenario. No real engine involved — channels are
  # digest projections — so these run in the default `mix test`.
  @scenarios [
    Coconut.Scenarios.GInt01,
    Coconut.Scenarios.GInt02
  ]

  for mod <- @scenarios do
    describe "#{inspect(mod)}" do
      test "expect 命中" do
        assert :ok = Scenario.run_scenario(unquote(mod)).verdict
      end
    end
  end
end
