defmodule ForemanServer.MCP.PrToolsTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.CommandGateway
  alias ForemanServer.MCP.{Dispatch, Policy, ToolError, Tools}
  alias ForemanServer.TestSupport.PrSurfaceSupport
  alias ForemanServer.TestSupport.PrWatchSupport

  @endpoint ForemanServerWeb.Endpoint
  @token "pr-tools-token"
  @write_tools ["foreman_pr_fix", "foreman_pr_watch_stop"]

  setup do
    previous_mcp = Application.get_env(:foreman_server, :mcp, [])
    previous_token = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    writes(false)

    on_exit(fn ->
      Application.put_env(:foreman_server, :mcp, previous_mcp)

      if previous_token == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous_token)
    end)

    {:ok, PrSurfaceSupport.seed_two_prs!()}
  end

  defp writes(enabled?) do
    config = Application.get_env(:foreman_server, :mcp, [])

    Application.put_env(
      :foreman_server,
      :mcp,
      Keyword.put(config, :allow_workflow_writes, enabled?)
    )
  end

  defp http_prs(run_id) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> get("/api/runs/#{run_id}/prs")
    |> json_response(200)
  end

  # Replace the gateway's operator path with a recorder; everything else passes through.
  defp record_gateway(reply) do
    test = self()
    {:ok, _} = Application.ensure_all_started(:meck)
    :meck.new(CommandGateway, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(CommandGateway) end)

    :meck.expect(CommandGateway, :dispatch_operator, fn envelope ->
      send(test, {:dispatched, envelope})
      reply
    end)
  end

  test "foreman_pr_status returns exactly what HTTP returns, as a read tool", ctx do
    assert {:ok, body} = Tools.call_tool("foreman_pr_status", %{run_id: ctx.run_id})
    assert body |> Jason.encode!() |> Jason.decode!() == http_prs(ctx.run_id)
    assert length(body.prs) == 2

    assert {:error, %ToolError{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_pr_status", %{run_id: "run-nope"})

    assert "foreman_pr_status" in tool_names()
  end

  defp tool_names, do: Enum.map(Dispatch.components(), & &1.name)

  describe "writes disallowed (default policy)" do
    test "the write tools are hidden and refused", ctx do
      for tool <- @write_tools do
        refute tool in tool_names()
        refute Policy.authorized?(tool)
      end

      assert "foreman_pr_status" in tool_names()

      record_gateway({:ok, nil})

      assert {:error, %ToolError{code: "WRITE_NOT_ALLOWED"}} =
               Tools.call_tool("foreman_pr_fix", %{run_id: ctx.run_id, kind: "ci"})

      assert {:error, %ToolError{code: "WRITE_NOT_ALLOWED"}} =
               Tools.call_tool("foreman_pr_watch_stop", %{run_id: ctx.run_id})

      refute_received {:dispatched, _}
    end
  end

  describe "writes allowed" do
    setup do
      writes(true)
      :ok
    end

    test "the write tools are listed", _ctx do
      for tool <- @write_tools, do: assert(tool in tool_names())
    end

    test "foreman_pr_fix kind ci dispatches run.pr.fix_ci with the coordinator trigger", ctx do
      record_gateway({:ok, nil})

      assert {:ok, %{run_id: run_id, command: "run.pr.fix_ci"}} =
               Tools.call_tool("foreman_pr_fix", %{
                 run_id: ctx.run_id,
                 kind: "ci",
                 pr_url: ctx.failing_url,
                 note: "focus on unit"
               })

      assert run_id == ctx.run_id

      assert_received {:dispatched,
                       %{
                         type: "run.pr.fix_ci",
                         aggregate_id: aggregate_id,
                         payload: %{
                           run_id: ^run_id,
                           pr_url: pr_url,
                           trigger: "coordinator",
                           note: "focus on unit"
                         }
                       }}

      assert aggregate_id == "run:#{ctx.run_id}"
      assert pr_url == ctx.failing_url
    end

    test "each kind maps to its command and a note over 2000 characters is refused", ctx do
      record_gateway({:ok, nil})

      for {kind, type} <- [
            {"comments", "run.pr.address_comments"},
            {"conflicts", "run.pr.resolve_conflicts"}
          ] do
        assert {:ok, %{command: ^type}} =
                 Tools.call_tool("foreman_pr_fix", %{run_id: ctx.run_id, kind: kind})

        assert_received {:dispatched, %{type: ^type}}
      end

      assert {:error, %ToolError{code: "INVALID_PARAMS"}} =
               Tools.call_tool("foreman_pr_fix", %{run_id: ctx.run_id, kind: "bogus"})

      assert {:error, %ToolError{code: "INVALID_PARAMS"}} =
               Tools.call_tool("foreman_pr_fix", %{
                 run_id: ctx.run_id,
                 kind: "ci",
                 note: String.duplicate("x", 2001)
               })

      refute_received {:dispatched, _}
    end

    test "a fix already in flight yields the typed pr_fix_in_flight error", ctx do
      # The seed left a requested CI fix on the failing PR; the real aggregate refuses.
      assert {:error, %ToolError{code: "pr_fix_in_flight", message: message}} =
               Tools.call_tool("foreman_pr_fix", %{
                 run_id: ctx.run_id,
                 kind: "comments",
                 pr_url: ctx.failing_url
               })

      assert message =~ ctx.failing_url

      assert Enum.count(PrWatchSupport.run_event_types(ctx.run_id), &(&1 == "PrFixRequested")) ==
               1
    end

    test "a coordinator fix on an idle failing PR is recorded with its trigger and note" do
      %{run_id: run_id, pr_url: pr_url} = PrWatchSupport.start_run!(complete: true)

      PrWatchSupport.dispatch!(%{
        type: "run.pr.checks",
        command_id: "checks:#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{
          run_id: run_id,
          pr_url: pr_url,
          head_sha: "sha-1",
          digest: "d1",
          checks_state: "failing",
          pr_status: "open"
        }
      })

      assert {:ok, %{command: "run.pr.fix_ci"}} =
               Tools.call_tool("foreman_pr_fix", %{run_id: run_id, kind: "ci", note: "be quick"})

      assert [%{data: data}] =
               run_id
               |> PrWatchSupport.run_events()
               |> Enum.filter(&(&1.event_type == "PrFixRequested"))

      assert %{pr_url: ^pr_url, kind: "ci", attempt: 1, trigger: "coordinator", note: "be quick"} =
               atomize(data)

      assert {:ok, %{prs: [%{fixes: %{in_flight: %{kind: "ci", state: "requested"}}}]}} =
               Tools.call_tool("foreman_pr_status", %{run_id: run_id})
    end

    defp atomize(map), do: Map.new(map, fn {k, v} -> {String.to_existing_atom("#{k}"), v} end)

    test "a merged PR cannot be fixed: typed pr_not_open error", ctx do
      assert {:error, %ToolError{code: "pr_not_open", message: "PR is merged"}} =
               Tools.call_tool("foreman_pr_fix", %{
                 run_id: ctx.run_id,
                 kind: "ci",
                 pr_url: ctx.merged_url
               })
    end

    test "foreman_pr_watch_stop stops watching one PR", ctx do
      assert {:ok, %{command: "run.pr.watch_stop"}} =
               Tools.call_tool("foreman_pr_watch_stop", %{
                 run_id: ctx.run_id,
                 pr_url: ctx.failing_url
               })

      assert {:ok, %{prs: [%{watching: false, stop_reason: "operator"}, %{watching: true}]}} =
               Tools.call_tool("foreman_pr_status", %{run_id: ctx.run_id})
    end

    test "a PR that is not watched is a typed error", ctx do
      assert {:error, %ToolError{code: "pr_not_watched"}} =
               Tools.call_tool("foreman_pr_watch_stop", %{
                 run_id: ctx.run_id,
                 pr_url: "https://github.com/acme/other/pull/9"
               })
    end
  end
end
