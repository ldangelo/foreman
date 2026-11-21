defmodule ForemanServer.Workflow.RunExecutorResumeContextTest do
  @moduledoc """
  AC-002-3: a resumed run whose base ref cannot be resolved ends with the
  terminal reason `{:resume_context_unresolvable, _}` and starts no phase. It is
  never cut from a guessed base (the project's `HEAD` or default branch).

  Real git repository, real command gateway, aggregates and projection. Only
  `OrphanReaper.reap/1` is replaced: it would otherwise scan the machine's
  processes, and the base is resolved after it in the entry-present path.

  `RunExecutor.__handle_kickoff_ready_for_test__/1` is the production
  `handle_kickoff_ready/1` called directly; it bypasses only the provider and
  model preflight that runs before it in `kickoff_preflight/1`.
  """

  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias ForemanServer.{CommandGateway, Identity, ProjectionStore}
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.TestSupport.{MeckScope, UniqueIds}
  alias ForemanServer.Workflow.{OrphanReaper, RunExecutor}

  @missing_base "refs/heads/no-such-base"

  setup_all do
    MeckScope.new_once!(OrphanReaper)
  end

  setup do
    :ok = ForemanServer.DispatcherQuiesce.suspend!()
    MeckScope.restore_on_exit!(OrphanReaper)
    :meck.expect(OrphanReaper, :reap, fn _path -> {:ok, []} end)

    run_id = UniqueIds.unique_run_id("resume-context")
    repo = Path.join(System.tmp_dir!(), "resume-context-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    init_repo!(repo)

    project_id = "proj-resume-context-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      File.rm_rf(repo)
      File.rm_rf(Path.join(ForemanServer.Workflow.RunWorktreeLayout.base_root(), project_id))
    end)

    ForemanServer.TestSupport.RunSlotsReset.reset!()

    {:ok, _} =
      ForemanServer.CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{project_id: project_id, path: repo},
        aggregate_id: "project:#{project_id}"
      })

    admit_run!(project_id, run_id)

    ctx = %{
      run_id: run_id,
      repo: repo,
      project_id: project_id,
      phase_id: Identity.phase_id(run_id, 1)
    }

    start_phase!(ctx)
    %{ctx: ctx}
  end

  describe "a base that cannot be resolved" do
    test "with the worktree on disk, recovery fails with :resume_context_unresolvable",
         %{ctx: ctx} do
      seed_worktree!(ctx)

      assert {:error, {:resume_context_unresolvable, {:worktree_base_unresolvable, base, _}}} =
               RunExecutor.__resume_prelude_for_test__(state(ctx, %{base: @missing_base}))

      assert base == @missing_base
    end

    test "with no worktree entry, recovery fails instead of provisioning from another base",
         %{ctx: ctx} do
      assert {:error, {:resume_context_unresolvable, {:worktree_base_unresolvable, _, _}}} =
               RunExecutor.__resume_prelude_for_test__(state(ctx, %{base: @missing_base}))

      assert_nothing_recorded(ctx)
    end

    test "with the worktree directory gone, recovery fails instead of provisioning from another base",
         %{ctx: ctx} do
      seed_worktree!(ctx)
      File.rm_rf!(worktree_dir(ctx))

      assert {:error, {:resume_context_unresolvable, {:worktree_base_unresolvable, _, _}}} =
               RunExecutor.__resume_prelude_for_test__(state(ctx, %{base: @missing_base}))

      assert_nothing_recorded(ctx)
    end

    test "the run ends failed with that terminal reason and no phase is started", %{ctx: ctx} do
      assert {:stop, :normal, %{status: :failed}} =
               RunExecutor.__handle_kickoff_ready_for_test__(state(ctx, %{base: @missing_base}))

      run = ProjectionStore.run(ctx.run_id)
      assert run.status == "failed"
      assert run.terminal? == true
      assert run.failure_reason =~ ":resume_context_unresolvable"
      assert run.failure_reason =~ ":worktree_base_unresolvable"
      assert run.failure_reason =~ @missing_base

      # No phase started: phase 1 is still on its first attempt and the
      # second phase does not exist.
      assert [%{index: 1, attempt: 1, status: "in_progress"}] =
               ProjectionStore.phases_for_run(ctx.run_id)

      assert_nothing_recorded(ctx)
    end
  end

  describe "a base that resolves" do
    test "recovery proceeds, so the failures above come from the base and not the setup",
         %{ctx: ctx} do
      assert {:ok, _state} = RunExecutor.__resume_prelude_for_test__(state(ctx, %{base: "main"}))
      assert retried_count(ctx) == 1
    end
  end

  # Provisioning replaces the base with the tip of the task's `source_branch`
  # (`adopt --continue --from-source-branch`), and fails when that branch is not
  # there. The pre-check must judge the base provisioning will use, or a run that
  # can only fail at provisioning is recovered first (attempt and recovery
  # recorded) and then ends with a different reason.
  describe "a task whose source branch is missing" do
    test "recovery fails with :resume_context_unresolvable and records nothing", %{ctx: ctx} do
      repo = ctx.repo

      assert {:error,
              {:resume_context_unresolvable, {:source_branch_not_found, "no-such-branch", ^repo}}} =
               RunExecutor.__resume_prelude_for_test__(
                 state(ctx, %{base: "main"}, %{source_branch: "no-such-branch"})
               )

      assert_nothing_recorded(ctx)
    end

    test "the same task with its source branch present recovers", %{ctx: ctx} do
      git!(ctx.repo, ["branch", "adopted"])

      assert {:ok, _state} =
               RunExecutor.__resume_prelude_for_test__(
                 state(ctx, %{base: "main"}, %{source_branch: "adopted"})
               )

      assert retried_count(ctx) == 1
    end
  end

  # Nothing downstream of the base resolution ran: no worktree was provisioned,
  # no resumed attempt and no recovery were recorded.
  defp assert_nothing_recorded(ctx) do
    refute File.dir?(
             Path.join(ForemanServer.Workflow.RunWorktreeLayout.base_root(), ctx.project_id)
           )

    assert retried_count(ctx) == 0
    assert Map.get(ProjectionStore.run(ctx.run_id), :recovery) == nil
  end

  defp state(ctx, worktree_spec, task_extra \\ %{}) do
    %{
      run_id: ctx.run_id,
      task: Map.merge(%{task_id: "task-#{ctx.run_id}", project_id: ctx.project_id}, task_extra),
      status: :running,
      resuming?: true,
      resume_from: 0,
      phase_specs: [%{name: "only"}, %{name: "second"}],
      worktree_spec: worktree_spec,
      plan_context: nil,
      artifact_base: Path.join(ctx.repo, "artifacts")
    }
  end

  defp init_repo!(repo) do
    git!(repo, ["init", "--initial-branch=main", "--quiet"])
    git!(repo, ["config", "user.email", "t@x"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "seed")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-m", "seed", "--quiet"])
  end

  defp git!(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}) in #{dir}: #{out}")
    end
  end

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

  defp start_phase!(ctx) do
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

    await(fn -> match?(%{status: "in_progress"}, phase(ctx.run_id)) end)
  end

  defp worktree_dir(ctx), do: Path.join(ctx.repo, "wt")

  defp seed_worktree!(ctx) do
    File.mkdir_p!(worktree_dir(ctx))

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "WorktreeCreated",
          payload: %{
            operation_id: "wt-" <> ctx.run_id,
            project_id: ctx.project_id,
            run_id: ctx.run_id,
            phase_id: ctx.phase_id,
            repo_path: ctx.repo,
            worktree_path: worktree_dir(ctx),
            branch: "foreman/#{ctx.run_id}",
            base_ref: git!(ctx.repo, ["rev-parse", "HEAD"]),
            cleanup: "never"
          }
        }
      ])
  end

  defp phase(run_id), do: Enum.find(ProjectionStore.phases_for_run(run_id), &(&1.index == 1))

  defp retried_count(ctx) do
    case Store.read_stream_forward(aggregate_id(ctx), 0, 50) do
      {:ok, events} -> Enum.count(events, &(&1.event_type == "PhaseRetried"))
      {:error, :stream_not_found} -> 0
    end
  end

  defp await(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && await(fun, tries - 1)
    end
  end
end
