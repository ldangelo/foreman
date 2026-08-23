defmodule ForemanServer.Workflow.MergeGateCharacterizationTest do
  @moduledoc """
  characterization tests for merge gate integration in the Run aggregate.

  TRD-2026-4212be7e / MGH-T004 / TRD-074

  Verifies the full fail-closed merge gate lifecycle:
  1. run.pr.ready sets merge_gate: :pending — run.pr.merge is blocked.
  2. merge_approve (authorized) transitions merge_gate: :approved — run.pr.merge succeeds.
  3. merge_approve (unauthorized) is rejected; gate stays pending.

  Tests call Run.handle_command/2 and Run.apply_event/2 directly — no
  EventStore, CommandRouter, or Actor infra. MergeGate GenServer is started
  only for the side-effect calls inside run.pr.ready's handle_command.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Run

  setup do
    {:ok, _} = ForemanServer.Workflow.MergeGate.ensure_started()
    :ok
  end

  # --- Helper: build a run in the :in_progress state ---

  defp run_state(run_id, task_id \\ "task-1", project_id \\ "project-test") do
    {:ok, event_spec} =
      Run.handle_command(Run.initial_state(), %{
        type: "run.start",
        payload: %{
          run_id: run_id,
          task_id: task_id,
          project_id: project_id,
          workflow_snapshot: %{}
        }
      })

    Run.apply_event(Run.initial_state(), %{
      event_type: event_spec.event_type,
      payload: event_spec.payload
    })
  end

  # --- Test 1: run.pr.ready → merge_gate: :pending; run.pr.merge blocked ---

  test "PrReady sets merge_gate: :pending; run.pr.merge returns error" do
    run_id = "run-pr-ready-#{System.unique_integer([:positive])}"
    state = run_state(run_id)

    {:ok, event_spec} =
      Run.handle_command(state, %{
        type: "run.pr.ready",
        payload: %{
          run_id: run_id,
          task_id: state.task_id,
          project_id: state.project_id,
          pr_url: "https://github.com/foo/bar/pull/42",
          branch_name: "foreman/run-#{run_id}/create-prd",
          head_sha: "abc123",
          base_branch: "main"
        }
      })

    state2 =
      Run.apply_event(state, %{
        event_type: event_spec.event_type,
        payload: event_spec.payload
      })

    # Gate is held pending
    assert state2.merge_gate == :pending

    # Merge is blocked — state.merge_gate is the authoritative gate check
    assert {:error, :pr_not_acceptable} =
             Run.handle_command(state2, %{
               type: "run.pr.merge",
               payload: %{
                 run_id: run_id,
                 task_id: state2.task_id,
                 project_id: state2.project_id,
                 pr_url: "https://github.com/foo/bar/pull/42",
                 branch_name: "main"
               }
             })
  end

  # --- Test 2: authorized merge_approve → merge_gate: :approved; run.pr.merge succeeds ---

  test "authorized merge_approve sets merge_gate: :approved; run.pr.merge succeeds" do
    run_id = "run-approve-#{System.unique_integer([:positive])}"
    state = run_state(run_id)

    # 1. Hold the gate
    {:ok, ready_spec} =
      Run.handle_command(state, %{
        type: "run.pr.ready",
        payload: %{
          run_id: run_id,
          task_id: state.task_id,
          project_id: state.project_id,
          pr_url: "https://github.com/foo/bar/pull/99",
          branch_name: "foreman/run-#{run_id}/create-prd",
          head_sha: "abc456",
          base_branch: "main"
        }
      })

    state2 =
      Run.apply_event(state, %{
        event_type: ready_spec.event_type,
        payload: ready_spec.payload
      })

    assert state2.merge_gate == :pending

    # 2. Authorized approval transitions to :approved
    {:ok, approve_spec} =
      Run.handle_command(state2, %{
        type: "merge_approve",
        payload: %{
          run_id: run_id,
          approver: "ldangelo",
          approver_identity: "github:ldangelo"
        }
      })

    state3 =
      Run.apply_event(state2, %{
        event_type: approve_spec.event_type,
        payload: approve_spec.payload
      })

    assert state3.merge_gate == :approved

    # 3. Merge now succeeds
    assert {:ok, merge_spec} =
             Run.handle_command(state3, %{
               type: "run.pr.merge",
               payload: %{
                 run_id: run_id,
                 task_id: state3.task_id,
                 project_id: state3.project_id,
                 pr_url: "https://github.com/foo/bar/pull/99",
                 branch_name: "main"
               }
             })

    assert merge_spec.event_type == "PrMerged"
  end

  # --- Test 3: unauthorized approver identity is rejected ---

  test "unauthorized approver_identity returns error; merge_gate stays :pending" do
    run_id = "run-unauthorized-#{System.unique_integer([:positive])}"
    state = run_state(run_id)

    # Hold the gate
    {:ok, ready_spec} =
      Run.handle_command(state, %{
        type: "run.pr.ready",
        payload: %{
          run_id: run_id,
          task_id: state.task_id,
          project_id: state.project_id,
          pr_url: "https://github.com/foo/bar/pull/77",
          branch_name: "foreman/run-#{run_id}/create-prd",
          head_sha: "abc789",
          base_branch: "main"
        }
      })

    state2 =
      Run.apply_event(state, %{
        event_type: ready_spec.event_type,
        payload: ready_spec.payload
      })

    # Unauthorized identity is rejected — gate stays :pending
    assert {:error, :unauthorized_approver} =
             Run.handle_command(state2, %{
               type: "merge_approve",
               payload: %{
                 run_id: run_id,
                 approver: "attacker",
                 approver_identity: "github:attacker"
               }
             })

    # Gate is still pending
    assert state2.merge_gate == :pending

    # Merge still blocked
    assert {:error, :pr_not_acceptable} =
             Run.handle_command(state2, %{
               type: "run.pr.merge",
               payload: %{
                 run_id: run_id,
                 task_id: state2.task_id,
                 project_id: state2.project_id,
                 pr_url: "https://github.com/foo/bar/pull/77",
                 branch_name: "main"
               }
             })
  end

  # --- Test 4: run.pr.merge allowed without any prior run.pr.ready (backward compat) ---
  # If the aggregate state has no merge_gate set (nil), run.pr.merge is allowed.
  # This preserves the existing behavior for workflows that predate the merge gate.

  # fail-closed: any run without an explicit merge_approve is blocked.
  # A run that skips run.pr.ready (no gate ever set) or calls run.pr.merge
  # before approval must NOT merge — this prevents direct bypass of the gate.
  test "run.pr.merge blocked when merge_gate is nil (no approval ever given)" do
    run_id = "run-no-gate-#{System.unique_integer([:positive])}"
    state = run_state(run_id)

    # state.merge_gate is nil — no gate was ever requested
    assert state.merge_gate == nil

    # Merge is blocked — fail-closed, not fail-open
    assert {:error, :pr_not_acceptable} =
             Run.handle_command(state, %{
               type: "run.pr.merge",
               payload: %{
                 run_id: run_id,
                 task_id: state.task_id,
                 project_id: state.project_id,
                 pr_url: "https://github.com/foo/bar/pull/1",
                 branch_name: "main"
               }
             })
  end
end
