defmodule ForemanServer.CommandGatewayCancelQueuedRunTest do
  # A run that waits for a run slot has no Run aggregate yet, so `run.cancel` used to be refused as
  # not found and the run stayed in the global waiting list until the next boot.
  use ExUnit.Case, async: false

  alias EventStore.EventData
  alias ForemanServer.{Aggregate, CommandGateway, EventStore, ProjectionStore, RunAdmission}
  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @run_slots_stream "run_slots:global"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)

    for name <- [
          ForemanServer.PubSub,
          ForemanServerWeb.Presence,
          ForemanServer.EventStore,
          ForemanServer.ProjectionStore,
          ForemanServer.Aggregator,
          ForemanServer.CommandRouter
        ] do
      assert is_pid(Process.whereis(name)), "#{inspect(name)} is not running in the app tree"
    end

    :ok
  end

  setup do
    previous_capacity = Application.get_env(:foreman_server, :max_concurrent_runs)
    Application.put_env(:foreman_server, :max_concurrent_runs, 1)

    reset!()

    on_exit(fn ->
      reset!()

      if previous_capacity == nil do
        Application.delete_env(:foreman_server, :max_concurrent_runs)
      else
        Application.put_env(:foreman_server, :max_concurrent_runs, previous_capacity)
      end
    end)

    :ok
  end

  test "cancelling a run that waits for a slot removes it from the waiting list and releases its task" do
    holder = unique_id("holder")
    queued = unique_id("queued")
    task_id = unique_id("task")

    append_holder!(holder)
    seed_in_progress_task!(task_id, queued)

    assert {:ok, :slot_queued} =
             RunAdmission.start(unique_id("project"), admission(queued, task_id))

    assert waiter_ids() == [queued]

    project_id = Map.fetch!(ProjectionStore.task_projection(task_id), :project_id)
    assert %{status: "queued"} = ProjectionStore.pending_run(queued)
    assert task_id in ProjectionStore.deferred_task_ids(project_id)

    assert {:ok, _} = cancel(queued)

    assert waiter_ids() == []
    # Only the waiter left: the run holding the slot is untouched.
    assert Map.keys(holders()) == [holder]

    assert {:ok, task} =
             wait_until(fn ->
               task = ProjectionStore.task_projection(task_id)

               if task && Map.get(task, :acknowledged_run_id) == queued,
                 do: {:ok, task},
                 else: :retry
             end)

    assert Map.get(task, :acknowledged_run_id) == queued

    # The acknowledged task is bound to a run that will never start. It must not read as a queued run,
    # and the Dispatcher must not re-admit it as a deferred task when a slot frees.
    assert ProjectionStore.pending_run(queued) == nil
    refute task_id in ProjectionStore.deferred_task_ids(Map.fetch!(task, :project_id))
  end

  test "a second cancel of the same queued run is refused as an unknown run and removes nothing" do
    holder = unique_id("holder")
    queued = unique_id("queued")
    task_id = unique_id("task")

    append_holder!(holder)
    seed_in_progress_task!(task_id, queued)

    assert {:ok, :slot_queued} =
             RunAdmission.start(unique_id("project"), admission(queued, task_id))

    assert {:ok, _} = cancel(queued)

    # Not waiting any more, and still no Run aggregate: it is an unknown run again, so the aggregate's
    # own refusal applies and nothing is removed or acknowledged twice.
    assert {:error, _not_found} = cancel(queued)
    assert waiter_ids() == []
    assert Map.keys(holders()) == [holder]
  end

  test "cancelling an unknown run is still refused and leaves other waiters alone" do
    holder = unique_id("holder")
    waiting = unique_id("waiting")
    task_id = unique_id("task")

    append_holder!(holder)
    seed_in_progress_task!(task_id, waiting)

    assert {:ok, :slot_queued} =
             RunAdmission.start(unique_id("project"), admission(waiting, task_id))

    assert {:error, _not_found} = cancel(unique_id("unknown"))

    # Cancelling one run never touches another waiter.
    assert waiter_ids() == [waiting]
  end

  # ---------------------------------------------------------------------------------- helpers

  defp cancel(run_id) do
    CommandGateway.dispatch_operator(%{
      type: "run.cancel",
      command_id: unique_id("cancel"),
      aggregate_id: "run:#{run_id}",
      payload: %{run_id: run_id}
    })
  end

  defp admission(run_id, task_id) do
    %{
      run_id: run_id,
      task_id: task_id,
      workflow_snapshot: %{phases: [%{id: "phase-1", kind: "command"}]}
    }
  end

  defp slots do
    {state, _version} = Aggregate.load(RunSlots, @run_slots_stream)
    state
  end

  defp waiter_ids, do: Enum.map(slots().waiters, & &1.run_id)
  defp holders, do: slots().holders

  defp append_holder!(run_id) do
    data = %{run_id: run_id, capacity: 1, acquired_at_ms: System.system_time(:millisecond)}

    :ok =
      EventStore.append_to_stream(@run_slots_stream, 0, [
        %EventData{event_type: "RunSlotAcquired", data: data, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: "RunSlotAcquired", payload: data}])
  end

  defp seed_in_progress_task!(task_id, run_id) do
    stream = "task:" <> task_id

    append_and_apply(stream, 0, "TaskCreated", %{
      task_id: task_id,
      project_id: unique_id("project"),
      title: "queued #{task_id}",
      status: "open",
      task_type: "implementation"
    })

    append_and_apply(stream, 1, "TaskApproved", %{
      task_id: task_id,
      approval_id: unique_id("approval"),
      approved_by: "alice",
      approved_at: "2026-08-10T00:00:00Z",
      run_id: run_id,
      workflow_snapshot: %{run_id: run_id, phases: []}
    })

    append_and_apply(stream, 2, "TaskUpdated", %{task_id: task_id, status: "in_progress"})
  end

  defp append_and_apply(stream, version, event_type, payload) do
    :ok =
      EventStore.append_to_stream(stream, version, [
        %EventData{event_type: event_type, data: payload, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: event_type, payload: payload}])
  end

  defp wait_until(fun, attempts \\ 50) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      :retry when attempts > 1 ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)

      :retry ->
        :timeout
    end
  end

  defp reset! do
    ForemanServer.TestSupport.RunSlotsReset.reset!()
    ProjectionStoreReset.reset!(keep_subscribers: true)
  end

  defp unique_id(prefix),
    do: "#{prefix}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
end
