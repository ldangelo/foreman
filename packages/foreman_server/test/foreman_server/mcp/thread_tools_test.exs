defmodule ForemanServer.MCP.ThreadToolsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Policy
  alias ForemanServer.MCP.ToolError
  alias ForemanServer.MCP.Tools
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunStarted",
          payload: %{run_id: "r1", task_id: "t1", project_id: "p"}
        },
        %{
          event_type: "JobsiteStarted",
          payload: %{jobsite_id: "j1", repo_path: "/r", strategy: "worktree", project_id: "p"}
        }
      ])

    :ok
  end

  test "both thread tools survive the read-only policy listing and are not write tools" do
    names = Tools.list_tools() |> Policy.list_tools() |> Enum.map(& &1.name)
    assert "foreman_thread_list" in names
    assert "foreman_thread_get" in names
    assert Policy.authorized?("foreman_thread_list")
    assert Policy.authorized?("foreman_thread_get")
  end

  test "list returns the same ids and keys as HTTP's DTO" do
    assert {:ok, dtos} = Tools.call_tool("foreman_thread_list", %{project_id: "p"})
    assert dtos |> Enum.map(& &1["id"]) |> Enum.sort() == ["jobsite:j1", "run:r1"]
    assert Enum.all?(dtos, &(&1["steering"] == "pause_resume" and &1["resolved"] == false))
    assert Enum.all?(dtos, &Enum.all?(Map.keys(&1), fn k -> is_binary(k) end))

    assert {:ok, [%{"id" => "jobsite:j1"}]} =
             Tools.call_tool("foreman_thread_list", %{project_id: "p", door: "jobsite"})
  end

  test "bad arguments are INVALID_PARAMS" do
    for args <- [
          %{project_id: "p", limit: 0},
          %{project_id: "p", limit: 501},
          %{project_id: "p", limit: "x"},
          %{project_id: "p", door: "nope"},
          %{project_id: ""}
        ] do
      assert {:error, %ToolError{code: "INVALID_PARAMS"}} =
               Tools.call_tool("foreman_thread_list", args)
    end
  end

  test "get returns the DTO; unknown id is NOT_FOUND" do
    assert {:ok, %{"id" => "run:r1", "door" => "workflow"}} =
             Tools.call_tool("foreman_thread_get", %{thread_id: "run:r1"})

    assert {:error, %ToolError{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_thread_get", %{thread_id: "run:zzz"})
  end
end
