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
    {:ok, _} = ForemanServer.Workflow.MergeGate.start_link()
    assert {:ok, %{completed: completed}} = ForemanServer.Workflow.CreateWorkflowDispatcher.dispatch("task-test-1")
    assert :create_prd in completed
    assert :implement_trd in completed
  end

  # TRD-067 / WFD-T004: characterization test — correct skill in
  # correct order, output routing, no bypass.
  test "dispatches every skill in the documented order via idempotency-key routing, with no step bypassed" do
    {:ok, _} = ForemanServer.Idempotency.KeyStore.start_link()
    {:ok, _} = ForemanServer.Workflow.MergeGate.start_link()
    task_id = "task-trd-067"

    assert {:ok, %{completed: completed}} =
             ForemanServer.Workflow.CreateWorkflowDispatcher.dispatch(task_id)

    # Correct skill in correct order: exactly the five documented
    # steps, in the exact declared sequence, no reordering.
    assert completed == [:create_prd, :refine_prd, :create_trd, :refine_trd, :implement_trd]

    # Output routing: every step's idempotency key is durably recorded
    # as :completed in the KeyStore under the documented "create-<task_id>-<step>"
    # routing convention (default idempotency_prefix), proving each
    # step's completion signal actually reached the KeyStore rather
    # than being dropped or misrouted.
    for {step, _skill} <- ForemanServer.Workflow.CreateWorkflowDispatcher.steps() do
      key = "create-#{task_id}-#{step}"
      assert {:ok, :completed} = ForemanServer.Idempotency.KeyStore.status(key)
    end

    # No bypass: a step already marked :completed before dispatch is
    # not re-dispatched (idempotent skip), yet still appears in the
    # returned completed list — proving the sequencer neither skips
    # silently nor short-circuits the remaining steps downstream of it.
    task_id_2 = "task-trd-067-partial"
    :ok = ForemanServer.Idempotency.KeyStore.mark_started("create-#{task_id_2}-create_prd")
    :ok = ForemanServer.Idempotency.KeyStore.mark_completed("create-#{task_id_2}-create_prd")

    assert {:ok, %{completed: completed_2}} =
             ForemanServer.Workflow.CreateWorkflowDispatcher.dispatch(task_id_2)

    assert completed_2 == [:create_prd, :refine_prd, :create_trd, :refine_trd, :implement_trd]
  end

  # TRD-074 / MGH-T004: merge gate hold is added to the create workflow.
  # After the workflow's final step, a merge approval is requested and
  # the workflow reports it as pending — it is never auto-approved.
  test "holds for merge gate approval after the workflow completes; never auto-approves" do
    {:ok, _} = ForemanServer.Idempotency.KeyStore.start_link()
    {:ok, _} = ForemanServer.Workflow.MergeGate.start_link()
    task_id = "task-trd-074"
    pr_url = "https://github.com/foo/bar/pull/42"

    assert {:ok, %{merge_gate: :pending}} =
             ForemanServer.Workflow.CreateWorkflowDispatcher.dispatch(task_id, pr_url: pr_url)

    # The PR is genuinely held — MergeGate itself reports it pending,
    # not the dispatcher merely echoing an unlinked status.
    assert pr_url in ForemanServer.Workflow.MergeGate.pending()

    # Only explicit human approval clears the hold; the dispatcher
    # provides no path that bypasses MergeGate.approve/3.
    assert {:ok, :approved} =
             ForemanServer.Workflow.MergeGate.approve(pr_url, "alice", "github:alice")
  end
end
