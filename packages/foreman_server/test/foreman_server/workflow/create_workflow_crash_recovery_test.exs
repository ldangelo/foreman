defmodule ForemanServer.Workflow.CreateWorkflowCrashRecoveryTest do
  @moduledoc """
  CTH-T004 / TRD-090: crash-recovery characterization scenario for the
  create workflow -- Foreman crashes mid-sequence, restarts, resumes
  from the next incomplete step, and produces no duplicate side
  effects. Builds on RTE-T005's generic KeyStore-level reconciliation
  (TRD-079, crash_recovery_characterization_test.exs) applied here to
  CreateWorkflowDispatcher's actual step sequence.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.Workflow.{CreateWorkflowDispatcher, MergeGate}

  setup do
    {:ok, _} = KeyStore.start_link()
    {:ok, _} = MergeGate.start_link()
    :ok
  end

  test "crash after step 2 of 5: restart resumes from step 3, steps 1-2 are not re-dispatched" do
    task_id = "cth-t004-#{System.unique_integer([:positive])}"
    prefix = "create-#{task_id}"

    # Simulate the workflow having genuinely completed the first two
    # steps before a crash -- exactly the durable state the real
    # dispatcher would have left in the KeyStore at that point.
    :ok = KeyStore.mark_started("#{prefix}-create_prd")
    :ok = KeyStore.mark_completed("#{prefix}-create_prd")
    :ok = KeyStore.mark_started("#{prefix}-refine_prd")
    :ok = KeyStore.mark_completed("#{prefix}-refine_prd")

    # Crash happens here, mid-sequence, before create_trd starts.
    # "Restart" is simulated by simply re-invoking dispatch/2 against
    # the same durable KeyStore state -- there is no in-memory workflow
    # state to lose, by design.
    assert {:ok, %{completed: completed}} = CreateWorkflowDispatcher.dispatch(task_id)

    # Resumes from the next incomplete step: create_prd/refine_prd are
    # reported as completed (already done), but the sequencer picks up
    # at create_trd and runs every remaining step through to the end --
    # it does not restart from create_prd, and it does not stop early.
    assert completed == [:create_prd, :refine_prd, :create_trd, :refine_trd, :implement_trd]

    # No duplicate side effects: the first two steps' idempotency
    # records were never touched again -- still exactly :completed,
    # not re-marked :started then :completed a second time (which
    # would indicate the skill was re-invoked).
    assert {:ok, :completed} = KeyStore.status("#{prefix}-create_prd")
    assert {:ok, :completed} = KeyStore.status("#{prefix}-refine_prd")
  end

  test "crash after all five steps but before merge-gate request: restart re-requests the same PR exactly once, not duplicated" do
    task_id = "cth-t004-post-steps-#{System.unique_integer([:positive])}"
    pr_url = "https://github.com/foo/bar/pull/#{System.unique_integer([:positive])}"
    prefix = "create-#{task_id}"

    for {step, _skill} <- CreateWorkflowDispatcher.steps() do
      :ok = KeyStore.mark_started("#{prefix}-#{step}")
      :ok = KeyStore.mark_completed("#{prefix}-#{step}")
    end

    # Crash happens here, before the merge-gate request reached
    # MergeGate. "Restart" re-dispatches; every step is a cache hit,
    # but the merge-gate request is not durably recorded anywhere else
    # in this design, so it is correctly re-issued on resume.
    assert {:ok, %{merge_gate: :pending}} =
             CreateWorkflowDispatcher.dispatch(task_id, pr_url: pr_url)

    # Exactly one pending entry for this PR -- MergeGate.request_approval
    # is itself idempotent (re-inserts the same key), so resuming after
    # a crash here does not create duplicate or conflicting gate entries.
    assert Enum.count(MergeGate.pending(), &(&1 == pr_url)) == 1
  end
end
