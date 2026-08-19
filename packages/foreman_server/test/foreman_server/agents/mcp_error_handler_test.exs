defmodule ForemanServer.Agents.McpErrorHandlerTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Agents.McpErrorHandler

  test "timeout is recoverable" do
    assert {:recoverable, :retry} = McpErrorHandler.classify(:timeout)
  end

  test "connection_lost is recoverable" do
    assert {:recoverable, :retry} = McpErrorHandler.classify(:connection_lost)
  end

  test "rate_limited is recoverable" do
    assert {:recoverable, :retry} = McpErrorHandler.classify(:rate_limited)
  end

  test "auth_failed is non-recoverable" do
    assert {:non_recoverable, :escalate} = McpErrorHandler.classify(:auth_failed)
  end

  test "permission_denied is non-recoverable" do
    assert {:non_recoverable, :escalate} = McpErrorHandler.classify(:permission_denied)
  end

  test "handle emits retry directive for recoverable" do
    assert {:retry, d} = McpErrorHandler.handle(:timeout, %{e: "ep"})
    assert d.action == :retry
    assert d.kind == :timeout
    assert d.context == %{e: "ep"}
    assert is_integer(d.emitted_at)
  end

  test "handle emits escalate directive for non-recoverable" do
    assert {:escalate, d2} = McpErrorHandler.handle(:permission_denied, %{e: "ep"})
    assert d2.action == :escalate
    assert d2.kind == :permission_denied
  end

  test "handle emits log directive for unknown kind" do
    assert {:log, d3} = McpErrorHandler.handle(:something_weird)
    assert d3.action == :log
  end
end