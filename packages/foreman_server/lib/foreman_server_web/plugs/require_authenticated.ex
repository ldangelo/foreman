defmodule ForemanServerWeb.Plugs.RequireAuthenticated do
  @moduledoc """
  Guards browser/LiveView routes with the same shared-secret bearer
  token used elsewhere in the app (`ForemanServerWeb.Plugs.BearerAuth`
  for the JSON API, `ForemanServer.MCP.Auth` for the MCP transport). The
  token may arrive via an `Authorization: Bearer <token>` header or,
  since a plain browser navigation cannot set custom headers, via a
  `?token=<token>` query parameter — mirroring `BearerAuth`'s existing
  "narrow tooling" query-param allowance.

  Unlike `BearerAuth`, an unconfigured `:api_bearer_token` does NOT
  bypass this guard. Routes behind `:require_authenticated` (currently
  the Jido live dashboard, TRD-2026-4212be7e / JLD-T001) expose live
  internal agent/signal state and must fail closed until an operator
  configures a token, rather than defaulting open like the JSON API
  does for local dev convenience.

  On failure, halts with `401` and a plain-text body (this guards an
  HTML/LiveView route, not the JSON API).
  """

  import Plug.Conn

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    expected = Application.get_env(:foreman_server, :api_bearer_token)

    if is_binary(expected) and expected != "" and token_matches?(conn, expected) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(401, "unauthorized")
      |> halt()
    end
  end

  defp token_matches?(conn, expected) do
    header_token = extract_header_token(conn)
    query_token = conn.query_params["token"]
    header_token == expected or query_token == expected
  end

  defp extract_header_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      ["bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end
end
