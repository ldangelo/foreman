defmodule ForemanServer.Idempotency.ResumptionTimeTest do
  @moduledoc """
  TRD-080 / RTE-T006 — NFR-03 Verification: crash recovery ≤30 seconds to resumption.

  Crash recovery involves multiple layers:

    1. Idempotency layer — `CrashRecovery.reconcile/1` (this file)
       Determines whether a crashed operation should skip, retry fresh, or
       retry after checking side effects. Must decide within ≤30s.

    2. EventStore replay — aggregate state rebuilt from event stream on
       GenServer restart. Tested in aggregate integration tests.

    3. ProjectionStore rebuild — projectors replay from EventStore on
       startup. Tested in projector integration tests.

    4. RunExecutor re-entry — workflow resumes from the last checkpoint.
       Tested in `crash_recovery_characterization_test.exs` (TRD-079).

  This test exercises layer 1 (the decision layer) under the NFR-03
  threshold. Layer 1 is the critical path: if `reconcile/1` times out,
  the entire recovery pipeline stalls.

  NFR-03 contract:
    - REQ-017: crash recovery safety (no duplicate side effects)
    - NFR-03: ≤30 000 ms from reconcile/1 call to decision
    - RTE-T004: 5-restart backoff (TRD-078)
    - RTE-T006: this verification (TRD-080)
  """

  use ExUnit.Case, async: false
  @moduletag :nfr
  @moduletag :capture_log

  alias ForemanServer.Idempotency.{CrashRecovery, KeyStore}
  alias ForemanServer.{CommandRouter, Incarnation, ProjectionStore, RunAdmission}
  alias ForemanServer.TestSupport.{RunSlotsReset, UniqueIds}
  alias ForemanServer.Workflow.RunExecutor

  @resumption_target_ms 30_000

  # ---------------------------------------------------------------------------
  # NFR-03: ≤30s recovery decision for each reconcile path
  # ---------------------------------------------------------------------------

  describe "NFR-03: crash recovery ≤30 seconds to resumption" do
    setup do
      {:ok, _} = KeyStore.ensure_started()
      ForemanServer.TestSupport.KeyStoreReset.reset!()
      :ok
    end

    test "ambiguous key: side-effects check decides within 30s" do
      :ok = KeyStore.mark_ambiguous("k-resume-ambiguous")

      {time_us, result} =
        :timer.tc(fn ->
          CrashRecovery.reconcile("k-resume-ambiguous", fn _ -> true end)
        end)

      time_ms = div(time_us, 1000)

      assert time_ms < @resumption_target_ms,
             "NFR-03 violated: ambiguous recovery took #{time_ms}ms (limit: #{@resumption_target_ms}ms)"

      assert match?({:retry, :no_side_effects}, result),
             "expected {:retry, :no_side_effects}, got #{inspect(result)}"
    end

    test "completed key: skip decision within 30s (fastest path)" do
      :ok = KeyStore.mark_completed("k-resume-completed")

      {time_us, result} =
        :timer.tc(fn ->
          CrashRecovery.reconcile("k-resume-completed")
        end)

      time_ms = div(time_us, 1000)

      assert time_ms < @resumption_target_ms,
             "NFR-03 violated: completed recovery took #{time_ms}ms (limit: #{@resumption_target_ms}ms)"

      assert {:skip, :already_completed} = result
    end

    test "fresh key: retry decision within 30s (no prior state)" do
      {time_us, result} =
        :timer.tc(fn ->
          CrashRecovery.reconcile("k-resume-fresh-#{:rand.uniform(1_000_000)}")
        end)

      time_ms = div(time_us, 1000)

      assert time_ms < @resumption_target_ms,
             "NFR-03 violated: fresh recovery took #{time_ms}ms (limit: #{@resumption_target_ms}ms)"

      assert {:retry, :fresh} = result
    end

    test "started-but-unknown key: retry within 30s" do
      :ok = KeyStore.mark_started("k-resume-started")

      {time_us, result} =
        :timer.tc(fn ->
          CrashRecovery.reconcile("k-resume-started")
        end)

      time_ms = div(time_us, 1000)

      assert time_ms < @resumption_target_ms,
             "NFR-03 violated: started-key recovery took #{time_ms}ms (limit: #{@resumption_target_ms}ms)"

      assert {:retry, :unknown_state} = result
    end
  end

  # ---------------------------------------------------------------------------
  # AC-002-4: every resumed run records its boot-to-resumed time
  # ---------------------------------------------------------------------------

  describe "AC-002-4: boot-to-resumed time is recorded for every resumed run" do
    @interrupted_runs 5

    setup do
      :ok = ForemanServer.DispatcherQuiesce.suspend!()
      RunSlotsReset.reset!()
      :ok
    end

    test "resuming N interrupted runs records a duration on each, within the target" do
      project_id = "project-nfr-#{System.unique_integer([:positive])}"
      repo = Path.join(System.tmp_dir!(), "nfr-resume-#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo)
      on_exit(fn -> File.rm_rf(repo) end)

      {:ok, _} =
        CommandRouter.dispatch(%{
          type: "project.register",
          payload: %{project_id: project_id, path: repo},
          aggregate_id: "project:#{project_id}"
        })

      run_ids =
        for _ <- 1..@interrupted_runs do
          run_id = UniqueIds.unique_run_id("nfr-resume")

          {:ok, _} =
            RunAdmission.start(project_id, %{
              run_id: run_id,
              task_id: "task-#{run_id}",
              workflow_snapshot: %{phases: []},
              phase_specs: []
            })

          run_id
        end

      {time_us, results} =
        :timer.tc(fn ->
          Enum.map(run_ids, &RunExecutor.__resume_prelude_for_test__(resume_state(&1, repo)))
        end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert div(time_us, 1000) < @resumption_target_ms

      now_since_boot = System.monotonic_time(:millisecond) - Incarnation.started_at_ms()

      for run_id <- run_ids do
        assert %{outcome: "resumed", elapsed_since_boot_ms: elapsed} =
                 await_recovery(run_id),
               "run #{run_id} recorded no resumption time"

        assert elapsed >= 0 and elapsed <= now_since_boot
      end
    end
  end

  defp resume_state(run_id, repo) do
    %{
      run_id: run_id,
      task: %{task_id: "task-#{run_id}"},
      resuming?: true,
      resume_from: 0,
      phase_specs: [%{name: "only"}],
      worktree_spec: %{},
      plan_context: %{
        "source_revision" => "0000000000000000000000000000000000000000",
        "project_root" => repo,
        "implementation_key" => "test-key"
      }
    }
  end

  defp await_recovery(run_id, tries \\ 100) do
    case Map.get(ProjectionStore.run(run_id) || %{}, :recovery) do
      nil when tries > 0 ->
        Process.sleep(20)
        await_recovery(run_id, tries - 1)

      recovery ->
        recovery
    end
  end
end
