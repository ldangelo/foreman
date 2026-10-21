defmodule ForemanServer.Aggregates.RunMultiGateTest do
  @moduledoc """
  E12-S6: the Run aggregate's merge gate is a map keyed by `repo_id` (`nil` =
  the run's primary, which is also where every legacy event folds). Pure
  aggregate tests; the MergeGate GenServer is only touched by the side effects
  inside `run.pr.ready` / `merge_approve`.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Run
  alias ForemanServer.PrGate
  alias ForemanServer.Workflow.MergeGate

  @run_id "run-multi-gate"
  @identity "github:ldangelo"

  setup do
    case GenServer.whereis(MergeGate) do
      nil -> {:ok, _pid} = MergeGate.start_link()
      _pid -> :ok
    end

    MergeGate.clear()
    %{state: started()}
  end

  defp started do
    {:ok, spec} =
      Run.handle_command(Run.initial_state(), %{
        type: "run.start",
        payload: %{
          run_id: @run_id,
          task_id: "task-1",
          project_id: "project-1",
          workflow_snapshot: %{}
        }
      })

    Run.apply_event(Run.initial_state(), %{event_type: spec.event_type, payload: spec.payload})
  end

  defp apply_spec(state, {:ok, spec}),
    do: Run.apply_event(state, %{event_type: spec.event_type, payload: spec.payload})

  defp ready(state, repo_id) do
    payload =
      %{
        run_id: @run_id,
        project_id: "project-1",
        task_id: "task-1",
        pr_url: "https://github.com/o/#{repo_id || "main"}/pull/1",
        branch_name: "foreman/task-1/#{@run_id}",
        head_sha: "sha-#{repo_id || "main"}",
        base_branch: "main"
      }
      |> put_repo(repo_id)

    apply_spec(state, Run.handle_command(state, %{type: "run.pr.ready", payload: payload}))
  end

  defp approve_result(state, repo_id, identity \\ @identity) do
    payload =
      put_repo(
        %{run_id: @run_id, approver: "leo", approver_identity: identity},
        repo_id
      )

    Run.handle_command(state, %{type: "merge_approve", payload: payload})
  end

  defp approve(state, repo_id), do: apply_spec(state, approve_result(state, repo_id))

  defp merge_result(state, repo_id) do
    payload =
      put_repo(
        %{
          run_id: @run_id,
          project_id: "project-1",
          task_id: "task-1",
          pr_url: "https://github.com/o/x/pull/1",
          branch_name: "foreman/task-1/#{@run_id}"
        },
        repo_id
      )

    Run.handle_command(state, %{type: "run.pr.merge", payload: payload})
  end

  defp put_repo(payload, nil), do: payload
  defp put_repo(payload, repo_id), do: Map.put(payload, :repo_id, repo_id)

  describe "legacy streams" do
    test "events without repo_id fold into the nil (primary) key exactly as before", %{
      state: state
    } do
      fold = fn state, type, payload ->
        Run.apply_event(state, %{event_type: type, payload: Map.put(payload, :run_id, @run_id)})
      end

      pending = fold.(state, "PrReady", %{pr_url: "u", head_sha: "s", base_branch: "main"})
      assert pending.merge_gates == %{nil => :pending}
      assert Run.merge_gate(pending) == :pending

      approved = fold.(pending, "MergeGateApproved", %{approver: "a", approver_identity: "i"})
      assert approved.merge_gates == %{nil => :approved}

      held = fold.(approved, "MergeGatePending", %{pr_url: "u"})
      assert held.merge_gates == %{nil => :pending}
    end

    test "the legacy error tuples are unchanged for the primary", %{state: state} do
      assert {:error, {:merge_gate_not_found, :run}} = approve_result(state, nil)
      assert {:error, :pr_not_acceptable} = merge_result(state, nil)

      ready = ready(state, nil)
      approved = approve(ready, nil)
      assert {:error, :merge_gate_already_approved} = approve_result(approved, nil)
    end

    test "a single-repo approval event carries no repo_id", %{state: state} do
      {:ok, spec} = state |> ready(nil) |> approve_result(nil)
      refute Map.has_key?(spec.payload, :repo_id)
    end
  end

  describe "gates per repository" do
    test "approving one repo's PR leaves the other pending and unmergeable", %{state: state} do
      state = state |> ready(nil) |> ready("b")
      assert %{nil => :pending, "b" => :pending} = state.merge_gates

      only_a = approve(state, nil)
      assert Run.merge_gate(only_a, nil) == :approved
      assert Run.merge_gate(only_a, "b") == :pending

      assert {:ok, _} = merge_result(only_a, nil)
      assert {:error, :pr_not_acceptable} = merge_result(only_a, "b")

      only_b = approve(state, "b")
      assert Run.merge_gate(only_b, nil) == :pending
      assert Run.merge_gate(only_b, "b") == :approved
      assert {:error, :pr_not_acceptable} = merge_result(only_b, nil)
      assert {:ok, _} = merge_result(only_b, "b")
    end

    test "a non-primary approval event carries the repo_id", %{state: state} do
      {:ok, spec} = state |> ready("b") |> approve_result("b")
      assert spec.payload.repo_id == "b"
      assert spec.event_type == "MergeGateApproved"
    end

    test "a re-ready of one repo re-holds only that repo's gate", %{state: state} do
      both = state |> ready(nil) |> ready("b") |> approve(nil) |> approve("b")
      assert %{nil => :approved, "b" => :approved} = both.merge_gates

      reready_b = ready(both, "b")
      assert Run.merge_gate(reready_b, nil) == :approved
      assert Run.merge_gate(reready_b, "b") == :pending

      reready_a = ready(both, nil)
      assert Run.merge_gate(reready_a, nil) == :pending
      assert Run.merge_gate(reready_a, "b") == :approved
    end

    test "approving an unknown repo is a typed error naming it", %{state: state} do
      state = ready(state, nil)
      assert {:error, {:merge_gate_not_found, :run, "zzz"}} = approve_result(state, "zzz")
      assert {:error, :pr_not_acceptable} = merge_result(state, "zzz")
    end

    test "a repo id that is not a binary is malformed, not the primary", %{state: state} do
      state = ready(state, nil)

      assert {:error, {:missing_or_invalid, :repo_id}} = approve_result(state, 5)
      assert {:error, {:missing_or_invalid, :repo_id}} = merge_result(state, 5)
    end

    test "an unauthorized approver opens neither repo's gate", %{state: state} do
      state = state |> ready(nil) |> ready("b")

      for repo_id <- [nil, "b"] do
        assert {:error, :unauthorized_approver} =
                 approve_result(state, repo_id, "github:someone-else")
      end

      assert %{nil => :pending, "b" => :pending} = state.merge_gates
    end

    test "approving twice is refused per repo", %{state: state} do
      state = state |> ready("b") |> approve("b")
      assert {:error, :merge_gate_already_approved} = approve_result(state, "b")
    end
  end

  describe "ETS gate entries" do
    test "each PR of a run is keyed by its own requester key" do
      assert PrGate.gate_key("r", nil) == "run:r"
      assert PrGate.gate_key("r", "") == "run:r"
      assert PrGate.gate_key("r", "b") == "run:r:b"
    end

    test "approving b's entry approves neither the primary's nor a stale approved one", %{
      state: state
    } do
      state |> ready(nil) |> ready("b")

      assert MergeGate.pending_for_key?("run:#{@run_id}")
      assert MergeGate.pending_for_key?("run:#{@run_id}:b")

      :ok = PrGate.record_approved(@run_id, "leo", @identity, "b")

      assert MergeGate.approved?("run:#{@run_id}:b")
      refute MergeGate.approved?("run:#{@run_id}")
      assert MergeGate.pending_for_key?("run:#{@run_id}")
    end

    test "approve_by_key approves a pending entry of the key, never an already approved one" do
      # Several scenarios: which entry a status-blind lookup returns depends on
      # table order, so one scenario alone could pass by luck.
      for n <- 1..8 do
        key = "run:k#{n}"
        pending = "https://github.com/o/r/pull/#{n}0"
        approved = "https://github.com/o/r/pull/#{n}1"

        MergeGate.request_approval(pending, key)
        MergeGate.request_approval(approved, key)
        {:ok, :approved} = MergeGate.approve(approved, "leo", @identity)

        assert {:ok, :approved} = MergeGate.approve_by_key(key, "leo", @identity)
        refute pending in MergeGate.pending(), "#{pending} was the pending entry of #{key}"

        # Nothing pending under the key any more: not found, not "approve something".
        assert {:error, :not_found} = MergeGate.approve_by_key(key, "leo", @identity)
      end
    end
  end

  describe "run.pr.retry / run.repo_pr_failed" do
    test "retry validates the run and repository, emits no event, and works on a terminal run",
         %{state: state} do
      retry = fn state, payload ->
        Run.handle_command(state, %{type: "run.pr.retry", payload: payload})
      end

      assert {:ok, nil} = retry.(state, %{run_id: @run_id, repo_id: "b"})
      assert {:error, {:missing_or_invalid, :repo_id}} = retry.(state, %{run_id: @run_id})

      terminal =
        Run.apply_event(state, %{event_type: "RunCompleted", payload: %{run_id: @run_id}})

      assert terminal.terminal?
      assert {:ok, nil} = retry.(terminal, %{run_id: @run_id, repo_id: "b"})
    end

    test "the failure event names the repo, and the run keeps its status", %{state: state} do
      assert {:ok, spec} =
               Run.handle_command(state, %{
                 type: "run.repo_pr_failed",
                 payload: %{run_id: @run_id, repo_id: "b", reason: "push rejected", at: 7}
               })

      assert spec.event_type == "RunRepoPrFailed"
      assert spec.payload == %{run_id: @run_id, repo_id: "b", reason: "push rejected", at: 7}

      folded = Run.apply_event(state, %{event_type: spec.event_type, payload: spec.payload})
      assert folded.status == state.status
      refute folded.terminal?
    end

    test "a failure missing its reason is rejected", %{state: state} do
      assert {:error, {:missing_or_invalid, :reason}} =
               Run.handle_command(state, %{
                 type: "run.repo_pr_failed",
                 payload: %{run_id: @run_id, repo_id: "b", at: 7}
               })
    end
  end
end
