defmodule Coconut.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description "headless SVS editor"

  def project do
    [
      app: :coconut,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: [precommit: ["compile --warnings-as-errors", "format", "test"]],
      deps: deps(),
      description: @description
    ]
  end

  def application do
    []
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp deps do
    [
      # Rebase support
      {:tamale, path: "../tamale"}
      # {:tamale, github: "SynapticStrings/Tamal"}

      # Compute Agent
      #  add orchid or blabla
    ]
  end
end
