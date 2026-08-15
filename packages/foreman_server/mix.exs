defmodule ForemanServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :foreman_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # EventStore persistence
      {:eventstore, "~> 1.3"},

      # Phoenix HTTP boundary
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:plug_cowboy, "~> 2.6"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:mox, "~> 1.0", only: :test},
      {:meck, "~> 1.2", only: :test},
      {:stream_data, "~> 1.1", only: :test},
      # JSON serialization for EventStore
      {:jason, "~> 1.4"},

      # Anubis MCP server (TRD-036)
      {:anubis_mcp, "~> 1.10"}
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ForemanServer.Application, []},
      env: [
        event_stores: [ForemanServer.EventStore]
      ]
    ]
  end

  defp releases do
    [
      foreman_server: [
        config_providers: [
          {ForemanServer.ConfigProviders.Secrets, []}
        ]
      ]
    ]
  end
end
