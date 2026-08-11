defmodule Coconut.MixProject do
  use Mix.Project

  @version "0.2.0"
  @description "An engine-agnostic editor core that treats user intervention as first-class"

  def project do
    [
      app: :coconut,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: [precommit: ["compile --warnings-as-errors", "format", "test"]],
      deps: deps(),
      description: @description
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp deps do
    [
      # Rebase support
      {:tamale, github: "SynapticStrings/Tamal"},
      # Lib Management
      {:ex_doc, "~> 0.40.3", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
