defmodule ForemanServer.Workflow.RunExecutorResumeAttemptTest do
  @moduledoc """
  A restart that finds the resume phase still `in_progress` is one more attempt
  at it. `RunExecutor` records that as a `PhaseRetried` (`reason: "resumed"`)
  after `rehydrate_resume_context/1` has reaped orphaned agents, through the
  real command gateway, aggregate and projection.

  The command id carries `Incarnation.id()`: a repeat within one boot appends
  nothing, every restart appends a new `PhaseRetried`. A second boot is
  simulated by erasing the incarnation persistent term, which `id/0` recreates
  on next use.

  Only `OrphanReaper.reap/1` is replaced, to observe WHEN the reap runs; it
  would otherwise scan the machine's processes.
  """

  use ExUnit.Case, async: false
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias ForemanServer.{CommandGateway, Identity, Incarnation, ProjectionStore}
  alias ForemanServer.Aggregate.Actor
  alias ForemanServer.MCP.Tools
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.TestSupport.{MeckScope, UniqueIds}
  alias ForemanServer.Workflow.{OrphanReaper, RunExecutor}

  @incarnation_key {Incarnation, :id}
  @started_at_key {Incarnation, :started_at_ms}

  setup_all do
    MeckScope.new_once!(OrphanReaper)
  end

  setup do
    :ok = ForemanServer.DispatcherQuiesce.suspend!()
    MeckScope.restore_on_exit!(OrphanReaper)

    original = :persistent_term.get(@incarnation_key, nil)
    original_started_at = :persistent_term.get(@started_at_key, nil)

    on_exit(fn ->
      if original, do: :persistent_term.put(@incarnation_key, original)
      if original_started_at, do: :persistent_term.put(@started_at_key, original_started_at)
    end)

    run_id = UniqueIds.unique_run_id("resume-attempt")
    repo = Path.join(System.tmp_dir!(), "resume-attempt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf(repo) end)

    parent = self()

    :meck.expect(OrphanReaper, :reap, fn path ->
      send(parent, {:reaped, path, phase_attempt(run_id)})
      {:ok, []}
    end)

    ForemanServer.TestSupport.RunSlotsReset.reset!()
    project_id = "project-resume-run-#{System.unique_integer([:positive])}"

    {:ok, _} =
      ForemanServer.CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{project_id: project_id, path: repo},
        aggregate_id: "project:#{project_id}"
      })

    admit_run!(project_id, run_id)

    %{
      run_id: run_id,
      repo: repo,
      phase_id: Identity.phase_id(run_id, 1),
      admission_project_id: project_id
    }
  end

  describe "resume of an in-flight phase" do
    test "reaps first, then records attempt 2; the same boot appends nothing more", ctx do
      start_phase!(ctx)
      seed_worktree!(ctx)

      assert {:ok, _state} = RunExecutor.__resume_prelude_for_test__(state(ctx))

      # The reap ran while the phase was still on attempt 1: it precedes PhaseRetried.
      wt = worktree_dir(ctx)
      assert_received {:reaped, ^wt, 1}
      assert_attempt(ctx.run_id, 2)
      assert retried_count(ctx) == 1

      assert {:ok, _state} = RunExecutor.__resume_prelude_for_test__(state(ctx))

      assert_attempt(ctx.run_id, 2)
      assert retried_count(ctx) == 1
    end

    test "a second boot appends another PhaseRetried and advances to attempt 3", ctx do
      start_phase!(ctx)
      seed_worktree!(ctx)

      assert {:ok, _} = RunExecutor.__resume_prelude_for_test__(state(ctx))
      assert_attempt(ctx.run_id, 2)

      :persistent_term.erase(@incarnation_key)

      assert {:ok, _} = RunExecutor.__resume_prelude_for_test__(state(ctx))

      assert_attempt(ctx.run_id, 3)
      assert retried_count(ctx) == 2
    end

    test "with no worktree entry the attempt is recorded without a reap and the gap is logged",
         ctx do
      start_phase!(ctx)

      log =
        capture_log(fn ->
          assert {:ok, _} = RunExecutor.__resume_prelude_for_test__(state(ctx))
        end)

      assert log =~ "resume found no worktree entry"
      refute_received {:reaped, _, _}
      assert_attempt(ctx.run_id, 2)
      assert retried_count(ctx) == 1
    end
  end

  describe "a worktree record git cannot prune" do
    test "is its own error, not :resume_context_unresolvable, and keeps its payload", ctx do
      start_phase!(ctx)
      seed_worktree!(ctx)
      # The directory is gone and `ctx.repo` is not a git repository, so `git worktree prune`
      # fails there.
      File.rm_rf!(worktree_dir(ctx))

      assert {:error, {:resume_worktree_prune_failed, repo_path, code, output}} =
               RunExecutor.__resume_prelude_for_test__(state(ctx))

      assert repo_path == ctx.repo
      assert is_integer(code) and code != 0
      assert output =~ "not a git repository"
    end
  end

  describe "resume of a phase that is not in flight" do
    test "dispatches no phase.retry when the phase never started", ctx do
      seed_run!(ctx)

      assert {:ok, _} = RunExecutor.__resume_prelude_for_test__(state(ctx))

      assert retried_count(ctx) == 0
    end

    test "dispatches no phase.retry when the phase already completed", ctx do
      start_phase!(ctx)

      {:ok, _} =
        CommandGateway.dispatch_system(%{
          type: "phase.complete",
          command_id: "test:complete:#{ctx.phase_id}",
          aggregate_id: aggregate_id(ctx),
          payload: %{
            phase_id: ctx.phase_id,
            run_id: ctx.run_id,
            index: 1,
            artifact_path: "p.md",
            artifact_sha256: String.duplicate("a", 64),
            artifact_bytes: 1
          }
        })

      await(fn -> phase_status(ctx.run_id) == "completed" end)

      assert {:ok, _} = RunExecutor.__resume_prelude_for_test__(state(ctx))

      assert retried_count(ctx) == 0
    end

    test "a fresh (non-resuming) run records nothing", ctx do
      start_phase!(ctx)

      assert {:ok, _} =
               RunExecutor.__resume_prelude_for_test__(%{state(ctx) | resuming?: false})

      assert retried_count(ctx) == 0
      assert_attempt(ctx.run_id, 1)
    end
  end

  describe "run recovery record (AC-002-4)" do
    setup ctx do
      handler = "resumed-#{ctx.run_id}"
      parent = self()

      :telemetry.attach(
        handler,
        [:foreman_server, :workflow, :run_executor, :resumed],
        fn _event, measurements, metadata, _ ->
          send(parent, {:resumed_telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "a resumed run records one `resumed` with the monotonic time since boot, reported once",
         ctx do
      start_phase!(ctx)
      before_ms = System.monotonic_time(:millisecond)

      assert {:ok, _} = RunExecutor.__resume_prelude_for_test__(state(ctx))

      after_ms = System.monotonic_time(:millisecond)
      await(fn -> recovery(ctx.run_id) != nil end)

      assert %{outcome: "resumed", elapsed_since_boot_ms: elapsed} = recovery(ctx.run_id)
      # A monotonic difference against the application start, never a wall clock.
      assert elapsed >= before_ms - Incarnation.started_at_ms()
      assert elapsed <= after_ms - Incarnation.started_at_ms()
      assert recovery_events(ctx) == 1
      assert_received {:resumed_telemetry, %{elapsed_since_boot_ms: ^elapsed}, %{run_id: run_id}}
      assert run_id == ctx.run_id

      assert %{recovery: %{outcome: "resumed", elapsed_since_boot_ms: ^elapsed}} =
               run_status!(ctx.run_id)

      # The same resume again in this boot: one record, one telemetry event, and the
      # command id (workflow:executor:run.recovery_attempt:<run>:<incarnation>) is answered
      # as a replay.
      assert {:ok, _} = RunExecutor.__resume_prelude_for_test__(state(ctx))
      assert recovery_events(ctx) == 1
      refute_received {:resumed_telemetry, _, _}

      assert {:ok, answer} =
               CommandGateway.dispatch_system(%{
                 type: "run.recovery_attempt",
                 command_id:
                   "workflow:executor:run.recovery_attempt:#{ctx.run_id}:#{Incarnation.id()}",
                 aggregate_id: "run:#{ctx.run_id}",
                 payload: %{run_id: ctx.run_id, outcome: "resumed", elapsed_since_boot_ms: 1}
               })

      assert Actor.replayed?(answer)
      assert recovery_events(ctx) == 1
    end

    test "a new boot records a second `resumed`", ctx do
      start_phase!(ctx)

      assert {:ok, _} = RunExecutor.__resume_prelude_for_test__(state(ctx))
      await(fn -> recovery(ctx.run_id) != nil end)
      first = recovery(ctx.run_id).elapsed_since_boot_ms

      :persistent_term.erase(@incarnation_key)

      assert {:ok, _} = RunExecutor.__resume_prelude_for_test__(state(ctx))

      assert recovery_events(ctx) == 2
      assert %{outcome: "resumed", elapsed_since_boot_ms: second} = recovery(ctx.run_id)
      assert is_integer(first) and is_integer(second)
    end

    test "a resume records even when no phase is in flight; a run that is not resumed has none",
         ctx do
      assert {:ok, _} = RunExecutor.__resume_prelude_for_test__(%{state(ctx) | resuming?: false})
      assert recovery_events(ctx) == 0
      refute Map.has_key?(ProjectionStore.run(ctx.run_id), :recovery)
      assert %{recovery: nil} = run_status!(ctx.run_id)

      assert {:ok, _} = RunExecutor.__resume_prelude_for_test__(state(ctx))

      assert recovery_events(ctx) == 1
      assert retried_count(ctx) == 0
    end

    test "a terminal run cannot record recovery: the resume stops and appends nothing", ctx do
      {:ok, _} =
        CommandGateway.dispatch_system(%{
          type: "run.fail",
          command_id: "test:fail:#{ctx.run_id}",
          aggregate_id: "run:#{ctx.run_id}",
          payload: %{run_id: ctx.run_id, reason: "boom"}
        })

      assert {:error, {:resume_attempt_not_recorded, {:run_terminal, "failed"}}} =
               RunExecutor.__resume_prelude_for_test__(state(ctx))

      assert recovery_events(ctx) == 0
    end
  end

  describe "resume against a real git repository (AC-002-5)" do
    test "no worktree entry: the discard has no path and rides the resumed PhaseRetried", ctx do
      ctx = real_repo!(ctx)
      name = "wt-" <> ctx.run_id

      log =
        capture_log(fn ->
          assert {:ok, state} = RunExecutor.__resume_prelude_for_test__(real_state(ctx))
          # Carried by the retry, so cleared: nothing repeats it later.
          refute Map.has_key?(state, :prior_worktree_discarded)
        end)

      assert log =~ name
      assert_attempt(ctx.run_id, 2)

      assert %{prior_worktree_discarded: %{name: ^name, path: nil}} = phase(ctx.run_id)

      assert %{current_phase: %{index: 1, prior_worktree_discarded: %{name: ^name, path: nil}}} =
               run_status!(ctx.run_id)

      # The fresh worktree is provisioned against the real repository.
      record = provision_worktree!(ctx)
      assert File.dir?(record.worktree_path)
      assert git!(record.worktree_path, ["rev-parse", "--abbrev-ref", "HEAD"]) == record.branch
    end

    test "an entry whose directory is gone while git still lists it is re-provisioned", ctx do
      ctx = real_repo!(ctx)
      name = "wt-" <> ctx.run_id

      record = provision_worktree!(ctx)
      path = record.worktree_path

      File.write!(Path.join(path, "committed.txt"), "kept")
      git!(path, ["add", "committed.txt"])
      git!(path, ["commit", "--no-gpg-sign", "-m", "work", "--quiet"])
      File.write!(Path.join(path, "uncommitted.txt"), "lost")

      File.rm_rf!(path)
      refute File.exists?(path)
      assert listed_worktrees(ctx.repo) =~ path

      state = real_state(ctx)

      log =
        capture_log(fn ->
          assert {:ok, state} = RunExecutor.__resume_prelude_for_test__(state)
          send(self(), {:state, state})
        end)

      assert_received {:state, state}

      # Named in the warning, with the path the entry recorded.
      assert log =~ name
      assert log =~ path

      # The entry is not rehydrated, so the run is not ended with `:run_worktree_vanished`.
      refute Map.has_key?(state, :run_worktree)
      refute Map.has_key?(state, :prior_worktree_discarded)
      refute_received {:reaped, _, _}

      assert_attempt(ctx.run_id, 2)
      assert %{prior_worktree_discarded: %{name: ^name, path: ^path}} = phase(ctx.run_id)

      assert %{current_phase: %{prior_worktree_discarded: %{name: ^name, path: ^path}}} =
               run_status!(ctx.run_id)

      # Git's record of the missing worktree was pruned, so provisioning succeeds.
      refute listed_worktrees(ctx.repo) =~ path
      assert {:ok, fresh} = RunExecutor.__ensure_run_worktree_for_test__(state, 1)
      assert fresh.worktree_path == path
      assert File.read!(Path.join(path, "committed.txt")) == "kept"
      refute File.exists?(Path.join(path, "uncommitted.txt"))
    end

    test "an entry whose directory is present discards nothing", ctx do
      ctx = real_repo!(ctx)
      record = provision_worktree!(ctx)
      path = record.worktree_path
      File.write!(Path.join(path, "pending.txt"), "still here")

      log =
        capture_log(fn ->
          assert {:ok, state} = RunExecutor.__resume_prelude_for_test__(real_state(ctx))
          assert %{run_worktree: %{worktree_path: ^path}} = state
          refute Map.has_key?(state, :prior_worktree_discarded)
        end)

      refute log =~ "uncommitted changes are lost"
      assert_received {:reaped, ^path, _}
      assert_attempt(ctx.run_id, 2)

      refute Map.has_key?(phase(ctx.run_id), :prior_worktree_discarded)
      assert %{current_phase: %{prior_worktree_discarded: nil}} = run_status!(ctx.run_id)
      assert File.read!(Path.join(path, "pending.txt")) == "still here"
    end

    test "a later phase of the same run does not repeat the discard", ctx do
      ctx = real_repo!(ctx)
      state = real_state(ctx)

      capture_log(fn ->
        assert {:ok, state} = RunExecutor.__resume_prelude_for_test__(state)
        send(self(), {:state, state})
      end)

      assert_received {:state, state}
      assert_attempt(ctx.run_id, 2)

      [_, second] = state.phase_specs
      assert {:ok, _state, _record} = RunExecutor.phase_begin(state, second, 1)

      second_phase = Enum.find(ProjectionStore.phases_for_run(ctx.run_id), &(&1.index == 2))
      assert second_phase.status == "in_progress"
      refute Map.has_key?(second_phase, :prior_worktree_discarded)
      assert %{prior_worktree_discarded: %{path: nil}} = phase(ctx.run_id)
    end

    test "with no phase in flight the discard rides the PhaseStarted of the resume phase", ctx do
      ctx = real_repo!(ctx)
      # Phase 1 never started: undo the in-flight phase by using a second run.
      run_id = UniqueIds.unique_run_id("resume-attempt")
      ctx = %{ctx | run_id: run_id, phase_id: Identity.phase_id(run_id, 1)}
      admit_run!(ctx.admission_project_id, run_id)
      seed_run!(ctx)
      name = "wt-" <> run_id

      capture_log(fn ->
        assert {:ok, state} = RunExecutor.__resume_prelude_for_test__(real_state(ctx))
        assert state.prior_worktree_discarded == %{name: name, path: nil}
        send(self(), {:state, state})
      end)

      assert_received {:state, state}
      assert retried_count(ctx) == 0

      assert {:ok, state, _record} = RunExecutor.phase_begin(state, hd(state.phase_specs), 0)
      refute Map.has_key?(state, :prior_worktree_discarded)

      assert %{status: "in_progress", attempt: 1, prior_worktree_discarded: %{name: ^name}} =
               phase(run_id)
    end
  end

  describe "PhaseStarted decoding" do
    test "an event recorded before the field existed decodes with no discard" do
      assert %ForemanServer.Events.PhaseStarted{prior_worktree_discarded: nil, attempt: 1} =
               ForemanServer.EventCodec.decode!("PhaseStarted", %{
                 run_id: "r1",
                 phase_id: "p1",
                 index: 1,
                 name: "dev",
                 attempt: 1,
                 artifact_template: %{}
               })
    end

    test "a replayed event carries the discard with string keys and folds to one shape", ctx do
      run_id = ctx.run_id
      phase_id = ctx.phase_id
      seed_run!(ctx)

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "PhaseStarted",
            payload: %{
              "run_id" => run_id,
              "phase_id" => phase_id,
              "index" => 1,
              "name" => "only",
              "attempt" => 1,
              "artifact_template" => %{},
              "prior_worktree_discarded" => %{"name" => "wt-x", "path" => "/gone"}
            }
          }
        ])

      assert %{prior_worktree_discarded: %{name: "wt-x", path: "/gone"}} = phase(run_id)
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp state(ctx) do
    %{
      run_id: ctx.run_id,
      task: %{task_id: "task-#{ctx.run_id}"},
      resuming?: true,
      resume_from: 0,
      phase_specs: [%{name: "only"}],
      worktree_spec: %{},
      plan_context: %{
        "source_revision" => "0000000000000000000000000000000000000000",
        "project_root" => ctx.repo,
        "implementation_key" => "test-key"
      }
    }
  end

  # The run's own stream, through the production admission path: the
  # `run.recovery_attempt` command needs a run that exists.
  defp admit_run!(project_id, run_id) do
    case ForemanServer.RunAdmission.start(project_id, %{
           run_id: run_id,
           task_id: "task-#{run_id}",
           workflow_snapshot: %{phases: []},
           phase_specs: []
         }) do
      {:ok, queued} when queued in [:queued, :slot_queued] ->
        flunk("run #{run_id} was queued, not started: it has no run stream to record on")

      {:ok, _started} ->
        :ok
    end
  end

  defp aggregate_id(ctx), do: "phase:#{ctx.run_id}:#{ctx.phase_id}"

  defp seed_run!(ctx) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunStarted",
          payload: %{
            run_id: ctx.run_id,
            project_id: Map.get(ctx, :project_id, "project-#{ctx.run_id}"),
            task_id: "task-#{ctx.run_id}",
            workflow_snapshot: %{}
          }
        }
      ])
  end

  # PhaseStarted through the real gateway, so the Phase aggregate stream and
  # the projection both hold an in-flight attempt 1.
  defp start_phase!(ctx) do
    seed_run!(ctx)

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "phase.start",
        command_id: "workflow:executor:phase.start:#{ctx.run_id}:#{ctx.phase_id}",
        aggregate_id: aggregate_id(ctx),
        payload: %{
          run_id: ctx.run_id,
          phase_id: ctx.phase_id,
          index: 1,
          name: "only",
          attempt: 1,
          artifact_template: %{}
        }
      })

    await(fn -> phase_status(ctx.run_id) == "in_progress" end)
  end

  # The entry's directory exists, so resume reuses it; a directory that is gone is the
  # re-provisioning case, covered against a real repository below.
  defp worktree_dir(ctx), do: Path.join(ctx.repo, "wt")

  defp seed_worktree!(ctx) do
    File.mkdir_p!(worktree_dir(ctx))

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "WorktreeCreated",
          payload: %{
            operation_id: "wt-" <> ctx.run_id,
            project_id: "project-#{ctx.run_id}",
            run_id: ctx.run_id,
            phase_id: ctx.phase_id,
            repo_path: ctx.repo,
            worktree_path: worktree_dir(ctx),
            branch: "foreman/#{ctx.run_id}",
            base_ref: "0000000000000000000000000000000000000000",
            cleanup: "never"
          }
        }
      ])
  end

  # -- real git repository -----------------------------------------------------

  # A registered project whose checkout is a real git repository, a run of it, and an
  # in-flight phase 1. Run worktrees live under the real `~/.foreman/worktrees/<project>`,
  # so the directory is removed on exit.
  defp real_repo!(ctx) do
    project_id = "proj-resume-#{System.unique_integer([:positive])}"
    git!(ctx.repo, ["init", "--initial-branch=main", "--quiet"])
    git!(ctx.repo, ["config", "user.email", "t@x"])
    git!(ctx.repo, ["config", "user.name", "T"])
    File.write!(Path.join(ctx.repo, "README.md"), "seed")
    git!(ctx.repo, ["add", "."])
    git!(ctx.repo, ["commit", "--no-gpg-sign", "-m", "seed", "--quiet"])

    on_exit(fn ->
      File.rm_rf(Path.join(ForemanServer.Workflow.RunWorktreeLayout.base_root(), project_id))
    end)

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: project_id, path: ctx.repo}}
      ])

    ctx = Map.put(ctx, :project_id, project_id)
    start_phase!(ctx)
    ctx
  end

  # The executor state of a resumed run of that project: the run's base is the checkout's HEAD,
  # and phase 1 is the resume phase.
  defp real_state(ctx) do
    %{
      run_id: ctx.run_id,
      task: %{task_id: "task-#{ctx.run_id}", project_id: ctx.project_id},
      resuming?: true,
      resume_from: 0,
      phase_specs: [%{name: "only"}, %{name: "second"}],
      worktree_spec: %{},
      plan_context: nil,
      artifact_base: Path.join(ctx.repo, "artifacts")
    }
  end

  # Provisions the run's worktree through the production path (`Worktree.create/1` ->
  # CommandGateway -> event store -> projection).
  defp provision_worktree!(ctx) do
    assert {:ok, record} = RunExecutor.__create_run_worktree_for_test__(real_state(ctx), 1)
    record
  end

  defp listed_worktrees(repo), do: git!(repo, ["worktree", "list", "--porcelain"])

  defp run_status!(run_id) do
    assert {:ok, dto} = Tools.call_tool("foreman_run_status", %{run_id: run_id})
    dto
  end

  defp git!(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}) in #{dir}: #{out}")
    end
  end

  defp phase(run_id), do: Enum.find(ProjectionStore.phases_for_run(run_id), &(&1.index == 1))
  defp phase_attempt(run_id), do: with(%{attempt: a} <- phase(run_id), do: a)
  defp phase_status(run_id), do: with(%{status: s} <- phase(run_id), do: s)

  defp retried_count(ctx) do
    case Store.read_stream_forward(aggregate_id(ctx), 0, 50) do
      {:ok, events} -> Enum.count(events, &(&1.event_type == "PhaseRetried"))
      {:error, :stream_not_found} -> 0
    end
  end

  defp recovery(run_id), do: Map.get(ProjectionStore.run(run_id), :recovery)

  defp recovery_events(ctx) do
    case Store.read_stream_forward("run:#{ctx.run_id}", 0, 100) do
      {:ok, events} -> Enum.count(events, &(&1.event_type == "RunRecoveryAttempted"))
      {:error, :stream_not_found} -> 0
    end
  end

  defp assert_attempt(run_id, expected) do
    await(fn -> phase_attempt(run_id) == expected end)
    assert phase_attempt(run_id) == expected
  end

  defp await(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && await(fun, tries - 1)
    end
  end
end
