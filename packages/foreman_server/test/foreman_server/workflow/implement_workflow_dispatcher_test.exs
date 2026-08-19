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
  test "dispatches the correct skill with the correct idempotency key" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    task_id = "task-skill-check"
    assert {:ok, :dispatched} = ForemanServer.Workflow.ImplementWorkflowDispatcher.dispatch(task_id)
    assert {:ok, :completed} = ForemanServer.Idempotency.KeyStore.status("implement-#{task_id}-1")
  end

  test "no bypass: repeated dispatch never re-runs the skill for a completed key" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    task_id = "task-no-bypass"
    assert {:ok, :dispatched} = ForemanServer.Workflow.ImplementWorkflowDispatcher.dispatch(task_id)
    assert {:ok, :skipped} = ForemanServer.Workflow.ImplementWorkflowDispatcher.dispatch(task_id)
    assert {:ok, :skipped} = ForemanServer.Workflow.ImplementWorkflowDispatcher.dispatch(task_id)
  end
end
