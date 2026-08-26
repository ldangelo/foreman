defmodule ForemanServer.Agents.McpClientPoolTest do
  use ExUnit.Case, async: false

  test "register and lookup" do
    {:ok, _pid} = ForemanServer.Agents.McpClientPool.start_link()
    assert :ok = ForemanServer.Agents.McpClientPool.register("test-server", %{id: "test-server"})
    assert [] = ForemanServer.Agents.McpClientPool.tools("test-server")
  end

  test "unknown server returns empty" do
    {:ok, _pid} = ForemanServer.Agents.McpClientPool.start_link()
    assert [] = ForemanServer.Agents.McpClientPool.tools("unknown")
  end
end
