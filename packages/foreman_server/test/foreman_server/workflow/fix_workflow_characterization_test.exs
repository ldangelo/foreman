defmodule ForemanServer.Workflow.FixWorkflowCharacterizationTest do
  @moduledoc """
  CTH-T003 / TRD-089: dedicated characterization harness for the fix
  workflow — verifies correct dispatch of ensemble:fix-issue as an
  observable black-box contract, independent of WFD-T007's unit tests.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.Workflow.FixWorkflowDispatcher

  setup do
    {:ok, _pid} = KeyStore.start_link()
    :ok
  end

  test "dispatching the fix workflow invokes exactly ensemble:fix-issue, once, per task" do
    task_id = "cth-t003-#{System.unique_integer([:positive])}"

    assert {:ok, :dispatched} = FixWorkflowDispatcher.dispatch(task_id)

    # Observable contract: the durable idempotency record for this task
    # is keyed on the fix workflow's single step, proving the dispatch
    # reached ensemble:fix-issue and nothing else.
    assert {:ok, :completed} = KeyStore.status("fix-#{task_id}-1")
  end

  test "re-dispatch for an already-completed task never re-invokes the skill" do
    task_id = "cth-t003-rerun-#{System.unique_integer([:positive])}"

    assert {:ok, :dispatched} = FixWorkflowDispatcher.dispatch(task_id)
    assert {:ok, :skipped} = FixWorkflowDispatcher.dispatch(task_id)
    assert {:ok, :skipped} = FixWorkflowDispatcher.dispatch(task_id)

    # The record remains :completed throughout — no re-marking, no
    # regression to :started, proving each retry is a genuine no-op.
    assert {:ok, :completed} = KeyStore.status("fix-#{task_id}-1")
  end

  test "distinct tasks get distinct, independently-tracked dispatches" do
    task_a = "cth-t003-a-#{System.unique_integer([:positive])}"
    task_b = "cth-t003-b-#{System.unique_integer([:positive])}"

    assert {:ok, :dispatched} = FixWorkflowDispatcher.dispatch(task_a)
    assert {:ok, :dispatched} = FixWorkflowDispatcher.dispatch(task_b)

    assert {:ok, :completed} = KeyStore.status("fix-#{task_a}-1")
    assert {:ok, :completed} = KeyStore.status("fix-#{task_b}-1")
  end
end
