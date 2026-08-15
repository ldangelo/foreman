defmodule ForemanServerWeb.MCPRouterTest do
  use ExUnit.Case, async: false

  use Phoenix.ConnTest

  @endpoint ForemanServerWeb.Endpoint
  @token "mcp-router-test-token"

  setup do
    previous_token = Application.get_env(:foreman_server, :api_bearer_token)
    previous_mcp = Application.get_env(:foreman_server, :mcp, [])

    Application.put_env(:foreman_server, :api_bearer_token, @token)

    Application.put_env(
      :foreman_server,
      :mcp,
      Keyword.merge(previous_mcp, enabled: true, allow_insecure_local: false)
    )

    on_exit(fn ->
      if previous_token == nil do
        Application.delete_env(:foreman_server, :api_bearer_token)
      else
        Application.put_env(:foreman_server, :api_bearer_token, previous_token)
      end

      Application.put_env(:foreman_server, :mcp, previous_mcp)
    end)

    :ok
  end

  test "GET /mcp returns 401 when authorization is missing" do
    conn = build_conn() |> get("/mcp/mcp")

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "GET /mcp is routed through the MCP transport when authorized" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> put_req_header("mcp-protocol-version", "2025-06-18")
      |> get("/mcp/mcp")

    assert conn.status == 500
  end
end
