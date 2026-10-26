defmodule ForemanServer.MCP.HttpBootTest do
  @moduledoc """
  `/mcp` answers on a server that `mix phx.server` did not start (foreman-cnn1l).

  `Anubis.Server.Supervisor` returns `:ignore` for an HTTP transport that carries no `start:`
  option unless it believes an HTTP server is running: `PHX_SERVER`, `ANUBIS_MCP_SERVER`, or
  Phoenix's `:serve_endpoints` application env, which Phoenix's own `mix.exs` defaults to `false`
  and only `mix phx.server` sets to `true`. A release (`prod.exs` sets `server: true`) and the
  live harnesses (`mix run --no-start --no-halt boot.exs`) serve HTTP without it, so the MCP
  supervisor was silently skipped, its `:session_config` persistent_term was never written and
  every `/mcp` request raised `ArgumentError` (HTTP 500): no agent could call a Foreman tool.
  The rest of the suite never saw it: the test environment disables MCP, and
  `MCPRouterTest` writes the persistent_term by hand.

  These tests start the child `ForemanServer.Application.children/0` builds for an enabled MCP,
  under the Phoenix state of such a boot (`:serve_endpoints` false, neither environment
  variable), with the persistent_term erased first so only the real supervisor can write it, and
  speak to it through the real endpoint the way an MCP client does (`initialize`,
  `notifications/initialized`, `tools/list`, `tools/call`).
  """
  use ForemanServerWeb.ConnCase, async: false

  alias ForemanServer.MCP

  @session_config_key {Anubis.Server.Supervisor, MCP, :session_config}
  @token "mcp-http-boot-test-token"
  @protocol_version "2025-06-18"

  # The two settings of `config/dev.exs`'s `:mcp` that a harness-booted server runs with.
  @dev_mcp [enabled: true, mount: "/mcp", allow_workflow_writes: true, allow_insecure_local: true]

  setup do
    previous_app_env =
      for key <- [:mcp, :api_bearer_token], do: {key, Application.fetch_env(:foreman_server, key)}

    previous_serve_endpoints = Application.fetch_env(:phoenix, :serve_endpoints)

    previous_os_env =
      for name <- ~w(PHX_SERVER ANUBIS_MCP_SERVER), do: {name, System.get_env(name)}

    # The state of `mix run --no-start --no-halt`: nothing that tells Anubis a server is running.
    Application.put_env(:phoenix, :serve_endpoints, false)
    Enum.each(previous_os_env, fn {name, _} -> System.delete_env(name) end)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    :persistent_term.erase(@session_config_key)

    on_exit(fn ->
      restore_env(:foreman_server, previous_app_env)
      restore_env(:phoenix, serve_endpoints: previous_serve_endpoints)

      for {name, value} <- previous_os_env do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      :persistent_term.erase(@session_config_key)
    end)
  end

  defp restore_env(app, entries) do
    for {key, previous} <- entries do
      case previous do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end
  end

  # Boots what `ForemanServer.Application` supervises for `mcp_env`, nothing else.
  defp boot_mcp!(mcp_env) do
    Application.put_env(:foreman_server, :mcp, mcp_env)

    spec = Enum.find(ForemanServer.Application.children(), &match?({MCP, _}, &1))

    assert spec,
           "ForemanServer.Application.children/0 does not supervise ForemanServer.MCP for #{inspect(mcp_env)}"

    start_supervised!(spec)
  end

  # One JSON-RPC message over `POST /mcp`, as an MCP client sends it.
  defp rpc(body, opts \\ []) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> put_req_header("mcp-protocol-version", @protocol_version)

    conn =
      case Keyword.fetch(opts, :token) do
        {:ok, nil} -> conn
        {:ok, token} -> put_req_header(conn, "authorization", "Bearer " <> token)
        :error -> put_req_header(conn, "authorization", "Bearer " <> @token)
      end

    conn =
      case Keyword.fetch(opts, :session) do
        {:ok, session} -> put_req_header(conn, "mcp-session-id", session)
        :error -> conn
      end

    post(conn, "/mcp", Jason.encode!(body))
  end

  defp initialize do
    conn =
      rpc(%{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: @protocol_version,
          capabilities: %{},
          clientInfo: %{name: "mcp-http-boot-test", version: "1"}
        }
      })

    assert conn.status == 200, "initialize answered HTTP #{conn.status}: #{conn.resp_body}"
    assert [session] = get_resp_header(conn, "mcp-session-id")

    notified = rpc(%{jsonrpc: "2.0", method: "notifications/initialized"}, session: session)
    assert notified.status == 202

    {session, Jason.decode!(conn.resp_body)}
  end

  describe "a boot that is not `mix phx.server` (live harnesses, releases)" do
    setup do
      assert Application.get_env(:phoenix, :serve_endpoints) == false
      refute System.get_env("PHX_SERVER")
      refute System.get_env("ANUBIS_MCP_SERVER")
      :ok
    end

    test "the supervisor starts and writes the session config the transport plug reads" do
      boot_mcp!(@dev_mcp)

      assert %{registry_mod: registry_mod} = :persistent_term.get(@session_config_key)
      assert registry_mod == Anubis.Server.Registry.Local

      assert is_pid(Process.whereis(Anubis.Server.Registry.supervisor_name(MCP))),
             "the Anubis supervisor of ForemanServer.MCP is not running"
    end

    test "POST /mcp initialize answers 200 with the server info and a session id" do
      boot_mcp!(@dev_mcp)

      {session, %{"jsonrpc" => "2.0", "id" => 1, "result" => result}} = initialize()

      assert is_binary(session) and session != ""
      assert result["serverInfo"]["name"] == "foreman-mcp"
      assert result["protocolVersion"] == @protocol_version
    end

    test "tools/list advertises the multi-repo write tools agents call" do
      boot_mcp!(@dev_mcp)
      {session, _} = initialize()

      conn = rpc(%{jsonrpc: "2.0", id: 2, method: "tools/list", params: %{}}, session: session)

      assert conn.status == 200
      names = for tool <- Jason.decode!(conn.resp_body)["result"]["tools"], do: tool["name"]
      assert "foreman_run_request_repo" in names
      assert "foreman_task_fanout" in names
      assert "foreman_project_list" in names
    end

    test "tools/call reaches a tool through the real transport and returns its JSON" do
      boot_mcp!(@dev_mcp)
      {session, _} = initialize()

      conn =
        rpc(
          %{
            jsonrpc: "2.0",
            id: 3,
            method: "tools/call",
            params: %{name: "foreman_project_list", arguments: %{}}
          },
          session: session
        )

      assert conn.status == 200

      assert %{"result" => %{"content" => [%{"type" => "text", "text" => text}]} = result} =
               Jason.decode!(conn.resp_body)

      refute result["isError"]
      assert is_list(Jason.decode!(text))
    end
  end

  describe "a token-protected config (allow_insecure_local: false)" do
    @secured_mcp [
      enabled: true,
      mount: "/mcp",
      allow_workflow_writes: true,
      allow_insecure_local: false
    ]

    test "boots, refuses a request without the token and serves one that carries it" do
      boot_mcp!(@secured_mcp)

      refused =
        rpc(%{jsonrpc: "2.0", id: 1, method: "initialize", params: %{}}, token: nil)

      assert refused.status == 401
      assert Jason.decode!(refused.resp_body) == %{"error" => "unauthorized"}

      wrong =
        rpc(%{jsonrpc: "2.0", id: 1, method: "initialize", params: %{}}, token: "not-the-token")

      assert wrong.status == 401

      {_session, %{"result" => result}} = initialize()
      assert result["serverInfo"]["name"] == "foreman-mcp"
    end
  end

  describe "child spec" do
    test "Anubis' OAuth :authorization option is never passed (Foreman gates with its own Plug and dispatch)" do
      for insecure_local <- [true, false] do
        Application.put_env(:foreman_server, :mcp,
          enabled: true,
          allow_insecure_local: insecure_local
        )

        for module <- [MCP, MCP.Stdio] do
          %{start: {Anubis.Server.Supervisor, :start_link, [^module, opts]}} =
            module.child_spec([])

          refute Keyword.has_key?(opts, :authorization)
        end
      end
    end
  end
end
