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
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.TestSupport.{MeckScope, UniqueIds}
  alias ForemanServer.Workflow.{OrphanReaper, RunExecutor}

  @incarnation_key {Incarnation, :id}

  setup_all do
    MeckScope.new_once!(OrphanReaper)
  end

  setup do
    :ok = ForemanServer.DispatcherQuiesce.suspend!()
    MeckScope.restore_on_exit!(OrphanReaper)

    original = :persistent_term.get(@incarnation_key, nil)

    on_exit(fn ->
      if original, do: :persistent_term.put(@incarnation_key, original)
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

    %{run_id: run_id, repo: repo, phase_id: Identity.phase_id(run_id, 1)}
  end

  describe "resume of an in-flight phase" do
    test "reaps first, then records attempt 2; the same boot appends nothing more", ctx do
      start_phase!(ctx)
      seed_worktree!(ctx)

      assert {:ok, _state} = RunExecutor.__resume_prelude_for_test__(state(ctx))

      # The reap ran while the phase was still on attempt 1: it precedes PhaseRetried.
      assert_received {:reaped, "/wt/" <> _, 1}
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

  defp aggregate_id(ctx), do: "phase:#{ctx.run_id}:#{ctx.phase_id}"

  defp seed_run!(ctx) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunStarted",
          payload: %{
            run_id: ctx.run_id,
            project_id: "project-#{ctx.run_id}",
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

  defp seed_worktree!(ctx) do
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
            worktree_path: "/wt/#{ctx.run_id}",
            branch: "foreman/#{ctx.run_id}",
            base_ref: "0000000000000000000000000000000000000000",
            cleanup: "never"
          }
        }
      ])
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
