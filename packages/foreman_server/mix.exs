defmodule ForemanServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :foreman_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # EventStore persistence
      {:eventstore, "~> 1.3"},

      # Commanded + EventStore adapter (EventStore "via Commanded adapter")
      {:commanded, "~> 1.4"},
      {:commanded_eventstore_adapter, "~> 1.4"},

      # Phoenix HTTP boundary
      {:phoenix, "~> 1.7"},
      {:plug_cowboy, "~> 2.6"},

      # JSON serialization for EventStore
      {:jason, "~> 1.4"},
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
end
