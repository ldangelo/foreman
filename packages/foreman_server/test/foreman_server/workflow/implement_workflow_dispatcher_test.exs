defmodule ForemanServer.Workflow.ImplementWorkflowDispatcherTest do
  use ExUnit.Case, async: false
  test "dispatch records idempotency" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    assert {:ok, :dispatched} = ForemanServer.Workflow.ImplementWorkflowDispatcher.dispatch("task-1")
  end
  test "second dispatch is skipped" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    assert {:ok, :dispatched} = ForemanServer.Workflow.ImplementWorkflowDispatcher.dispatch("task-2")
    assert {:ok, :skipped} = ForemanServer.Workflow.ImplementWorkflowDispatcher.dispatch("task-2")
  end
end
