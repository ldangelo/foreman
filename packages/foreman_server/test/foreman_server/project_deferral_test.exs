defmodule ForemanServer.ProjectDeferralTest do
  # Admission refusals (cap, run limit, pause) are retried, so they were only
  # logged. `project.note_deferral` makes them a durable, idempotent per
  # task/reason/day counter surfaced as `limits.deferred_today`.
  use ExUnit.Case, async: false

  alias ForemanServer.{ProjectionStore, ProjectStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.Dispatcher

  setup do
    # The app's real Dispatcher stays subscribed to ProjectionStore and handles
    # terminal/resume events emitted by earlier tests. Unfrozen, it would run
    # against the modules mocked below (calling the mocked RunSupervisor.start_run
    # and RunAdmission.start) and put messages in this test's mailbox. See
    # ForemanServer.DispatcherQuiesce.
    :ok = ForemanServer.DispatcherQuiesce.suspend!()

    ProjectionStoreReset.reset!()
    :meck.new(ForemanServer.ProjectionStore, [:no_link, :passthrough])
    :meck.new(ForemanServer.RunAdmission, [:no_link])
    :meck.new(ForemanServer.Workflow.RunSupervisor, [:no_link])

    on_exit(fn ->
      for mod <- [
            ForemanServer.ProjectionStore,
            ForemanServer.RunAdmission,
            ForemanServer.Workflow.RunSupervisor
          ] do
        if :meck.validate(mod), do: :meck.unload(mod)
      end

      ProjectionStoreReset.reset!()
    end)

    id = "deferral-#{System.unique_integer([:positive])}"
    assert {:ok, _} = ProjectStore.save(%{project_id: id, path: "/tmp/#{id}"})
    {:ok, id: id}
  end

  defp task(id, task_id) do
    %{
      status: "in_progress",
      task_id: task_id,
      run_id: "run-#{task_id}",
      project_id: id,
      approval_id: "approval-#{task_id}",
      workflow_snapshot: %{phases: []}
    }
  end

  defp refuse_with(reason) do
    :meck.expect(ForemanServer.RunAdmission, :start, fn _project, _payload -> {:error, reason} end)
  end

  defp resume(id, task_ids) do
    tasks = Map.new(task_ids, &{&1, task(id, &1)})
    :meck.expect(ForemanServer.ProjectionStore, :deferred_task_ids, fn ^id -> task_ids end)

    :meck.expect(ForemanServer.ProjectionStore, :task_projection, fn tid ->
      Map.get(tasks, tid)
    end)

    envelope = %{event_type: "ProjectResumed", data: %{project_id: id}}
    assert {:noreply, _} = Dispatcher.handle_info({:projection_event, envelope}, %{})
  end

  test "a cap rejection counts once per task/reason/day however often it is retried", %{id: id} do
    refuse_with({:daily_thread_cap_exceeded, 5, "2026-01-01"})

    resume(id, ["t1"])
    resume(id, ["t1"])
    assert %{deferred_today: 1} = ProjectionStore.project_limits(id)

    {:ok, events} = ForemanServer.EventStore.read_stream_forward("project:#{id}", 0, 1_000)
    assert Enum.count(events, &(&1.event_type =~ "ProjectAdmissionDeferred")) == 1

    resume(id, ["t1", "t2"])

    assert %{deferred_today: 2, deferred_by_reason: %{"daily_thread_cap_exceeded" => 2}} =
             ProjectionStore.project_limits(id)
  end

  test "reasons are counted separately and unrelated errors are not counted", %{id: id} do
    refuse_with(:run_limit_exceeded)
    resume(id, ["t1"])
    refuse_with({:project_paused, id})
    resume(id, ["t1"])
    refuse_with({:something_else, "boom"})
    resume(id, ["t3"])

    assert %{deferred_today: 2, deferred_by_reason: by_reason} =
             ProjectionStore.project_limits(id)

    assert by_reason == %{"run_limit_exceeded" => 1, "project_paused" => 1}
  end

  test "a failing note_deferral command leaves the Dispatcher alive and the project untouched" do
    ghost = "ghost-#{System.unique_integer([:positive])}"
    refuse_with({:daily_thread_cap_exceeded, 1, "2026-01-01"})
    resume(ghost, ["t1"])
    assert ProjectionStore.project_limits(ghost) == nil
  end

  test "recording the same deferral command again is one event", %{id: id} do
    command = fn ->
      ForemanServer.CommandGateway.dispatch_system(%{
        command_id: "deferral:t7:run_limit_exceeded:today",
        aggregate_id: "project:#{id}",
        type: "project.note_deferral",
        payload: %{project_id: id, task_id: "t7", reason: "run_limit_exceeded"}
      })
    end

    assert {:ok, first} = command.()
    assert {:ok, ^first} = command.()

    {:ok, events} = ForemanServer.EventStore.read_stream_forward("project:#{id}", 0, 1_000)
    assert Enum.count(events, &(&1.event_type =~ "ProjectAdmissionDeferred")) == 1
  end

  test "an unknown reason is rejected by the aggregate", %{id: id} do
    assert {:error, {:invalid_deferral_reason, "bogus"}} =
             ForemanServer.CommandGateway.dispatch_system(%{
               command_id: "deferral:t9:bogus:today",
               aggregate_id: "project:#{id}",
               type: "project.note_deferral",
               payload: %{project_id: id, task_id: "t9", reason: "bogus"}
             })
  end

  test "the counter survives a rebuild from the event log", %{id: id} do
    refuse_with({:daily_thread_cap_exceeded, 5, "2026-01-01"})
    resume(id, ["t1", "t2"])
    live = ProjectionStore.project_limits(id)
    assert live.deferred_today == 2

    :ok = ProjectionStore.rebuild([])
    assert ProjectionStore.project_limits(id) == live
  end
end
