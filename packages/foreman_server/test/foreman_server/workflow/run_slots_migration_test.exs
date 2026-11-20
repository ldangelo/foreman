defmodule ForemanServer.Workflow.RunSlotsMigrationTest do
  # TRD-009-TEST (REQ-009, AC-009-1..4, AC-008-1): the one-shot carry-over of the legacy
  # `run_slots:global` stream into the per-project streams. The legacy events carry no
  # `project_id`, so every run's project comes from its run projection, else its task.
  use ExUnit.Case, async: false

  alias ForemanServer.{Aggregate, CommandGateway, ProjectionStore}
  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.RunSlotsReset
  alias ForemanServer.Workflow.{BootReconciliation, RunSlotsMigration}

  @legacy "run_slots:global"

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
    :ok
  end

  # AC-009-1
  test "running runs continue: legacy holders are adopted by their own project" do
    a = project(2)
    b = project(1)
    [a1, a2] = [unique("a1"), unique("a2")]
    b1 = unique("b1")

    for {run, project} <- [{a1, a}, {a2, a}, {b1, b}], do: seed_live_run!(run, project)
    for run <- [a1, b1, a2], do: legacy_acquire!(run, 3)

    assert {:ok, _summary} = RunSlotsMigration.run()

    assert holders(a) == Enum.sort([a1, a2])
    assert holders(b) == [b1]
    # They count against their own project: its stream says it is full.
    assert map_size(slot_state(a).holders) == 2
    assert slot_state(a).capacity == 2
    assert slot_state(b).capacity == 1
    # None was stopped or released, and the runs are still live.
    refute Enum.any?(events(RunSlots.stream_id(a)), &(&1.event_type == "RunSlotReleased"))
    refute Enum.any?(events(RunSlots.stream_id(b)), &(&1.event_type == "RunSlotReleased"))
    assert %{} = ProjectionStore.run(a1)
  end

  # AC-009-2
  test "waiters keep their order: A queues X then Y, B queues Z; a second pass changes nothing" do
    a = project(1)
    b = project(1)
    [a1, b1] = [unique("a1"), unique("b1")]
    [x, y, z] = [unique("x"), unique("y"), unique("z")]

    seed_live_run!(a1, a)
    seed_live_run!(b1, b)
    for {run, project} <- [{x, a}, {z, b}, {y, a}], do: seed_in_progress_task!(run, project)

    legacy_acquire!(a1, 2)
    legacy_acquire!(b1, 2)
    # Legacy order interleaves the projects: X, Z, Y.
    for run <- [x, z, y], do: legacy_acquire!(run, 0)

    assert {:ok, _} = RunSlotsMigration.run()

    assert waiters(a) == [x, y]
    assert waiters(b) == [z]
    assert queued_order(a) == [x, y]

    before = {event_count(a), event_count(b)}
    assert {:ok, _} = RunSlotsMigration.run()
    assert {event_count(a), event_count(b)} == before
    assert waiters(a) == [x, y]
    assert waiters(b) == [z]
  end

  # AC-009-3, AC-008-1 (and the TRD-009 implementation AC: reconcile twice, one carry-over)
  test "legacy stream is retained and untouched, also across two boot reconciliations" do
    a = project(1)
    [a1, x, ghost] = [unique("a1"), unique("x"), unique("ghost")]

    seed_live_run!(a1, a)
    seed_in_progress_task!(x, a)
    legacy_acquire!(a1, 1)
    legacy_acquire!(x, 0)
    # A waiter with neither a run nor an in-progress task is an orphan and is NOT carried over.
    legacy_acquire!(ghost, 0)

    snapshot = snapshot(@legacy)
    assert length(snapshot) == 3

    assert {:ok, _} = RunSlotsMigration.run()
    assert snapshot(@legacy) == snapshot

    scan!()
    scan!()

    assert snapshot(@legacy) == snapshot
    assert holders(a) == [a1]
    assert waiters(a) == [x]
    assert count(events(RunSlots.stream_id(a)), "RunSlotAcquired") == 1
    assert count(events(RunSlots.stream_id(a)), "RunSlotQueued") == 1
  end

  # AC-009-4
  test "a project already over its new limit: no holder is stopped and new runs wait" do
    a = project(1)
    [a1, a2, a3] = [unique("a1"), unique("a2"), unique("a3")]
    x = unique("x")

    for run <- [a1, a2, a3], do: seed_live_run!(run, a)
    seed_in_progress_task!(x, a)
    for run <- [a1, a2, a3], do: legacy_acquire!(run, 3)
    legacy_acquire!(x, 0)

    assert {:ok, _} = RunSlotsMigration.run()

    assert holders(a) == Enum.sort([a1, a2, a3])
    refute Enum.any?(events(RunSlots.stream_id(a)), &(&1.event_type == "RunSlotReleased"))
    assert waiters(a) == [x]

    # A fresh run waits behind the waiter already queued.
    fresh = unique("fresh")

    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               type: "run_slots.acquire",
               command_id: "fresh:#{fresh}",
               aggregate_id: RunSlots.stream_id(a),
               payload: %{run_id: fresh, capacity: 1, project_id: a}
             })

    assert waiters(a) == [x, fresh]

    # And nothing is promoted while the project is over its limit.
    assert {:ok, nil} =
             CommandGateway.dispatch_system(%{
               type: "run_slots.promote",
               command_id: "promote:#{unique("p")}",
               aggregate_id: RunSlots.stream_id(a),
               payload: %{project_id: a, capacity: 1}
             })
  end

  # -- helpers ---------------------------------------------------------------

  defp scan! do
    assert :ok = BootReconciliation.scan_run_slot_orphans()
    # The scan is a cast; a call queued behind it returns once it was handled.
    _ = :sys.get_state(BootReconciliation)
    :ok
  end

  defp project(limit) do
    id = H.register_project(System.tmp_dir!(), config: %{})

    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "project.update",
        aggregate_id: "project:#{id}",
        command_id: "u-#{System.unique_integer([:positive])}",
        payload: %{project_id: id, max_concurrent_runs: limit}
      })

    id
  end

  defp slot_state(project) do
    {state, _version} = Aggregate.load(RunSlots, RunSlots.stream_id(project))
    state
  end

  defp waiters(project), do: Enum.map(slot_state(project).waiters, & &1.run_id)
  defp holders(project), do: slot_state(project).holders |> Map.keys() |> Enum.sort()

  defp events(stream) do
    case Store.read_stream_forward(stream, 0, 200) do
      {:ok, events} -> events
      {:error, _} -> []
    end
  end

  defp event_count(project), do: project |> RunSlots.stream_id() |> events() |> length()

  defp count(events, type), do: Enum.count(events, &(&1.event_type == type))

  defp queued_order(project) do
    project
    |> RunSlots.stream_id()
    |> events()
    |> Enum.filter(&(&1.event_type == "RunSlotQueued"))
    |> Enum.map(&field(&1.data, :run_id))
  end

  defp field(data, key), do: Map.get(data, key) || Map.get(data, Atom.to_string(key))

  defp snapshot(stream) do
    Enum.map(events(stream), &{&1.event_id, &1.stream_version, &1.event_type, &1.data})
  end

  # A legacy slot event has no `project_id`; capacity 0 makes the acquire a queued waiter.
  defp legacy_acquire!(run_id, capacity) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run_slots.acquire",
        command_id: "legacy-seed:#{run_id}",
        aggregate_id: @legacy,
        payload: %{run_id: run_id, capacity: capacity}
      })
  end

  defp unique(prefix), do: "#{prefix}-mig-#{System.unique_integer([:positive])}"

  defp seed_live_run!(run_id, project_id) do
    append("run:#{run_id}", 0, "RunStarted", %{
      run_id: run_id,
      task_id: unique("task"),
      project_id: project_id,
      workflow_snapshot: %{},
      sequence: 0
    })
  end

  defp seed_in_progress_task!(run_id, project_id) do
    task_id = unique("task")

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

  defp append(stream, version, type, payload) do
    :ok =
      Store.append_to_stream(stream, version, [
        %EventStore.EventData{event_type: type, data: payload, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: type, payload: payload}])
  end
end
