defmodule ForemanServer.MCP.ApprovalsToolTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Anubis.Server.{Frame, Response}
  alias ForemanServer.Approvals.{DTO, Listing}
  alias ForemanServer.MCP
  alias ForemanServer.MCP.{Policy, ToolError, Tools}
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: "mp", path: "/tmp/mp", task_provider: %{type: "beads"}}
        },
        %{event_type: "RunStarted", payload: %{run_id: "mr1", task_id: "t", project_id: "mp"}},
        %{
          event_type: "ToolCallRequested",
          payload: %{
            run_id: "mr1",
            tool_call_id: "c1",
            tool_name: "Bash",
            requested_at: "2026-10-21T00:01:00Z"
          }
        }
      ])

    :ok
  end

  test "foreman_approvals_list is a read tool, authorized under the read-only policy" do
    assert "foreman_approvals_list" in (Tools.list_tools()
                                        |> Policy.list_tools()
                                        |> Enum.map(& &1.name))

    assert Policy.authorized?("foreman_approvals_list")
  end

  test "returns a typed Listing of the same DTOs as the HTTP endpoint, for a project and for a run" do
    assert {:ok, %Listing{approvals: [%DTO{} = call]}} =
             Tools.call_tool("foreman_approvals_list", %{project_id: "mp"})

    assert call.tool_call_id == "c1"
    assert call.actions == ["tool.approve", "tool.deny"]

    assert {:ok, %Listing{approvals: [^call]}} =
             Tools.call_tool("foreman_approvals_list", %{run_id: "mr1"})
  end

  test "the listing enforces its key, so a payload without approvals cannot be built" do
    assert_raise ArgumentError, ~r/approvals/, fn -> struct!(Listing, []) end
  end

  test "the wire payload of the real MCP tool call equals the HTTP endpoint's body" do
    mcp = Application.get_env(:foreman_server, :mcp, [])
    token = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :mcp, Keyword.put(mcp, :allow_insecure_local, true))

    on_exit(fn ->
      Application.put_env(:foreman_server, :mcp, mcp)

      if token == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, token)
    end)

    # Anubis's `validate_input` only renames keys; `handle_tool_call` is the real dispatch
    # (auth, policy, `Jason.encode!` of the result).
    tool = Enum.find(MCP.__components__(:tool), &(&1.name == "foreman_approvals_list"))
    {:ok, args} = tool.validate_input.(%{"project_id" => "mp"})

    assert {:reply, %Response{} = response, _frame} =
             MCP.handle_tool_call("foreman_approvals_list", args, Frame.new())

    assert %{"content" => [%{"text" => text}], "isError" => false} =
             Response.to_protocol(response)

    wire = Jason.decode!(text)

    assert %{
             "approvals" => [
               %{"tool_call_id" => "c1", "run_id" => "mr1", "status" => "requested"} = entry
             ]
           } = wire

    # the wire names are the struct field names, unchanged by the typed result
    assert entry |> Map.keys() |> Enum.sort() ==
             Enum.sort(~w(tool_call_id run_id project_id tool_name input_summary status
                          requested_at decided_at decided_by reason outcome approval_delivery
                          actions command_hints))

    Application.put_env(:foreman_server, :api_bearer_token, "approvals-tool-test")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer approvals-tool-test")
      |> get("/api/projects/mp/approvals")

    assert json_response(conn, 200) == wire
  end

  test "unknown ids are NOT_FOUND; bad arguments are INVALID_PARAMS" do
    assert {:error, %ToolError{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_approvals_list", %{project_id: "nope"})

    assert {:error, %ToolError{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_approvals_list", %{run_id: "nope"})

    for args <- [%{}, %{project_id: "mp", run_id: "mr1"}, %{project_id: "mp", status: "x"}] do
      assert {:error, %ToolError{code: "INVALID_PARAMS"}} =
               Tools.call_tool("foreman_approvals_list", args)
    end
  end
end
