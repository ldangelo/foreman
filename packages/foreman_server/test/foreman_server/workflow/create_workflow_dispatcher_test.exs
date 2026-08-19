defmodule ForemanServer.Workflow.CreateWorkflowDispatcherTest do
  use ExUnit.Case, async: false

  test "steps are in expected order" do
    steps = ForemanServer.Workflow.CreateWorkflowDispatcher.steps()
    assert length(steps) == 5
    assert {:create_prd, _} = List.first(steps)
    assert {:implement_trd, _} = List.last(steps)
  end

  test "dispatch records each step idempotently" do
    {:ok, _} = ForemanServer.Idempotency.KeyStore.start_link()
    assert {:ok, %{completed: completed}} = ForemanServer.Workflow.CreateWorkflowDispatcher.dispatch("task-test-1")
    assert "create_prd" in completed
    assert "implement_trd" in completed
  end
end
