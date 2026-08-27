defmodule ForemanServer.MCP.ToolsTest do
  use ExUnit.Case, async: true

  alias ForemanServer.MCP.Tools

  describe "MCP tools exposed" do
    test "all 18 default tools registered" do
      names = Tools.list_tools() |> Enum.map(& &1[:name]) |> Enum.sort()
      expected = ~w(
        foreman_doctor
        foreman_project_get
        foreman_project_list
        foreman_prompt_get
        foreman_prompt_put
        foreman_queue_status
        foreman_run_get
        foreman_run_get_activity
        foreman_run_get_events
        foreman_run_get_logs
        foreman_work_cancel
        foreman_work_get
        foreman_work_submit
        foreman_workflow_delete
        foreman_workflow_get
        foreman_workflow_list
        foreman_workflow_put
        foreman_workflow_validate
      ) |> Enum.sort()
      assert names == expected
    end

    test "new run tools return valid responses" do
      assert {:ok, []} = Tools.call_tool("foreman_run_get_logs", %{run_id: "nonexistent"})
      assert {:ok, []} = Tools.call_tool("foreman_run_get_events", %{run_id: "nonexistent"})
      assert {:ok, []} = Tools.call_tool("foreman_run_get_activity", %{run_id: "nonexistent"})
    end
  end
end
