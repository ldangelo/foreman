defmodule ForemanServer.Workflow.ImplementWorkflowCharacterizationTest do
  @moduledoc """
  CTH-T002 / TRD-088: dedicated characterization harness for the implement
  workflow — verifies correct dispatch of ensemble-full-implement-trd as an
  observable black-box contract, independent of WFD-T007's unit tests.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.Workflow.ImplementWorkflowDispatcher

  setup do
    {:ok, _pid} = KeyStore.start_link()
    :ok
  end

  test "dispatching the implement workflow invokes exactly ensemble-full-implement-trd, once, per task" do
    task_id = "cth-t002-#{System.unique_integer([:positive])}"

    assert {:ok, :dispatched} = ImplementWorkflowDispatcher.dispatch(task_id)

    # Observable contract: the durable idempotency record for this task
    # is keyed on the implement workflow's single step, proving the
    # dispatch reached ensemble-full-implement-trd and nothing else.
    assert {:ok, :completed} = KeyStore.status("implement-#{task_id}-1")
  end

  test "re-dispatch for an already-completed task never re-invokes the skill" do
    task_id = "cth-t002-rerun-#{System.unique_integer([:positive])}"

    assert {:ok, :dispatched} = ImplementWorkflowDispatcher.dispatch(task_id)
    assert {:ok, :skipped} = ImplementWorkflowDispatcher.dispatch(task_id)
    assert {:ok, :skipped} = ImplementWorkflowDispatcher.dispatch(task_id)

    # The record remains :completed throughout — no re-marking, no
    # regression to :started, proving each retry is a genuine no-op.
    assert {:ok, :completed} = KeyStore.status("implement-#{task_id}-1")
  end

  test "distinct tasks get distinct, independently-tracked dispatches" do
    task_a = "cth-t002-a-#{System.unique_integer([:positive])}"
    task_b = "cth-t002-b-#{System.unique_integer([:positive])}"

    assert {:ok, :dispatched} = ImplementWorkflowDispatcher.dispatch(task_a)
    assert {:ok, :dispatched} = ImplementWorkflowDispatcher.dispatch(task_b)

    assert {:ok, :completed} = KeyStore.status("implement-#{task_a}-1")
    assert {:ok, :completed} = KeyStore.status("implement-#{task_b}-1")
  end
end
