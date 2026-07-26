defmodule ForemanServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :foreman_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp deps do
    [
      # Commanded ES/CQRS framework
      {:commanded, "~> 1.0"},
      {:eventstore, "~> 1.3"},
      {:commanded_eventstore_adapter, "~> 1.0"},

      # Phoenix HTTP boundary
      {:phoenix, "~> 1.7"},
      {:plug_cowboy, "~> 2.6"},
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ForemanServer.Application, []}
    ]
  end
end
