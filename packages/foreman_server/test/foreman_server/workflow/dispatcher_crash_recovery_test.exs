defmodule ForemanServer.Workflow.DispatcherCrashRecoveryTest do
  @moduledoc """
  Boot replay (`ProjectionStore.subscribe(replay_existing: true)`) re-delivers
  every historical event to the Dispatcher. These tests pin what it does with
  the ones that describe a run the previous server left behind:

    * `TaskDispatched` for a run that is still in flight must RESUME it
      (reusing its worktree), not start it as a brand-new run;
    * a `RunPaused` whose run is no longer paused is history, not a command.

  `Dispatcher.handle_info/2` is called directly; `RunAdmission` and
  `RunSupervisor` are replaced only to observe what the Dispatcher decides.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.{ProjectionStore, RunControl}
  alias ForemanServer.TestSupport.MeckScope
  alias ForemanServer.Workflow.Dispatcher

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)

    ensure_started({Phoenix.PubSub, name: ForemanServer.PubSub}, ForemanServer.PubSub)
    ensure_started(ForemanServerWeb.Presence, ForemanServerWeb.Presence)
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)
    ensure_started(ForemanServer.Aggregator, ForemanServer.Aggregator)
    ensure_started(ForemanServer.CommandRouter, ForemanServer.CommandRouter)
    ensure_started(ForemanServer.RunControl, ForemanServer.RunControl)
    ensure_started(ForemanServer.TaskProvider.Registry, ForemanServer.TaskProvider.Registry)

    ensure_started(
      {Registry, keys: :unique, name: ForemanServer.RunExecutorRegistry},
      ForemanServer.RunExecutorRegistry
    )

    ensure_started(ForemanServer.Workflow.RunSupervisor, ForemanServer.Workflow.RunSupervisor)

    # `:meck.new(ProjectionStore, [:passthrough])` copies a 5.5k-line module (~1.3 s): once per module.
    MeckScope.new_once!(ProjectionStore)
  end

  setup do
    :ok = ForemanServer.DispatcherQuiesce.suspend!()
    MeckScope.restore_on_exit!(ProjectionStore)
  end

  describe "TaskDispatched replayed for a run a previous server left in flight" do
    test "resumes at the first unfinished phase" do
      %{run_id: run_id} = ctx = seed_run()
      completed_phase!(run_id, 1)

      start_run_args = dispatch_replayed_task(ctx)

      assert [^run_id, _task, [resume_from: 1]] = start_run_args
    end

    test "starts a run the projection has never seen as a fresh run" do
      ctx = seed_run(started?: false)

      assert [_run_id, _task, []] = dispatch_replayed_task(ctx)
    end

    test "does not start a run an operator paused" do
      %{run_id: run_id} = ctx = seed_run()
      :ok = ProjectionStore.apply_events([%{event_type: "RunPaused", payload: %{run_id: run_id}}])

      assert dispatch_replayed_task(ctx) == :not_started
    end
  end

  describe "RunPaused replayed at boot" do
    test "a steered run that has since finished gets no pause intent" do
      %{run_id: run_id} = seed_run()

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "RunPaused", payload: %{run_id: run_id, reason: "steer"}},
          %{event_type: "RunResumed", payload: %{run_id: run_id}},
          %{event_type: "RunCompleted", payload: %{run_id: run_id}}
        ])

      on_exit(fn -> RunControl.clear(run_id) end)
      replay_run_paused(run_id)

      assert RunControl.intent(run_id) == nil
    end

    test "a run that is still paused does get the pause intent" do
      %{run_id: run_id} = seed_run()

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "RunPaused", payload: %{run_id: run_id, reason: "operator"}}
        ])

      on_exit(fn -> RunControl.clear(run_id) end)
      replay_run_paused(run_id)

      assert RunControl.intent(run_id) == :pause
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp seed_run(opts \\ []) do
    n = System.unique_integer([:positive])
    run_id = "run-crash-#{n}"
    task_id = "task-crash-#{n}"
    project_id = "project-crash-#{n}"

    if Keyword.get(opts, :started?, true) do
      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "RunStarted",
            payload: %{
              run_id: run_id,
              project_id: project_id,
              task_id: task_id,
              workflow_snapshot: %{}
            }
          }
        ])
    end

    %{run_id: run_id, task_id: task_id, project_id: project_id}
  end

  defp completed_phase!(run_id, index) do
    phase = %{
      phase_id: "#{run_id}-phase-#{index}",
      run_id: run_id,
      index: index,
      name: "phase-#{index}",
      attempt: 1,
      artifact_template: "phase-{{index}}.md"
    }

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "PhaseStarted", payload: phase},
        %{
          event_type: "PhaseCompleted",
          payload: %{
            phase_id: phase.phase_id,
            run_id: run_id,
            index: index,
            artifact_path: "phase-#{index}.md",
            artifact_sha256: String.duplicate("a", 64),
            artifact_bytes: 10
          }
        }
      ])
  end

  # Replays `TaskDispatched` and returns the `RunSupervisor.start_run/3` args, or
  # `:not_started`.
  defp dispatch_replayed_task(%{run_id: run_id, task_id: task_id, project_id: project_id}) do
    parent = self()

    task_proj = %{
      task_id: task_id,
      run_id: run_id,
      project_id: project_id,
      approval_id: "approval-#{run_id}",
      status: "in_progress",
      workflow_snapshot: %{phases: [%{"name" => "phase-1"}, %{"name" => "phase-2"}]}
    }

    :meck.new(ForemanServer.RunAdmission, [:no_link, :passthrough])
    :meck.new(ForemanServer.Workflow.RunSupervisor, [:no_link, :passthrough])

    on_exit(fn ->
      for mod <- [
            ForemanServer.RunAdmission,
            ForemanServer.Workflow.RunSupervisor
          ] do
        try do
          :meck.unload(mod)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :meck.expect(ForemanServer.ProjectionStore, :task_projection, fn
      ^task_id -> task_proj
      other -> :meck.passthrough([other])
    end)

    :meck.expect(ForemanServer.RunAdmission, :start, fn ^project_id, _payload -> {:ok, nil} end)

    :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn id, task, opts ->
      send(parent, {:start_run, [id, task, opts]})
      {:ok, self()}
    end)

    envelope = %{event_type: "TaskDispatched", data: %{task_id: task_id}}
    {:noreply, _} = Dispatcher.handle_info({:projection_event, envelope}, %{pending: %{}})

    receive do
      {:start_run, args} -> args
    after
      200 -> :not_started
    end
  end

  defp replay_run_paused(run_id) do
    envelope = %{event_type: "RunPaused", data: %{run_id: run_id, reason: "steer"}}
    {:noreply, _} = Dispatcher.handle_info({:projection_event, envelope}, %{pending: %{}})
    :ok
  end

  defp ensure_started(child_spec, name) do
    case Process.whereis(name) do
      nil -> start_supervised!(child_spec)
      _pid -> :ok
    end
  end
end
