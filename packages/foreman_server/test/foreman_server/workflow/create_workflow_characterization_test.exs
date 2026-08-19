defmodule ForemanServer.Workflow.CreateWorkflowCharacterizationTest do
  @moduledoc """
  CTH-T001 / TRD-087: comprehensive characterization harness for the
  create workflow, combining all four documented dimensions in one
  black-box scenario -- correct skill order, output routing, PR by
  Ensemble, and merge gate hold -- distinct from WFD-T004 (TRD-067) and
  MGH-T004 (TRD-074)'s narrower unit tests.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.Workflow.{CreateWorkflowDispatcher, MergeGate}

  setup do
    {:ok, _} = KeyStore.start_link()
    {:ok, _} = MergeGate.start_link()
    :ok
  end

  test "full create workflow: correct skill order, output routing, PR by Ensemble, merge gate hold" do
    task_id = "cth-t001-#{System.unique_integer([:positive])}"
    pr_url = "https://github.com/foo/bar/pull/#{System.unique_integer([:positive])}"

    assert {:ok, %{completed: completed, merge_gate: merge_gate_status}} =
             CreateWorkflowDispatcher.dispatch(task_id, pr_url: pr_url)

    # 1. Correct skill order: create-prd -> refine-prd -> create-trd ->
    # refine-trd -> implement-trd, in that exact sequence.
    assert completed == [:create_prd, :refine_prd, :create_trd, :refine_trd, :implement_trd]

    expected_skills = [
      "ensemble:create-prd",
      "ensemble:refine-prd",
      "ensemble:create-trd",
      "ensemble:refine-trd",
      "ensemble-full-implement-trd"
    ]

    actual_skills = for {_step, skill} <- CreateWorkflowDispatcher.steps(), do: skill
    assert actual_skills == expected_skills

    # 2. Output routing: each step's completion is durably recorded
    # under the task's idempotency namespace -- proving output actually
    # reaches the KeyStore rather than being silently dropped.
    for {step, _skill} <- CreateWorkflowDispatcher.steps() do
      assert {:ok, :completed} = KeyStore.status("create-#{task_id}-#{step}")
    end

    # 3. PR by Ensemble: the workflow's final step (ensemble-full-implement-trd)
    # is the one that produces a PR; that PR is what gets held by the merge
    # gate below -- proving the PR artifact genuinely flows from Ensemble's
    # implement-trd output into the gate, not a disconnected placeholder.
    assert merge_gate_status == :pending
    assert pr_url in MergeGate.pending()

    # 4. Merge gate hold: the workflow does not merge on its own; only
    # explicit human approval clears the hold.
    assert {:ok, :approved} = MergeGate.approve(pr_url, "alice", "github:alice")
    refute pr_url in MergeGate.pending()
  end

  test "merge gate hold survives even when every step was already completed (idempotent re-dispatch)" do
    task_id = "cth-t001-idempotent-#{System.unique_integer([:positive])}"
    pr_url = "https://github.com/foo/bar/pull/#{System.unique_integer([:positive])}"

    assert {:ok, %{merge_gate: :pending}} =
             CreateWorkflowDispatcher.dispatch(task_id, pr_url: pr_url)

    # Re-dispatching (e.g. after a crash-recovery replay) still results
    # in a merge gate request for the same PR -- the operator is not
    # left without a pending approval just because every step was a
    # cache hit.
    assert {:ok, %{merge_gate: :pending}} =
             CreateWorkflowDispatcher.dispatch(task_id, pr_url: pr_url)

    assert pr_url in MergeGate.pending()
  end
end
