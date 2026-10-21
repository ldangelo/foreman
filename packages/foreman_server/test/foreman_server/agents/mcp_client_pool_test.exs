defmodule ForemanServer.Agents.McpClientPoolTest do
  use ExUnit.Case, async: false

  test "register and lookup" do
    start_supervised!(ForemanServer.Agents.McpClientPool)
    assert :ok = ForemanServer.Agents.McpClientPool.register("test-server", %{id: "test-server"})
    assert [] = ForemanServer.Agents.McpClientPool.tools("test-server")
  end

  test "unknown server returns empty" do
    start_supervised!(ForemanServer.Agents.McpClientPool)
    assert [] = ForemanServer.Agents.McpClientPool.tools("unknown")
  end
end
