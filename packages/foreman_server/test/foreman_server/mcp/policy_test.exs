defmodule ForemanServer.MCP.PolicyTest do
  use ExUnit.Case, async: true

  alias ForemanServer.MCP.Policy

  setup do
    # Reset to default false between tests
    Application.put_env(:foreman_server, :mcp, allow_workflow_writes: false)
    on_exit(fn -> Application.put_env(:foreman_server, :mcp, allow_workflow_writes: false) end)
  end

  describe "authorized?/1" do
    test "returns false for write tools when allow_workflow_writes is false" do
      refute Policy.authorized?("foreman_work_submit")
      refute Policy.authorized?("foreman_work_cancel")
    end

    test "returns true for read tools when allow_workflow_writes is false" do
      assert Policy.authorized?("foreman_work_list")
      assert Policy.authorized?("foreman_work_status")
      assert Policy.authorized?("foreman_run_list")
    end

    test "returns true for all tools when allow_workflow_writes is true" do
      Application.put_env(:foreman_server, :mcp, allow_workflow_writes: true)
      assert Policy.authorized?("foreman_work_submit")
      assert Policy.authorized?("foreman_work_cancel")
      assert Policy.authorized?("foreman_work_list")
    end
  end

  describe "list_tools/1" do
    setup do
      tools = [
        %{name: "foreman_work_submit", description: "Submit work"},
        %{name: "foreman_work_cancel", description: "Cancel work"},
        %{name: "foreman_work_list", description: "List work"},
        %{name: "foreman_work_status", description: "Get work status"}
      ]

      %{tools: tools}
    end

    test "filters write tools when allow_workflow_writes is false", %{tools: tools} do
      result = Policy.list_tools(tools)

      refute Enum.any?(result, fn %{name: name} -> name == "foreman_work_submit" end)
      refute Enum.any?(result, fn %{name: name} -> name == "foreman_work_cancel" end)
      assert Enum.any?(result, fn %{name: name} -> name == "foreman_work_list" end)
      assert Enum.any?(result, fn %{name: name} -> name == "foreman_work_status" end)
    end

    test "keeps all tools when allow_workflow_writes is true", %{tools: tools} do
      Application.put_env(:foreman_server, :mcp, allow_workflow_writes: true)
      result = Policy.list_tools(tools)

      assert length(result) == 4
      assert Enum.any?(result, fn %{name: name} -> name == "foreman_work_submit" end)
      assert Enum.any?(result, fn %{name: name} -> name == "foreman_work_cancel" end)
      assert Enum.any?(result, fn %{name: name} -> name == "foreman_work_list" end)
      assert Enum.any?(result, fn %{name: name} -> name == "foreman_work_status" end)
    end
  end
end
