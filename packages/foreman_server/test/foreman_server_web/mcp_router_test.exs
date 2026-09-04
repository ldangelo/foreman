defmodule ForemanServerWeb.MCPRouterTest do
  use ExUnit.Case, async: false

  use Phoenix.ConnTest

  @endpoint ForemanServerWeb.Endpoint
  @token "mcp-router-test-token"

  @session_config_key {Anubis.Server.Supervisor, ForemanServer.MCP, :session_config}

  setup do
    previous_token = Application.get_env(:foreman_server, :api_bearer_token)
    previous_mcp = Application.get_env(:foreman_server, :mcp, [])

    Application.put_env(:foreman_server, :api_bearer_token, @token)

    Application.put_env(
      :foreman_server,
      :mcp,
      Keyword.merge(previous_mcp, enabled: true, allow_insecure_local: false)
    )

    # ForemanServer.MCP's Anubis.Server.Supervisor is not actually booted in
    # the test env (the app supervisor already started without the :mcp
    # child before this test flips `enabled: true`), so the transport Plug's
    # `resolve_runtime_config/1` finds no `:session_config` persistent_term
    # and raises ArgumentError. Seed the same shape
    # `Anubis.Server.Supervisor.init/1` writes so the Plug can resolve a
    # registry module, mirroring the pattern used for other Anubis-backed
    # MCP tests (see skill://foreman-test-isolation root cause #6).
    :persistent_term.put(@session_config_key, %{
      server_module: ForemanServer.MCP,
      registry_mod: Anubis.Server.Registry.Local,
      transport: [
        layer: Anubis.Server.Transport.StreamableHTTP,
        name: ForemanServer.MCP.Transport
      ],
      session_idle_timeout: nil,
      timeout: 30_000,
      task_supervisor: ForemanServer.MCP.TaskSupervisor,
      task_store: [adapter: Anubis.Server.TaskStore.Local, name: ForemanServer.MCP.TaskStore]
    })

    on_exit(fn ->
      if previous_token == nil do
        Application.delete_env(:foreman_server, :api_bearer_token)
      else
        Application.put_env(:foreman_server, :api_bearer_token, previous_token)
      end

      Application.put_env(:foreman_server, :mcp, previous_mcp)
      :persistent_term.erase(@session_config_key)
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

    # No `accept: text/event-stream` header is sent, so the Anubis
    # transport (not our own app) rejects the GET per the MCP Streamable
    # HTTP spec. The JSON-RPC-shaped body (not a generic Phoenix error
    # page) proves the request reached the real MCP transport rather than
    # being rejected earlier by auth (401) or routing (404).
    body = json_response(conn, 406)
    assert %{"jsonrpc" => "2.0", "error" => %{"data" => data}} = body
    assert get_in(data, ["data", "message"]) == "Accept header must include text/event-stream"
  end
end
