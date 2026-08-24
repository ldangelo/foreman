defmodule ForemanServerWeb.Plugs.RequireAuthenticated do
  @moduledoc """
  Authentication gate for browser-rendered routes.

  Until the full session/token auth wiring lands (TRD-2026-4212be7e,
  follow-up bead), this plug simply rejects every request with `401`
  for JSON/API style requests or `302` for HTML browser requests so
  gated routes are never accidentally served without credentials.

  The plug MUST short-circuit the connection with `halt/1` so
  downstream handlers (LiveDashboard, etc.) never run for an
  unauthenticated request.
  """

  import Plug.Conn

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    case json_request?(conn) do
      true ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()

      false ->
        conn
        |> put_resp_header("location", "/")
        |> send_resp(302, "")
        |> halt()
    end
  end

  defp json_request?(conn) do
    case get_req_header(conn, "accept") do
      [accept | _] ->
        String.contains?(accept, "application/json") or
          String.contains?(accept, "text/json")

      _ ->
        false
    end
  end
end
