defmodule ProjectionStoreRunsTestHelper do
  def reset_projection_store do
    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      %{
        projects: %{},
        runs: %{},
        tasks: %{},
        phases: %{},
        pr_associations: %{},
        scheduler_intents: %{},
        worktrees: %{},
        worktree_create_orphans: %{},
        subscribers: Map.get(state, :subscribers, %{}),
        project_active_runs: %{},
        run_slots: %{capacity: 0, holders: %{}, waiters: []},
        works: %{}
      }
    end)
  end

  def set_now_ms(now_ms) when is_integer(now_ms) do
    Process.put(:projection_store_now_ms, fn -> now_ms end)
  end

  def clear_now_ms do
    Process.delete(:projection_store_now_ms)
  end
end

defmodule ForemanServer.ProjectionStoreRunsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore

  @default_now_ms 1_700_000_000_000

  setup_all do
    original_now_ms = Application.get_env(:foreman_server, :projection_store_now_ms)
    Application.put_env(:foreman_server, :projection_store_now_ms, fn -> @default_now_ms end)

    on_exit(fn ->
      if original_now_ms == nil do
        Application.delete_env(:foreman_server, :projection_store_now_ms)
      else
        Application.put_env(:foreman_server, :projection_store_now_ms, original_now_ms)
      end
    end)

    :ok
  end

  setup do
    ProjectionStoreRunsTestHelper.reset_projection_store()
    ProjectionStoreRunsTestHelper.set_now_ms(@default_now_ms)

    on_exit(fn ->
      ProjectionStoreRunsTestHelper.clear_now_ms()
      ProjectionStoreRunsTestHelper.reset_projection_store()
    end)

    :ok
  end

  test "RunStarted and phase activity drive active/stuck run queries" do
    run_id = "run-1"
    started_at_ms = @default_now_ms
    phase_event_at_ms = started_at_ms + 90_000

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "RunStarted",
                 payload: %{
                   run_id: run_id,
                   task_id: "task-1",
                   project_id: "project-1",
                   workflow_snapshot: %{}
                 }
               }
             ])

    assert ProjectionStore.active_runs() == [run_id]
    assert ProjectionStore.stuck_runs(900_000, started_at_ms) == []
    assert ProjectionStore.stuck_runs(0, started_at_ms + 60_000) == [run_id]

    ProjectionStoreRunsTestHelper.set_now_ms(phase_event_at_ms)

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "PhaseStarted",
                 payload: %{
                   run_id: run_id,
                   phase_id: "phase-1",
                   index: 1,
                   name: "build",
                   attempt: 1,
                   artifact_template: "report.md"
                 }
               }
             ])

    assert ProjectionStore.stuck_runs(60_000, phase_event_at_ms + 59_999) == []
    assert ProjectionStore.stuck_runs(60_000, phase_event_at_ms + 60_000) == [run_id]

    ProjectionStoreRunsTestHelper.set_now_ms(phase_event_at_ms + 120_000)

    assert :ok =
             ProjectionStore.apply_events([
               %{event_type: "RunCompleted", payload: %{run_id: run_id}}
             ])

    assert ProjectionStore.active_runs() == []
    assert ProjectionStore.stuck_runs(0, phase_event_at_ms + 180_000) == []
  end

  test "RunFlaggedStuck removes runs from active and stuck queries" do
    run_id = "run-stuck"
    started_at_ms = @default_now_ms
    flagged_at_ms = started_at_ms + 30_000

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "RunStarted",
                 payload: %{
                   run_id: run_id,
                   task_id: "task-2",
                   project_id: "project-1",
                   workflow_snapshot: %{}
                 }
               }
             ])

    assert ProjectionStore.active_runs() == [run_id]

    ProjectionStoreRunsTestHelper.set_now_ms(flagged_at_ms)

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "RunFlaggedStuck",
                 payload: %{
                   run_id: run_id,
                   project_id: "project-1",
                   flagged_at: flagged_at_ms
                 }
               }
             ])

    assert ProjectionStore.active_runs() == []
    assert ProjectionStore.stuck_runs(0, flagged_at_ms + 1) == []
    assert ProjectionStore.stuck_runs(900_000, flagged_at_ms + 900_000) == []
  end
end
