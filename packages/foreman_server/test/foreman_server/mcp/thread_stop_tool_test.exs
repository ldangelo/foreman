defmodule ForemanServer.MCP.ThreadStopToolTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Policy
  alias ForemanServer.MCP.ToolError
  alias ForemanServer.MCP.Tools
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    previous = Application.get_env(:foreman_server, :mcp)

    on_exit(fn ->
      ProjectionStoreReset.reset!()
      Application.put_env(:foreman_server, :mcp, previous)
    end)

    :ok
  end

  test "foreman_thread_stop is a write tool: hidden and refused under read-only policy" do
    Application.put_env(:foreman_server, :mcp, allow_workflow_writes: false)
    names = Tools.list_tools() |> Policy.list_tools() |> Enum.map(& &1.name)
    refute "foreman_thread_stop" in names
    refute Policy.authorized?("foreman_thread_stop")

    Application.put_env(:foreman_server, :mcp, allow_workflow_writes: true)
    names = Tools.list_tools() |> Policy.list_tools() |> Enum.map(& &1.name)
    assert "foreman_thread_stop" in names
    assert Policy.authorized?("foreman_thread_stop")
  end

  test "unknown thread is NOT_FOUND, terminal thread is a DOMAIN_ERROR naming the status" do
    assert {:error, %ToolError{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_thread_stop", %{thread_id: "run:nope"})

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: %{run_id: "done", project_id: "p"}},
        %{event_type: "RunCompleted", payload: %{run_id: "done", project_id: "p"}}
      ])

    assert {:error, %ToolError{code: "DOMAIN_ERROR", message: message}} =
             Tools.call_tool("foreman_thread_stop", %{thread_id: "run:done"})

    assert message =~ "not_stoppable" and message =~ "completed"
  end

  test "non-string reason is INVALID_PARAMS" do
    assert {:error, %ToolError{code: "INVALID_PARAMS"}} =
             Tools.call_tool("foreman_thread_stop", %{thread_id: "run:x", reason: 5})
  end
end
