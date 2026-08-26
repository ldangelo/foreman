defmodule ForemanServerWeb.Plugs.BearerAuth do
  @moduledoc """
  Bearer token authentication for the JSON API.

  The expected token is read from `:foreman_server, :api_bearer_token`
  application config. When unset (e.g. dev), authentication is bypassed
  and a `WWW-Authenticate` header is NOT emitted (acceptable for local
  development).

  Operators MAY supply the token via:

    * `Authorization: Bearer <token>` header
    * `?token=<token>` query parameter (for narrow tooling only)

  On failure, responds with `401` and a JSON error body.
  """

  import Plug.Conn

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    expected = Application.get_env(:foreman_server, :api_bearer_token)

    cond do
      is_nil(expected) or expected == "" ->
        conn

      token_matches?(conn, expected) ->
        conn

      true ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
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
