defmodule ForemanServer.Workflow.LegacyRemovalE2ETest do
  @moduledoc """
  LGC-T010 / TRD-105: runs the create, implement, and fix workflows
  end-to-end and verifies observable equivalence -- PR created (create
  workflow reaches a genuine merge-gate hold), task status updated
  (idempotency records durably reflect completion), and operator
  notified (merge gate pending list surfaces the PR for approval) --
  entirely on the current (post-migration) dispatcher stack, with no
  pre-migration code path involved.

  Per LGC-T008's scan (docs/LGC/LGC-T008-scan.md), zero pre-migration
  files (pi-sdk-runner, tool_factory, WorkflowRunner) exist in this
  codebase, so "without pre-migration code" is satisfied by construction;
  this test additionally re-verifies that grep finding structurally by
  asserting none of the three dispatchers under test reference any
  legacy module.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.Workflow.{
    CreateWorkflowDispatcher,
    ImplementWorkflowDispatcher,
    FixWorkflowDispatcher,
    MergeGate
  }

  setup do
    {:ok, _} = KeyStore.start_link()
    {:ok, _} = MergeGate.start_link()
    :ok
  end

  test "create workflow end-to-end: all skills dispatched, PR held for operator approval" do
    task_id = "lgc-t010-create-#{System.unique_integer([:positive])}"
    pr_url = "https://github.com/foo/bar/pull/#{System.unique_integer([:positive])}"

    assert {:ok, %{completed: completed, merge_gate: :pending}} =
             CreateWorkflowDispatcher.dispatch(task_id, pr_url: pr_url)

    # Task status updated: every documented step reached :completed.
    assert completed == [:create_prd, :refine_prd, :create_trd, :refine_trd, :implement_trd]

    for {step, _skill} <- CreateWorkflowDispatcher.steps() do
      assert {:ok, :completed} = KeyStore.status("create-#{task_id}-#{step}")
    end

    # PR created + operator notified: the PR is genuinely surfaced in
    # the merge gate's pending queue, awaiting explicit human approval.
    assert pr_url in MergeGate.pending()

    # Operator approves; observable outcome flips to approved, not
    # auto-merged by the workflow itself.
    assert {:ok, :approved} = MergeGate.approve(pr_url, "alice", "github:alice")
  end

  test "implement workflow end-to-end: task status updated via durable idempotency record" do
    task_id = "lgc-t010-implement-#{System.unique_integer([:positive])}"

    assert {:ok, :dispatched} = ImplementWorkflowDispatcher.dispatch(task_id)
    assert {:ok, :completed} = KeyStore.status("implement-#{task_id}-1")

    # Idempotent: re-running the workflow reflects the same completed
    # status rather than dispatching again.
    assert {:ok, :skipped} = ImplementWorkflowDispatcher.dispatch(task_id)
  end

  test "fix workflow end-to-end: task status updated via durable idempotency record" do
    task_id = "lgc-t010-fix-#{System.unique_integer([:positive])}"

    assert {:ok, :dispatched} = FixWorkflowDispatcher.dispatch(task_id)
    assert {:ok, :completed} = KeyStore.status("fix-#{task_id}-1")

    assert {:ok, :skipped} = FixWorkflowDispatcher.dispatch(task_id)
  end

  test "no dispatcher under test references pre-migration code" do
    legacy_patterns = ~r/pi[-_]sdk[-_]runner|tool[-_]factory|WorkflowRunner/i

    dispatcher_sources =
      [
        "lib/foreman_server/workflow/create_workflow_dispatcher.ex",
        "lib/foreman_server/workflow/implement_workflow_dispatcher.ex",
        "lib/foreman_server/workflow/fix_workflow_dispatcher.ex"
      ]

    for path <- dispatcher_sources do
      source = File.read!(path)
      refute Regex.match?(legacy_patterns, source), "#{path} references pre-migration code"
    end
  end
end
