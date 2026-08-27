defmodule ForemanServer.MCP.ToolsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Tools
  alias ForemanServer.MCP.ToolError
  alias ForemanServer.ProjectionStore

  setup do
    # Capture current state to restore on exit
    original_state = :sys.get_state(ProjectionStore)

    on_exit(fn ->
      :sys.replace_state(ProjectionStore, fn _ -> original_state end)
    end)

    :ok
  end

  defp replace_state(overrides) do
    base = %{
      projects: %{},
      runs: %{},
      tasks: %{},
      phases: %{},
      pr_associations: %{},
      scheduler_intents: %{},
      subscribers: %{},
      project_active_runs: %{},
      worktrees: %{},
      worktree_create_orphans: %{},
      run_slots: %{capacity: 0, holders: %{}, waiters: []},
      works: %{}
    }

    :sys.replace_state(ProjectionStore, fn _ -> Map.merge(base, overrides) end)
  end

  describe "tools/list" do
    test "advertises required tools with valid JSON Schemas" do
      tools = Tools.list_tools()

      assert Enum.map(tools, & &1.name) == [
               "foreman_work_get",
               "foreman_run_get",
               "foreman_queue_status",
               "foreman_project_list",
               "foreman_project_get",
               "foreman_workflow_list",
               "foreman_workflow_get",
               "foreman_workflow_validate",
               "foreman_work_submit",
               "foreman_work_cancel",
               "foreman_workflow_put",
               "foreman_workflow_delete",
               "foreman_prompt_put",
               "foreman_prompt_get",
               "foreman_doctor",
               "foreman_run_get_logs",
               "foreman_run_get_events",
               "foreman_run_get_activity"
             ]

      Enum.each(tools, fn tool ->
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert tool.inputSchema.type == "object"
        assert is_map(tool.inputSchema.properties)

        if Map.has_key?(tool.inputSchema, :required) do
          assert is_list(tool.inputSchema.required)
        end
      end)
    end
  end

  describe "foreman_work_get" do
    test "returns work when found" do
      work = %{work_id: "work-1", status: "submitted"}
      replace_state(%{works: %{"work-1" => work}})

      assert Tools.call_tool("foreman_work_get", %{work_id: "work-1"}) == {:ok, work}
    end

    test "returns NOT_FOUND when not found" do
      replace_state(%{works: %{}})

      assert Tools.call_tool("foreman_work_get", %{work_id: "nonexistent"}) ==
               {:error, %ToolError{code: "NOT_FOUND", message: "Work not found"}}
    end
  end

  describe "foreman_run_get" do
    test "returns run when found" do
      run = %{run_id: "run-1", status: "in_progress"}
      replace_state(%{runs: %{"run-1" => run}})

      assert Tools.call_tool("foreman_run_get", %{run_id: "run-1"}) == {:ok, run}
    end

    test "returns NOT_FOUND when not found" do
      replace_state(%{runs: %{}})

      assert Tools.call_tool("foreman_run_get", %{run_id: "nonexistent"}) ==
               {:error, %ToolError{code: "NOT_FOUND", message: "Run not found"}}
    end
  end

  describe "foreman_queue_status" do
    test "returns queue status" do
      replace_state(%{})

      assert Tools.call_tool("foreman_queue_status", %{}) ==
               {:ok, ProjectionStore.queue_status()}
    end
  end

  describe "foreman_project_list" do
    test "returns projects list" do
      replace_state(%{})

      assert Tools.call_tool("foreman_project_list", %{}) ==
               {:ok, ProjectionStore.list_projects()}
    end
  end

  describe "foreman_project_get" do
    test "returns project when found" do
      project = %{project_id: "proj-1", name: "Test Project"}
      replace_state(%{projects: %{"proj-1" => project}})

      assert Tools.call_tool("foreman_project_get", %{project_id: "proj-1"}) == {:ok, project}
    end

    test "returns NOT_FOUND when not found" do
      replace_state(%{projects: %{}})

      assert Tools.call_tool("foreman_project_get", %{project_id: "nonexistent"}) ==
               {:error, %ToolError{code: "NOT_FOUND", message: "Project not found"}}
    end
  end

  describe "dispatch error taxonomy" do
    # A single catch-all used to report all three of these as
    # METHOD_NOT_FOUND "Unknown tool", which made argument-shape bugs
    # extremely expensive to diagnose. They are now distinct.
    #
    # Note there is no test for "advertised tool with no implementation":
    # `call_tool/2` is generated from `@tools`, so that case cannot compile.

    test "an unknown tool name is METHOD_NOT_FOUND" do
      assert Tools.call_tool("unknown_tool", %{}) ==
               {:error,
                %ToolError{code: "METHOD_NOT_FOUND", message: "Unknown tool: unknown_tool"}}
    end

    test "a known tool missing a required argument is INVALID_PARAMS, naming the key" do
      assert {:error, %ToolError{code: "INVALID_PARAMS", message: message}} =
               Tools.call_tool("foreman_run_get", %{})

      assert message =~ "foreman_run_get"
      assert message =~ "run_id"
    end

    test "string-keyed arguments raise rather than masquerading as an unknown tool" do
      assert_raise ArgumentError, ~r/string-keyed arguments/, fn ->
        Tools.call_tool("foreman_run_get", %{"run_id" => "r-1"})
      end
    end
  end
end
