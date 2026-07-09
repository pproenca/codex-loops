defmodule CodexLoops.MixProject do
  use Mix.Project

  @version "VERSION" |> Path.expand(__DIR__) |> File.read!() |> String.trim()

  def project do
    [
      app: :codex_loops,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      releases: releases(),
      deps: deps(),
      dialyzer: dialyzer()
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
        include_executables_for: [:unix]
      ],
      codex_loops_mcp: [
        steps: [:assemble, &Burrito.wrap/1],
        include_executables_for: [:unix],
        applications: [
          anubis_mcp: :load
        ],
        burrito: [
          targets: [
            native: native_burrito_target()
          ]
        ]
      ]
    ]
  end

  defp native_burrito_target do
    [
      os: burrito_os(),
      cpu: burrito_cpu()
    ]
  end

  defp burrito_os do
    case :os.type() do
      {:unix, :darwin} -> :darwin
      {:unix, _name} -> :linux
      {:win32, _name} -> :windows
    end
  end

  defp burrito_cpu do
    :system_architecture
    |> :erlang.system_info()
    |> to_string()
    |> case do
      "aarch64" <> _rest -> :aarch64
      "arm64" <> _rest -> :aarch64
      _other -> :x86_64
    end
  end

  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:exqlite, "~> 0.38.0"},
      {:bandit, "~> 1.5"},
      {:anubis_mcp, "~> 1.6", runtime: false},
      {:burrito, "~> 1.5", runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14.1", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:stream_data, "~> 1.3", only: :test},
      {:phoenix_test, "~> 0.11.1", only: :test},
      {:phoenix_test_playwright, "~> 0.15.0", only: :test, runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit, :anubis_mcp, :peri],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end
end
