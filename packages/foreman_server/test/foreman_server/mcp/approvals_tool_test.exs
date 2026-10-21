defmodule ForemanServer.MCP.ApprovalsToolTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.{Policy, ToolError, Tools}
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

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

  test "returns the same DTOs as the HTTP endpoint for a project and for a run" do
    assert {:ok, %{"approvals" => [call]}} =
             Tools.call_tool("foreman_approvals_list", %{project_id: "mp"})

    assert call["tool_call_id"] == "c1"
    assert call["actions"] == ["tool.approve", "tool.deny"]

    assert {:ok, %{"approvals" => [^call]}} =
             Tools.call_tool("foreman_approvals_list", %{run_id: "mr1"})
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
