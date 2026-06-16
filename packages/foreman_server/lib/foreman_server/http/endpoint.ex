defmodule ForemanServer.Http.Endpoint do
  @moduledoc "Bandit child spec for the Foreman HTTP API."

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    port = Keyword.get(opts, :port, http_port())
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})

    Bandit.child_spec(
      plug: ForemanServer.Http.Router,
      scheme: :http,
      ip: ip,
      port: port,
      startup_log: false
    )
  end

  defp http_port do
    Application.get_env(:foreman_server, :http_port) ||
      String.to_integer(System.get_env("FOREMAN_SERVER_HTTP_PORT") || "0")
  end
end
