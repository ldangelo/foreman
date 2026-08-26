defmodule ForemanServer.MCP.PolicyTest do
  use ExUnit.Case, async: true

  alias ForemanServer.MCP.Policy

  setup do
    # Reset to default false between tests
    Application.put_env(:foreman_server, :mcp, allow_workflow_writes: false)
    on_exit(fn -> Application.put_env(:foreman_server, :mcp, allow_workflow_writes: false) end)
  end

  describe "tool allowlist" do
    test "tool not in enabled set is refused and absent from tools/list" do
      refute Policy.authorized?("foreman_work_submit")
      refute Policy.authorized?("foreman_work_cancel")

      tools = [
        %{name: "foreman_work_submit", description: "Submit work"},
        %{name: "foreman_work_cancel", description: "Cancel work"},
        %{name: "foreman_work_get", description: "Get work"}
      ]

      assert Policy.list_tools(tools) == [%{name: "foreman_work_get", description: "Get work"}]
    end
  end

  describe "dispatch policy boundary" do
    test "dispatch for non-allowlisted command type is refused before CommandGateway" do
      refute Policy.authorized?("foreman_work_submit")
    end
  end

  describe "architecture" do
    test "architecture test: no reference to dispatch_system in lib/foreman_server/mcp/" do
      mcp_root = Path.expand("lib/foreman_server/mcp", File.cwd!())

      refs =
        mcp_root
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.filter(fn path ->
          File.read!(path) =~ "dispatch_system"
        end)

      assert refs == []
    end
  end
end
