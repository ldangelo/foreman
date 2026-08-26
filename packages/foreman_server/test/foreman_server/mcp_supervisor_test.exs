defmodule ForemanServer.MCPSupervisorTest do
  use ExUnit.Case, async: false

  describe "MCP config" do
    test "has expected keys with correct defaults" do
      mcp_config = Application.get_env(:foreman_server, :mcp)

      assert mcp_config[:enabled] == false
      assert mcp_config[:mount] == "/mcp"
      assert mcp_config[:allow_workflow_writes] == false
      assert mcp_config[:allow_insecure_local] == false
    end

    test "config is a keyword list" do
      mcp_config = Application.get_env(:foreman_server, :mcp)
      assert is_list(mcp_config)
    end
  end

  describe "ForemanServer.MCP" do
    test "has a child_spec function" do
      Code.ensure_loaded(ForemanServer.MCP)
      assert function_exported?(ForemanServer.MCP, :child_spec, 1)
    end

    test "child_spec returns a valid supervisor child map" do
      spec = ForemanServer.MCP.child_spec([])
      assert spec[:id] == ForemanServer.MCP
      assert spec[:type] == :supervisor
      assert is_tuple(spec[:start])
    end
  end

  describe "mcp_child_spec/0" do
    test "returns empty list when enabled is false" do
      # Ensure config is disabled
      Application.put_env(:foreman_server, :mcp, enabled: false)

      on_exit(fn ->
        Application.put_env(:foreman_server, :mcp,
          enabled: false,
          mount: "/mcp",
          allow_workflow_writes: false,
          allow_insecure_local: false
        )
      end)

      assert ForemanServer.MCP.mcp_child_spec() == []
    end

    test "returns MCP child spec when enabled is true" do
      # Enable MCP for this test
      Application.put_env(:foreman_server, :mcp, enabled: true)

      on_exit(fn ->
        Application.put_env(:foreman_server, :mcp,
          enabled: false,
          mount: "/mcp",
          allow_workflow_writes: false,
          allow_insecure_local: false
        )
      end)

      assert ForemanServer.MCP.mcp_child_spec() == [ForemanServer.MCP.child_spec([])]
    end
  end

  describe "supervisor integration" do
    test "Anubis.Server module is available" do
      # Code.ensure_loaded? returns true if already loaded, {:module, module} if just loaded,
      # or {:error, reason} if it couldn't be loaded
      result = Code.ensure_loaded?(Anubis.Server)
      assert result == true or match?({:module, Anubis.Server}, result)
    end
  end
end
