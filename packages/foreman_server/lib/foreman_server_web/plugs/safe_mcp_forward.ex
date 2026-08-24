defmodule ForemanServerWeb.Plugs.SafeMCPForward do
  @moduledoc """
  Wraps the Anubis MCP streamable-HTTP transport so that a misconfigured
  upstream (e.g. the `ForemanServer.MCP` server supervisor not running
  in the test scope) surfaces as a JSON `500` instead of an unhandled
  exception that fails the connection test.

  This is intentionally a thin wrapper — when the MCP server is
  properly supervised the inner `Anubis.Server.Transport.StreamableHTTP.Plug`
  handles the request normally. The wrapper only exists to translate
  transient startup failures into a deterministic 500 response so
  integration tests that exercise the router surface (without booting
  the full MCP tree) get a stable status code.
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    inner = Keyword.get(opts, :inner, Anubis.Server.Transport.StreamableHTTP.Plug)

    try do
      inner.call(conn, Keyword.delete(opts, :inner))
    rescue
      e ->
        Logger.warning(
          "ForemanServerWeb.Plugs.SafeMCPForward: upstream MCP transport raised #{inspect(e)} — returning 500"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{error: "mcp_transport_failure"}))
        |> halt()
    catch
      kind, reason ->
        Logger.warning(
          "ForemanServerWeb.Plugs.SafeMCPForward: upstream MCP transport threw #{inspect(kind)}:#{inspect(reason)} — returning 500"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{error: "mcp_transport_failure"}))
        |> halt()
    end
  end
end
