defmodule CodexLoops.MixProject do
  use Mix.Project

  def project do
    [
      app: :codex_loops,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Workflow.CLI, name: "agent-loops"],
      releases: releases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl],
      mod: {Workflow.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp releases do
    [
      agent_loops: [
        include_executables_for: [:unix],
        overlays: ["rel/overlays"]
      ]
    ]
  end

  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:exqlite, "~> 0.38.0"},
      {:bandit, "~> 1.5"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:stream_data, "~> 1.3", only: :test}
    ]
  end
end
