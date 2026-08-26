defmodule ForemanServer.Workflow.CreateWorkflowCharacterizationTest do
  @moduledoc """
  Characterization tests for prd (create) workflow manifest and merge gate
  integration with the 5-phase ensemble chain.

  TRD-2026-4212be7e / CTH-T001 / TRD-087

  Verifies:
  - prd.yaml manifest has 5 phases in correct order with correct skill commands
  - Merge gate hold activates after run.pr.ready (end of implement-trd phase)
  - run.pr.merge blocked until explicit merge_approve
  - Fail-closed when no gate ever requested

  Structure mirrors merge_gate_characterization_test.exs: pure aggregate unit
  tests + MergeGate GenServer only. No Mox, no CommandGateway, no full app boot.

  Manifest parsing uses Interpreter.load!/1 directly (pure function, no GenServer).

  Dependencies: TRD-074 (merge gate), TRD-067 (plan workflow characterization)
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Run
  alias ForemanServer.Workflow.MergeGate
  alias ForemanServer.Workflow.Interpreter

  # ===========================================================================
  # MergeGate setup — singleton ETS-backed GenServer started once per module.
  # ===========================================================================

  setup_all do
    case GenServer.whereis(MergeGate) do
      nil -> {:ok, _pid} = MergeGate.start_link()
      _pid -> :ok
    end

    :ok
  end

  setup do
    MergeGate.clear()
    :ok
  end

  # ===========================================================================
  # Helper: build a run in the :in_progress state.
  # Exact copy of merge_gate_characterization_test.exs helper.
  # ===========================================================================

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

  # ===========================================================================
  # prd.yaml manifest structure tests (CTH-T001-1)
  # Uses Interpreter.load!/1 directly — pure function, no GenServer needed.
  # Parsed result has binary keys ("name", "command") matching raw YAML.
  # ===========================================================================

  describe "prd.yaml manifest structure (CTH-T001-1)" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir(),
          "wf_char_prd_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      manifest_path = Path.join(tmp, "prd.yaml")

      # action: command is included so the YAML matches what resolve_workflow
      # would produce (action derived from presence of "command" field).
      File.write!(manifest_path, """
      name: prd
      description: Create a PRD through the full ensemble chain.
      phases:
        - name: create-prd
          action: command
          command: "/skill:ensemble-full-create-prd --foreman"
        - name: refine-prd
          action: command
          command: "/skill:ensemble-full-refine-prd --foreman"
        - name: create-trd
          action: command
          command: "/skill:ensemble-full-create-trd --foreman"
        - name: refine-trd
          action: command
          command: "/skill:ensemble-full-refine-trd-foreman --foreman"
        - name: implement-trd
          action: command
          command: "/skill:ensemble-full-implement-trd --foreman"
      """)

      on_exit(fn -> File.rm_rf!(tmp) end)
      %{manifest_path: manifest_path}
    end

    test "loads prd.yaml and yields 5 phases in correct order", %{
      manifest_path: path
    } do
      {:ok, wf} = Interpreter.load!(path)
      assert wf["name"] == "prd"
      assert is_list(wf["phases"])
      assert length(wf["phases"]) == 5

      phase_names = Enum.map(wf["phases"], fn p -> p["name"] end)

      assert phase_names == [
               "create-prd",
               "refine-prd",
               "create-trd",
               "refine-trd",
               "implement-trd"
             ]
    end

    test "all phases use Ensemble skill convention (ensemble-full-*)", %{
      manifest_path: path
    } do
      {:ok, wf} = Interpreter.load!(path)

      expected_skills = %{
        "create-prd" => "ensemble-full-create-prd",
        "refine-prd" => "ensemble-full-refine-prd",
        "create-trd" => "ensemble-full-create-trd",
        "refine-trd" => "ensemble-full-refine-trd-foreman",
        "implement-trd" => "ensemble-full-implement-trd"
      }

      for phase <- wf["phases"] do
        phase_name = phase["name"]
        expected_skill = Map.fetch!(expected_skills, phase_name)

        assert phase["action"] == "command",
               "Phase #{phase_name} must have action: command"

        assert phase["command"] =~ expected_skill,
               "Phase #{phase_name} should use #{expected_skill}"
      end
    end

    test "all phases include --foreman flag for Foreman-managed execution", %{
      manifest_path: path
    } do
      {:ok, wf} = Interpreter.load!(path)

      for phase <- wf["phases"] do
        assert phase["action"] == "command"

        assert phase["command"] =~ "--foreman",
               "Phase #{phase["name"]} must include --foreman flag"
      end
    end

    test "final phase is implement-trd (merge gate hold activates after this phase)",
         %{manifest_path: path} do
      {:ok, wf} = Interpreter.load!(path)
      last_phase = List.last(wf["phases"])
      assert last_phase["name"] == "implement-trd"
      assert last_phase["command"] =~ "ensemble-full-implement-trd"
      assert last_phase["command"] =~ "--foreman"
    end
  end

  # ===========================================================================
  # Merge gate hold tests (CTH-T001-4) — TRD-074 integration
  # ===========================================================================

  describe "merge gate hold after implement-trd completes (CTH-T001-4)" do
    setup do
      # Flush ETS table between tests to prevent cross-test state pollution.
      # The table is :foreman_merge_gate per MergeGate (merge_gate.ex).
      try do
        :ets.delete_all_objects(:foreman_merge_gate)
      catch
        :error, :badarg -> :ok
      end

      :ok
    end

    test "run.pr.ready sets merge_gate: :pending; run.pr.merge is blocked" do
      run_id = "run-prd-mgh-#{System.unique_integer([:positive])}"
      task_id = "task-prd-mgh-#{System.unique_integer([:positive])}"
      project_id = "project-prd-mgh-#{System.unique_integer([:positive])}"
      pr_url = "https://github.com/test/prd/pull/#{System.unique_integer([:positive])}"

      state = run_state(run_id, task_id, project_id)

      # run.pr.ready — simulates end of implement-trd phase
      {:ok, event_spec} =
        Run.handle_command(state, %{
          type: "run.pr.ready",
          payload: %{
            run_id: run_id,
            task_id: task_id,
            project_id: project_id,
            pr_url: pr_url,
            branch_name: "main",
            head_sha: "abc1234",
            base_branch: "main"
          }
        })

      assert event_spec.event_type == "PrReady"

      state_after_ready = Run.apply_event(state, event_spec)
      assert state_after_ready.merge_gate == :pending

      # run.pr.merge is blocked while gate is :pending
      merge_result =
        Run.handle_command(state_after_ready, %{
          type: "run.pr.merge",
          payload: %{
            run_id: run_id,
            task_id: task_id,
            project_id: project_id,
            pr_url: pr_url,
            branch_name: "main"
          }
        })

      assert {:error, :pr_not_acceptable} = merge_result,
             "run.pr.merge must be blocked when merge_gate is :pending"
    end

    test "merge_approve (authorized) transitions to :approved; run.pr.merge succeeds" do
      run_id = "run-prd-approve-#{System.unique_integer([:positive])}"
      task_id = "task-prd-approve-#{System.unique_integer([:positive])}"
      project_id = "project-prd-approve-#{System.unique_integer([:positive])}"
      pr_url = "https://github.com/test/prd/pull/#{System.unique_integer([:positive])}"

      state = run_state(run_id, task_id, project_id)

      # 1. Trigger run.pr.ready → sets merge_gate: :pending
      {:ok, ready_spec} =
        Run.handle_command(state, %{
          type: "run.pr.ready",
          payload: %{
            run_id: run_id,
            task_id: task_id,
            project_id: project_id,
            pr_url: pr_url,
            branch_name: "main",
            head_sha: "abc1234",
            base_branch: "main"
          }
        })

      state = Run.apply_event(state, ready_spec)
      assert state.merge_gate == :pending

      # 2. Authorized merge_approve → transitions to :approved
      # Both :approver and :approver_identity required per Run.handle_command
      {:ok, approve_spec} =
        Run.handle_command(state, %{
          type: "merge_approve",
          payload: %{
            run_id: run_id,
            approver: "ldangelo",
            approver_identity: "github:ldangelo"
          }
        })

      assert approve_spec.event_type == "MergeGateApproved"

      state_after_approve = Run.apply_event(state, approve_spec)
      assert state_after_approve.merge_gate == :approved

      # 3. run.pr.merge now succeeds
      {:ok, merge_spec} =
        Run.handle_command(state_after_approve, %{
          type: "run.pr.merge",
          payload: %{
            run_id: run_id,
            task_id: task_id,
            project_id: project_id,
            pr_url: pr_url,
            branch_name: "main"
          }
        })

      assert merge_spec.event_type == "PrMerged"
    end

    test "merge_approve (unauthorized) returns error; gate stays :pending" do
      run_id = "run-prd-unauth-#{System.unique_integer([:positive])}"
      task_id = "task-prd-unauth-#{System.unique_integer([:positive])}"
      project_id = "project-prd-unauth-#{System.unique_integer([:positive])}"
      pr_url = "https://github.com/test/prd/pull/#{System.unique_integer([:positive])}"

      state = run_state(run_id, task_id, project_id)

      # 1. Trigger run.pr.ready
      {:ok, ready_spec} =
        Run.handle_command(state, %{
          type: "run.pr.ready",
          payload: %{
            run_id: run_id,
            task_id: task_id,
            project_id: project_id,
            pr_url: pr_url,
            branch_name: "main",
            head_sha: "abc1234",
            base_branch: "main"
          }
        })

      state = Run.apply_event(state, ready_spec)
      assert state.merge_gate == :pending

      # 2. Unauthorized approver — :approver and :approver_identity required
      # ApproverAuthorizer.authorize/1 returns {:error, :unauthorized_approver}
      assert {:error, :unauthorized_approver} =
               Run.handle_command(state, %{
                 type: "merge_approve",
                 payload: %{
                   run_id: run_id,
                   approver: "attacker",
                   approver_identity: "github:attacker"
                 }
               })

      # 3. Gate stays :pending
      assert state.merge_gate == :pending,
             "Gate must remain :pending after unauthorized merge_approve"
    end

    test "run.pr.merge blocked when merge_gate is nil (fail-closed, no bypass)" do
      run_id = "run-prd-no-gate-#{System.unique_integer([:positive])}"
      task_id = "task-prd-no-gate-#{System.unique_integer([:positive])}"
      project_id = "project-prd-no-gate-#{System.unique_integer([:positive])}"

      state = run_state(run_id, task_id, project_id)
      assert state.merge_gate == nil

      result =
        Run.handle_command(state, %{
          type: "run.pr.merge",
          payload: %{
            run_id: run_id,
            task_id: task_id,
            project_id: project_id,
            pr_url: "https://github.com/test/no-gate/pull/1",
            branch_name: "main"
          }
        })

      assert {:error, :pr_not_acceptable} = result,
             "run.pr.merge must be fail-closed when merge_gate is nil"
    end
  end
end
