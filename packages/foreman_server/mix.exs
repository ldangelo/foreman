defmodule ForemanServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :foreman_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      ecto_repos: [ForemanServer.Repo]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ecto_sql],
      mod: {ForemanServer.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.8"},
      {:ecto_sql, "~> 3.12"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.18"},
      {:postgrex, ">= 0.0.0"}
    ]
  end
end
