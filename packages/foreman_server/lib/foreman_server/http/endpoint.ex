defmodule ForemanServer.Http.Endpoint do
  @moduledoc "Bandit child spec for the Foreman HTTP API."

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    port = Keyword.get(opts, :port, Application.get_env(:foreman_server, :http_port, 0))
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})

    Bandit.child_spec(
      plug: ForemanServer.Http.Router,
      scheme: :http,
      ip: ip,
      port: port,
      startup_log: false
    )
  end
end
