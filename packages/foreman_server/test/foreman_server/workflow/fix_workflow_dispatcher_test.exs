defmodule ForemanServer.Workflow.FixWorkflowDispatcherTest do
  use ExUnit.Case, async: false
  test "dispatch records idempotency" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    assert {:ok, :dispatched} = ForemanServer.Workflow.FixWorkflowDispatcher.dispatch("task-1")
  end
  test "dispatches the correct skill with the correct idempotency key" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    task_id = "task-skill-check"
    assert {:ok, :dispatched} = ForemanServer.Workflow.FixWorkflowDispatcher.dispatch(task_id)
    assert {:ok, :completed} = ForemanServer.Idempotency.KeyStore.status("fix-#{task_id}-1")
  end

  test "no bypass: repeated dispatch never re-runs the skill for a completed key" do
    {:ok, _pid} = ForemanServer.Idempotency.KeyStore.start_link()
    task_id = "task-no-bypass"
    assert {:ok, :dispatched} = ForemanServer.Workflow.FixWorkflowDispatcher.dispatch(task_id)
    assert {:ok, :skipped} = ForemanServer.Workflow.FixWorkflowDispatcher.dispatch(task_id)
    assert {:ok, :skipped} = ForemanServer.Workflow.FixWorkflowDispatcher.dispatch(task_id)
  end
end
