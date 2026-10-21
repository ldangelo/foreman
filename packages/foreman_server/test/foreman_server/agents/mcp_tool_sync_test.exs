defmodule ForemanServer.Agents.McpToolSyncTest do
  use ExUnit.Case, async: false

  test "sync and tools_for" do
    start_supervised!(ForemanServer.Agents.McpToolSync)
    start_supervised!(ForemanServer.Agents.McpClientPool)
    assert :ok = ForemanServer.Agents.McpToolSync.sync(["test-server"])
    assert [] = ForemanServer.Agents.McpToolSync.tools_for("test-server")
  end

  test "all_tools returns cache" do
    start_supervised!(ForemanServer.Agents.McpToolSync)
    assert %{} = ForemanServer.Agents.McpToolSync.all_tools()
  end
end
