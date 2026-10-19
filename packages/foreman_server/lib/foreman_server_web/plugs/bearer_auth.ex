defmodule ForemanServerWeb.Plugs.BearerAuth do
  @moduledoc """
  Bearer token authentication for the JSON API. Fails closed.

  The expected token is read from `:foreman_server, :api_bearer_token`
  application config (`FOREMAN_API_TOKEN` at runtime).

    * **Token configured (non-empty)** — the request MUST present it, via
      `Authorization: Bearer <token>` or `?token=<token>` (narrow tooling
      only). Otherwise the plug halts with `401` and
      `{"error":"unauthorized"}`.
    * **Token not configured** — the plug halts with `401` and a JSON body
      carrying a `detail` that says no token is configured, unless the
      operator explicitly opted in to unauthenticated local access with
      `config :foreman_server, :api, allow_insecure_local: true`
      (`FOREMAN_API_ALLOW_INSECURE_LOCAL=true` at runtime; on in `dev.exs`
      and `test.exs`, off in `config.exs`). Only the boolean `true` opens
      the API; any other value, or a missing key, stays closed. The opt-in
      NEVER weakens a configured token: when a token is set it is always
      required.

  This mirrors the other guarded surfaces:
  `ForemanServerWeb.Plugs.RequireAuthenticated` (browser/LiveView routes,
  no opt-in) and `ForemanServer.MCP.Auth` (MCP transport, which has its own
  `allow_insecure_local` flag under `:mcp`).
  """

  import Plug.Conn

  @no_token_detail "no API token is configured on the server " <>
                     "(set FOREMAN_API_TOKEN, or allow_insecure_local for local development)"

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    expected = Application.get_env(:foreman_server, :api_bearer_token)

    cond do
      is_nil(expected) or expected == "" ->
        if insecure_local_allowed?() do
          conn
        else
          unauthorized(conn, %{error: "unauthorized", detail: @no_token_detail})
        end

      token_matches?(conn, expected) ->
        conn

      true ->
        unauthorized(conn, %{error: "unauthorized"})
    end
  end

  defp unauthorized(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(body))
    |> halt()
  end

  defp insecure_local_allowed? do
    case Application.get_env(:foreman_server, :api, []) do
      opts when is_list(opts) -> Keyword.get(opts, :allow_insecure_local, false) === true
      _ -> false
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
