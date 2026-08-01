defmodule ForemanServer.Http.Endpoint do
  @moduledoc "Bandit child spec for the Foreman HTTP API."

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    port = Keyword.get(opts, :port, http_port())
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    validate_remote_access!(ip)

    plug =
      cond do
        debug_live_views_enabled?() -> ForemanServerWeb.Endpoint
        debug_errors?() -> ForemanServer.Http.DevRouter
        true -> ForemanServer.Http.Router
      end
    Bandit.child_spec(
      plug: plug,
      scheme: :http,
      ip: ip,
      port: port,
      startup_log: false
    )
  end

  defp debug_errors? do
    Application.get_env(:foreman_server, :debug_errors, false)
  end

  defp debug_live_views_enabled? do
    Application.get_env(:foreman_server, :debug_live_views_enabled, false)
  end

  defp validate_remote_access!(ip) do
    if remote_bind?(ip) and not ForemanServer.Security.token_configured?() do
      raise ArgumentError,
            "FOREMAN_SERVER_AUTH_TOKEN is required when binding the Elixir server beyond loopback"
    end
  end

  defp remote_bind?({127, _, _, _}), do: false
  defp remote_bind?({0, 0, 0, 0}), do: true
  defp remote_bind?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp remote_bind?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp remote_bind?(_ip), do: true

  defp http_port do
    ForemanServer.RuntimeInfo.http_port()
  end
end
