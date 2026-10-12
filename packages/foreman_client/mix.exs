defmodule ForemanClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :foreman_client,
      version: "0.1.0",
      elixir: "~> 1.18",
      description: "HTTP client for a running foreman_server's /api/jobsites",
      deps: []
    ]
  end

  # `:inets` (httpc) and `:ssl` are OTP; the client has no other dependencies.
  def application, do: [extra_applications: [:logger, :inets, :ssl]]
end
