defmodule ForemanServer.Workflow.BootReconciliationQueuedWaiterTest do
  # TRD-018-TEST (kata `teak`): a queued run has a task `in_progress` with its
  # `run_id` but NO run projection yet. Boot reconciliation must keep such a waiter
  # (AC-005-2), and still remove the waiter of a terminal run (AC-007-1).
  #
  # These observe the project's own `run_slots:<project_id>` stream, which the boot scan reads
  # with the one slot-entry predicate (`BootReconciliation.slot_entry_orphan?/1`).
  use ExUnit.Case, async: false

  alias ForemanServer.{Aggregate, CommandGateway, ProjectionStore}
  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.RunSlotsReset
  alias ForemanServer.Workflow.BootReconciliation

  setup_all do
    case Process.whereis(BootReconciliation) do
      nil -> start_supervised!({BootReconciliation, []})
      _ -> :ok
    end

    :ok
  end

  setup do
    RunSlotsReset.reset!()
    on_exit(fn -> RunSlotsReset.reset!() end)
    project = H.register_project(System.tmp_dir!(), config: %{})
    Process.put(:project, project)
    :ok
  end

  test "a restart does not drop queued runs (AC-005-2)" do
    holder = unique("holder")
    seed_live_run!(holder)
    acquire!(holder, 1)

    queued = for _ <- 1..3, do: unique("queued")

    for run_id <- queued do
      # The defect's precondition: a task in progress, no run projection.
      seed_in_progress_task!(unique("task"), run_id)
      assert ProjectionStore.run(run_id) == nil
      acquire!(run_id, 0)
    end

    assert waiter_ids() == queued

    scan!()

    assert waiter_ids() == queued
    assert holder_ids() == [holder]
  end

  test "a waiter whose run has no projection and no task in progress is still removed" do
    holder = unique("holder")
    seed_live_run!(holder)
    acquire!(holder, 1)

    ghost = unique("ghost")
    queued = unique("queued")
    seed_in_progress_task!(unique("task"), queued)
    acquire!(ghost, 0)
    acquire!(queued, 0)

    scan!()

    assert waiter_ids() == [queued]
  end

  test "a terminal run's waiter is cleaned up and the next waiter considered (AC-007-1)" do
    holder = unique("holder")
    terminal = unique("terminal")
    live = unique("live")

    seed_live_run!(holder)
    seed_terminal_run!(terminal)
    seed_in_progress_task!(unique("task"), live)

    acquire!(holder, 1)
    acquire!(terminal, 0)
    acquire!(live, 0)
    assert waiter_ids() == [terminal, live]

    scan!()

    assert waiter_ids() == [live]
    assert holder_ids() == [holder]
  end

  # -- helpers ---------------------------------------------------------------

  defp scan! do
    assert :ok = BootReconciliation.scan_run_slot_orphans()
    # The scan is a cast; a call queued behind it returns once it was handled.
    _ = :sys.get_state(BootReconciliation)
    :ok
  end

  defp project, do: Process.get(:project)

  defp slot_state do
    {state, _} = Aggregate.load(RunSlots, RunSlots.stream_id(project()))
    state
  end

  defp waiter_ids, do: Enum.map(slot_state().waiters, & &1.run_id)
  defp holder_ids, do: slot_state().holders |> Map.keys() |> Enum.sort()

  defp acquire!(run_id, capacity) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run_slots.acquire",
        command_id: "seed:#{run_id}",
        aggregate_id: RunSlots.stream_id(project()),
        payload: %{
          run_id: run_id,
          project_id: project(),
          capacity: capacity,
          acquired_at_ms: System.system_time(:millisecond)
        }
      })
  end

  defp unique(prefix), do: "#{prefix}-qw-#{System.unique_integer([:positive])}"

  defp seed_in_progress_task!(task_id, run_id) do
    project_id = project()

    append("task:" <> task_id, 0, "TaskCreated", %{
      task_id: task_id,
      project_id: project_id,
      title: "queued #{task_id}",
      status: "open",
      task_type: "implementation"
    })

    append("task:" <> task_id, 1, "TaskApproved", %{
      task_id: task_id,
      approval_id: unique("approval"),
      approved_by: "alice",
      approved_at: "2026-08-10T00:00:00Z",
      run_id: run_id,
      workflow_snapshot: %{run_id: run_id, phases: []}
    })

    append("task:" <> task_id, 2, "TaskUpdated", %{task_id: task_id, status: "in_progress"})
  end

  defp seed_live_run!(run_id) do
    append("run:#{run_id}", 0, "RunStarted", %{
      run_id: run_id,
      task_id: unique("task"),
      project_id: project(),
      workflow_snapshot: %{},
      sequence: 0
    })
  end

  defp seed_terminal_run!(run_id) do
    seed_live_run!(run_id)
    append("run:#{run_id}", 1, "RunCompleted", %{run_id: run_id, sequence: 1})
  end

  defp append(stream, version, type, payload) do
    :ok =
      Store.append_to_stream(stream, version, [
        %EventStore.EventData{event_type: type, data: payload, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: type, payload: payload}])
  end
end
