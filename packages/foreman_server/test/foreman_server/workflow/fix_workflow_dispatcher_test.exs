defmodule ForemanServer.Workflow.FixWorkflowDispatcherTest do
  use ExUnit.Case, async: false
  test "dispatch records idempotency" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    assert {:ok, :dispatched} = ForemanServer.Workflow.FixWorkflowDispatcher.dispatch("task-1")
  end
end
