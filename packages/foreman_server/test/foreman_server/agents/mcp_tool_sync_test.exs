defmodule ForemanServer.Agents.McpToolSyncTest do
  use ExUnit.Case, async: false

  test "sync and tools_for" do
    {:ok, _pid} = ForemanServer.Agents.McpToolSync.start_link()
    assert :ok = ForemanServer.Agents.McpToolSync.sync(["test-server"])
    assert [] = ForemanServer.Agents.McpToolSync.tools_for("test-server")
  end

  test "all_tools returns cache" do
    {:ok, _pid} = ForemanServer.Agents.McpToolSync.start_link()
    assert %{} = ForemanServer.Agents.McpToolSync.all_tools()
  end
end
