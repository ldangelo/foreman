defmodule ForemanServer.MCP.ThreadSteerToolTest do
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

  test "foreman_thread_steer is a write tool: hidden and refused under read-only policy" do
    Application.put_env(:foreman_server, :mcp, allow_workflow_writes: false)
    names = Tools.list_tools() |> Policy.list_tools() |> Enum.map(& &1.name)
    refute "foreman_thread_steer" in names
    refute Policy.authorized?("foreman_thread_steer")

    Application.put_env(:foreman_server, :mcp, allow_workflow_writes: true)
    names = Tools.list_tools() |> Policy.list_tools() |> Enum.map(& &1.name)
    assert "foreman_thread_steer" in names
    assert Policy.authorized?("foreman_thread_steer")
  end

  test "unknown thread is NOT_FOUND, a run the aggregate rejects is DOMAIN_ERROR" do
    assert {:error, %ToolError{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_thread_steer", %{thread_id: "run:nope", text: "hi"})

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: %{run_id: "done", project_id: "p"}},
        %{event_type: "RunCompleted", payload: %{run_id: "done", project_id: "p"}}
      ])

    assert {:error, %ToolError{code: "DOMAIN_ERROR"}} =
             Tools.call_tool("foreman_thread_steer", %{thread_id: "run:done", text: "hi"})
  end

  test "blank text and non-boolean resume are INVALID_PARAMS" do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: %{run_id: "live", project_id: "p"}}
      ])

    assert {:error, %ToolError{code: "INVALID_PARAMS"}} =
             Tools.call_tool("foreman_thread_steer", %{thread_id: "run:live", text: " "})

    assert {:error, %ToolError{code: "INVALID_PARAMS"}} =
             Tools.call_tool("foreman_thread_steer", %{
               thread_id: "run:live",
               text: "x",
               resume: "no"
             })
  end
end
