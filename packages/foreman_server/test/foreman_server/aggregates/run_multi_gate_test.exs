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
        pr_url: url_of(repo_id),
        branch_name: "foreman/task-1/#{@run_id}",
        head_sha: head_of(repo_id),
        base_branch: "main"
      }
      |> put_repo(repo_id)

    apply_spec(state, Run.handle_command(state, %{type: "run.pr.ready", payload: payload}))
  end

  defp approve_result(state, repo_id, identity \\ @identity, head_sha \\ nil) do
    payload =
      put_repo(
        %{
          run_id: @run_id,
          approver: "leo",
          approver_identity: identity,
          head_sha: head_sha || head_of(repo_id)
        },
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

  # The head and PR url `ready/2` opens each repository's PR with.
  defp head_of(repo_id), do: "sha-#{repo_id || "main"}"
  defp url_of(repo_id), do: "https://github.com/o/#{repo_id || "main"}/pull/1"

  defp fold(state, type, payload),
    do: Run.apply_event(state, %{event_type: type, payload: Map.put(payload, :run_id, @run_id)})

  defp rehold_result(state, repo_id, head_sha, pr_url) do
    payload = put_repo(%{run_id: @run_id, pr_url: pr_url, head_sha: head_sha}, repo_id)
    Run.handle_command(state, %{type: "run.pr.rehold", payload: payload})
  end

  defp rehold(state, repo_id, head_sha),
    do: apply_spec(state, rehold_result(state, repo_id, head_sha, url_of(repo_id)))

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

  describe "an approval pins the head the operator named (foreman-ehxy6)" do
    test "the approval event carries the head, and the gate pins it until it is held again", %{
      state: state
    } do
      held = ready(state, nil)

      assert %Run.MergePin{pr_url: "https://github.com/o/main/pull/1", head_sha: nil} =
               Run.merge_pin(held)

      assert {:ok, %{event_type: "MergeGateApproved", payload: %{head_sha: "sha-main"}}} =
               approve_result(held, nil)

      approved = approve(held, nil)
      assert %Run.MergePin{head_sha: "sha-main", approved_at: at} = Run.merge_pin(approved)
      assert is_integer(at)

      assert %Run.MergePin{head_sha: nil, approved_at: nil} =
               approved |> ready(nil) |> Run.merge_pin()
    end

    test "an approval that names no head is refused, with the field named", %{state: state} do
      state = ready(state, nil)
      base = %{run_id: @run_id, approver: "leo", approver_identity: @identity}

      for payload <- [base | Enum.map([nil, "", 5], &Map.put(base, :head_sha, &1))] do
        assert {:error, {:missing_or_invalid, :head_sha}} =
                 Run.handle_command(state, %{type: "merge_approve", payload: payload})
      end

      assert %{nil => :pending} = state.merge_gates
    end

    test "an approval recorded before heads were pinned pins the head the PR watch had recorded",
         %{state: state} do
      url = url_of(nil)

      fixed =
        fold(ready(state, nil), "PrUpdated", %{
          pr_url: url,
          pr_status: "open",
          head_sha: "sha-fixed",
          base_branch: "main"
        })

      legacy =
        fold(fixed, "MergeGateApproved", %{
          approver: "leo",
          approver_identity: @identity,
          approved_at: 1
        })

      assert %Run.MergePin{head_sha: "sha-fixed", approved_at: 1} = Run.merge_pin(legacy)

      pushed =
        fold(legacy, "PrUpdated", %{
          pr_url: url,
          pr_status: "open",
          head_sha: "sha-pushed",
          base_branch: "main"
        })

      assert Run.merge_pin(pushed).head_sha == "sha-fixed",
             "a push after approval is never the pin"

      assert {:stale, %Run.MergePin{head_sha: "sha-fixed"}} =
               Run.stale_approval(pushed, nil, "sha-pushed")
    end
  end

  describe "a head that moved after approval voids it (foreman-ehxy6)" do
    test "the approval and its pin are dropped, not re-pinned to the moved head", %{state: state} do
      approved = state |> ready(nil) |> approve(nil)

      assert {:ok, spec} = rehold_result(approved, nil, "sha-pushed", url_of(nil))
      assert spec.event_type == "MergeGatePending"

      assert %{
               reason: "head_moved_since_approval",
               approved_head_sha: "sha-main",
               head_sha: "sha-pushed",
               pr_url: "https://github.com/o/main/pull/1"
             } = spec.payload

      refute Map.has_key?(spec.payload, :repo_id)

      held = apply_spec(approved, {:ok, spec})
      assert Run.merge_gate(held) == :pending
      assert %Run.MergePin{head_sha: nil, approved_at: nil} = Run.merge_pin(held)
      assert {:error, :pr_not_acceptable} = merge_result(held, nil)
    end

    test "only a fresh approval reopens the gate, and it pins the new head", %{state: state} do
      held = state |> ready(nil) |> approve(nil) |> rehold(nil, "sha-pushed")

      assert {:ok, %{payload: %{head_sha: "sha-pushed"}}} =
               approve_result(held, nil, @identity, "sha-pushed")

      reapproved = apply_spec(held, approve_result(held, nil, @identity, "sha-pushed"))
      assert Run.merge_gate(reapproved) == :approved
      assert Run.merge_pin(reapproved).head_sha == "sha-pushed"
      assert {:ok, _} = merge_result(reapproved, nil)

      assert {:error, :merge_gate_already_approved} = approve_result(reapproved, nil)
    end

    test "the same head, a held gate, another PR and a run with no PR are left alone", %{
      state: state
    } do
      approved = state |> ready(nil) |> approve(nil)

      assert {:ok, nil} = rehold_result(approved, nil, "sha-main", url_of(nil))

      assert {:ok, nil} =
               rehold_result(approved, nil, "sha-pushed", "https://github.com/o/other/pull/9")

      assert {:ok, nil} = rehold_result(ready(state, nil), nil, "sha-pushed", url_of(nil))
      assert {:ok, nil} = rehold_result(state, nil, "sha-pushed", url_of(nil))
      assert :current = Run.stale_approval(approved, nil, "sha-main")
      assert :current = Run.stale_approval(state, nil, "sha-pushed")
    end

    test "a re-hold needs the PR and the head it saw", %{state: state} do
      approved = state |> ready(nil) |> approve(nil)

      assert {:error, {:missing_or_invalid, :pr_url}} =
               rehold_result(approved, nil, "sha-pushed", nil)

      assert {:error, {:missing_or_invalid, :head_sha}} =
               rehold_result(approved, nil, nil, url_of(nil))

      assert {:error, {:missing_or_invalid, :repo_id}} =
               rehold_result(approved, 5, "sha-pushed", url_of(nil))
    end

    test "re-holding one repo's PR leaves the other repo's approval standing", %{state: state} do
      both = state |> ready(nil) |> ready("b") |> approve(nil) |> approve("b")

      assert {:ok, %{payload: %{repo_id: "b", approved_head_sha: "sha-b"}}} =
               rehold_result(both, "b", "sha-pushed", url_of("b"))

      after_b = rehold(both, "b", "sha-pushed")
      assert Run.merge_gate(after_b, "b") == :pending
      assert Run.merge_gate(after_b, nil) == :approved
      assert Run.merge_pin(after_b, nil).head_sha == "sha-main"

      # b's gate does not answer for a's PR, nor a's gate for b's
      assert {:ok, nil} = rehold_result(both, "b", "sha-pushed", url_of(nil))
      assert {:ok, nil} = rehold_result(both, nil, "sha-pushed", url_of("b"))
    end

    test "a PR outlives its run: a finished run's approval is voided too", %{state: state} do
      approved = state |> ready(nil) |> approve(nil)

      terminal =
        Run.apply_event(approved, %{event_type: "RunCompleted", payload: %{run_id: @run_id}})

      assert terminal.terminal?

      assert {:ok, %{event_type: "MergeGatePending"}} =
               rehold_result(terminal, nil, "sha-pushed", url_of(nil))
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
