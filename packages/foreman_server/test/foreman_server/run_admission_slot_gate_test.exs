defmodule ForemanServer.RunAdmissionSlotGateTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{Aggregate, CommandGateway, EventStore, ProjectionStore, RunAdmission}
  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @lease_path "/tmp/trd-006-slot-gate.db"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)

    assert_running!(ForemanServer.PubSub)
    assert_running!(ForemanServerWeb.Presence)
    assert_running!(ForemanServer.EventStore)
    assert_running!(ForemanServer.ProjectionStore)
    assert_running!(ForemanServer.Aggregator)
    assert_running!(ForemanServer.CommandRouter)
    :ok
  end

  setup do
    # The shipped default flips from 100 to 3 in TRD-010; the "no setting" scenarios
    # pin it here so they state the PRD's default regardless of that task's order.
    previous_default = Application.get_env(:foreman_server, :max_concurrent_runs_per_project)
    Application.put_env(:foreman_server, :max_concurrent_runs_per_project, 3)

    cleanup_run_slots_stream()
    cleanup_lease_stream()
    reset_projection_store()

    on_exit(fn ->
      if previous_default == nil do
        Application.delete_env(:foreman_server, :max_concurrent_runs_per_project)
      else
        Application.put_env(:foreman_server, :max_concurrent_runs_per_project, previous_default)
      end

      cleanup_run_slots_stream()
      cleanup_lease_stream()
      reset_projection_store()
    end)

    :ok
  end

  describe "per-project slot gate (capacity from the project)" do
    test "default of three: four runs submitted, three run and one waits (AC-002-1)" do
      project_id = unique_id("project")
      register_project!(project_id)
      run_ids = Enum.map(1..4, &unique_id("run-#{&1}"))

      results = Enum.map(run_ids, &RunAdmission.start(project_id, plain_payload(&1)))
      {running, [waiting]} = Enum.split(run_ids, 3)

      assert Enum.take(results, 3)
             |> Enum.all?(&match?({:ok, %{"event_type" => "RunStarted"}}, &1))

      assert List.last(results) == {:ok, :slot_queued}

      assert holder_ids(project_id) == Enum.sort(running)
      assert waiter_ids(project_id) == [waiting]
      refute ProjectionStore.run(waiting)

      # The legacy global stream is no longer written.
      assert {:error, :stream_not_found} =
               EventStore.read_stream_forward("run_slots:global", 0, 10)
    end

    test "a setting of five: six runs submitted, five run and one waits (AC-003-1)" do
      project_id = unique_id("project")
      register_project!(project_id)
      set_project_limit!(project_id, 5)
      run_ids = Enum.map(1..6, &unique_id("run-#{&1}"))

      results = Enum.map(run_ids, &RunAdmission.start(project_id, plain_payload(&1)))

      assert Enum.take(results, 5)
             |> Enum.all?(&match?({:ok, %{"event_type" => "RunStarted"}}, &1))

      assert List.last(results) == {:ok, :slot_queued}
      assert length(holder_ids(project_id)) == 5
      assert waiter_ids(project_id) == [List.last(run_ids)]
    end

    test "a setting of one: two runs submitted, one runs and one waits (AC-003-2)" do
      project_id = unique_id("project")
      register_project!(project_id)
      set_project_limit!(project_id, 1)
      [first, second] = [unique_id("run-1"), unique_id("run-2")]

      assert {:ok, %{"event_type" => "RunStarted"}} =
               RunAdmission.start(project_id, plain_payload(first))

      assert {:ok, :slot_queued} = RunAdmission.start(project_id, plain_payload(second))
      assert holder_ids(project_id) == [first]
      assert waiter_ids(project_id) == [second]
    end

    test "next waiter starts: three running and one waiting, one finishes (AC-002-2)" do
      project_id = unique_id("project")
      register_project!(project_id)
      [r1, r2, r3, waiting] = Enum.map(1..4, &unique_id("run-#{&1}"))

      for run_id <- [r1, r2, r3] do
        assert {:ok, %{"event_type" => "RunStarted"}} =
                 RunAdmission.start(project_id, plain_payload(run_id))
      end

      assert {:ok, :slot_queued} = RunAdmission.start(project_id, plain_payload(waiting))
      assert waiter_ids(project_id) == [waiting]

      # The release is built for the run's real project, so it lands on the
      # project's own stream and promotes that stream's head waiter.
      command = RunSlots.release_command(project_id, r1, "test_finished")
      assert command.aggregate_id == RunSlots.stream_id(project_id)
      assert {:ok, _} = CommandGateway.dispatch_system(command)

      assert holder_ids(project_id) == Enum.sort([r2, r3, waiting])
      assert waiter_ids(project_id) == []
    end

    test "a busy project does not block another project (AC-001-1)" do
      project_a = unique_id("project-a")
      project_b = unique_id("project-b")
      register_project!(project_a)
      register_project!(project_b)

      for n <- 1..3 do
        assert {:ok, %{"event_type" => "RunStarted"}} =
                 RunAdmission.start(project_a, plain_payload(unique_id("a-#{n}")))
      end

      backlog = unique_id("a-backlog")
      assert {:ok, :slot_queued} = RunAdmission.start(project_a, plain_payload(backlog))

      b_run = unique_id("b-run")

      assert {:ok, %{"event_type" => "RunStarted"}} =
               RunAdmission.start(project_b, plain_payload(b_run))

      assert holder_ids(project_b) == [b_run]
      assert waiter_ids(project_a) == [backlog]
    end

    test "archived project holds: waiting runs do not start when capacity frees (AC-017-1)" do
      project_id = unique_id("project")
      register_project!(project_id)
      [h1, h2, h3, waiting] = Enum.map(1..4, &unique_id("run-#{&1}"))

      # Holders without a project reservation, so the project can be archived.
      for run_id <- [h1, h2, h3] do
        assert {:ok, _} =
                 CommandGateway.dispatch_system(%{
                   type: "run_slots.acquire",
                   command_id: "test:hold:#{run_id}",
                   aggregate_id: RunSlots.stream_id(project_id),
                   payload: %{run_id: run_id, capacity: 3, project_id: project_id}
                 })
      end

      assert {:ok, :slot_queued} = RunAdmission.start(project_id, plain_payload(waiting))

      assert {:ok, _} =
               ForemanServer.CommandRouter.dispatch(%{
                 aggregate_id: "project:#{project_id}",
                 command_id: "archive:#{project_id}",
                 type: "project.archive",
                 payload: %{project_id: project_id}
               })

      assert {:ok, _} =
               CommandGateway.dispatch_system(RunSlots.release_command(project_id, h1, "done"))

      # Capacity is free, yet admitting the waiter is refused: no run starts.
      assert {:error, :project_archived} =
               RunAdmission.start(project_id, plain_payload(waiting))

      refute ProjectionStore.run(waiting)
    end

    @tag skip:
           "AC-007-1 backstop sweep over project streams is TRD-008 (RunLifecycleReconciler); covered by TRD-008-TEST"
    test "abnormal death frees the slot: the backstop sweep releases it (AC-007-1)" do
      flunk("pending TRD-008")
    end
  end

  describe "slot gate is outermost" do
    test "slot acquire is dispatched on the project stream before lease acquire" do
      {:ok, _} = Application.ensure_all_started(:meck)
      :meck.new(ForemanServer.CommandGateway, [:passthrough, :no_link])

      test_pid = self()

      :meck.expect(ForemanServer.CommandGateway, :dispatch_system, fn command, timeout ->
        send(test_pid, {:dispatch_system, command.type, command.aggregate_id})
        :meck.passthrough([command, timeout])
      end)

      :meck.expect(ForemanServer.CommandGateway, :dispatch_system, fn command ->
        send(test_pid, {:dispatch_system, command.type, command.aggregate_id})
        :meck.passthrough([command])
      end)

      project_id = unique_id("project")
      run_id = unique_id("run")
      task_id = unique_id("task")

      try do
        register_project!(project_id)

        result = RunAdmission.start(project_id, lease_payload(run_id, task_id))
        assert {:ok, _} = result

        refute result in [{:ok, :queued}, {:ok, :slot_queued}],
               "RunAdmission.start returned #{inspect(result)} — slot/lease phase did not proceed"

        expected_stream = RunSlots.stream_id(project_id)
        assert_receive {:dispatch_system, "run_slots.acquire", ^expected_stream}
        assert_receive {:dispatch_system, "lease.acquire", aggregate_id}
        assert aggregate_id == ForemanServer.Aggregates.BeadsDbLease.stream_id(@lease_path)

        refute_receive {:dispatch_system, _, _}
      after
        if :meck.validate(ForemanServer.CommandGateway) do
          :meck.unload(ForemanServer.CommandGateway)
        end
      end
    end

    test "a run queued behind the Beads lease hands its slot back on its project stream" do
      project_id = unique_id("project")
      register_project!(project_id)
      other = unique_id("lease-holder")
      run_id = unique_id("run")

      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 type: "lease.acquire",
                 command_id: "test:lease:#{other}",
                 aggregate_id: ForemanServer.Aggregates.BeadsDbLease.stream_id(@lease_path),
                 payload: %{
                   db_path: @lease_path,
                   run_id: other,
                   task_id: unique_id("task"),
                   acquired_at_ms: System.system_time(:millisecond)
                 }
               })

      assert {:ok, :queued} =
               RunAdmission.start(project_id, lease_payload(run_id, unique_id("task")))

      # Acquired and released on the project's stream, not on run_slots:global.
      assert {:ok, events} =
               EventStore.read_stream_forward(RunSlots.stream_id(project_id), 0, 50)

      types = for %{event_type: type, data: data} <- events, run_of(data) == run_id, do: type
      assert "RunSlotAcquired" in types
      assert "RunSlotReleased" in types
      refute run_id in holder_ids(project_id)
    end

    test "resume re-acquires the slot on the run's project stream" do
      project_id = unique_id("project")
      register_project!(project_id)
      run_id = unique_id("run")

      payload = %{run_id: run_id, task_id: unique_id("task"), project_id: project_id}
      assert {:ok, :resumed} = RunAdmission.resume(payload)
      assert holder_ids(project_id) == [run_id]
    end

    test "a queued run is recorded on the project stream, not the global one" do
      project_id = unique_id("project")
      register_project!(project_id)
      set_project_limit!(project_id, 1)
      holder = unique_id("holder")
      queued = unique_id("queued")

      assert {:ok, _} = RunAdmission.start(project_id, plain_payload(holder))
      assert {:ok, :slot_queued} = RunAdmission.start(project_id, plain_payload(queued))

      assert {:ok, events} =
               EventStore.read_stream_forward(RunSlots.stream_id(project_id), 0, 50)

      assert Enum.any?(events, &(&1.event_type == "RunSlotQueued" and run_of(&1.data) == queued))
    end
  end

  defp run_of(data), do: Map.get(data, "run_id") || Map.get(data, :run_id)

  defp slot_state(project_id) do
    {state, _version} = Aggregate.load(RunSlots, RunSlots.stream_id(project_id))
    state
  end

  defp holder_ids(project_id), do: slot_state(project_id).holders |> Map.keys() |> Enum.sort()
  defp waiter_ids(project_id), do: Enum.map(slot_state(project_id).waiters, & &1.run_id)

  defp set_project_limit!(project_id, limit) do
    {:ok, _} =
      ForemanServer.CommandRouter.dispatch(%{
        aggregate_id: "project:#{project_id}",
        command_id: "limit:#{project_id}:#{limit}",
        type: "project.update",
        payload: %{project_id: project_id, max_concurrent_runs: limit}
      })
  end

  defp plain_payload(run_id) do
    %{
      run_id: run_id,
      task_id: unique_id("task"),
      workflow_snapshot: %{phases: [%{id: "p", kind: "command"}]},
      phase_specs: [%{phase_id: "p", kind: "command"}],
      approval_id: unique_id("approval")
    }
  end

  defp lease_payload(run_id, task_id) do
    %{
      run_id: run_id,
      task_id: task_id,
      workflow_snapshot: %{
        phases: [%{id: "phase-1", kind: "command"}],
        implementation: %{beads_database_path: @lease_path}
      }
    }
  end

  # Deleting the stream alone leaves live `run_slots:<project>` actors holding
  # another test's in-memory holders/waiters, so the gate can see free slots
  # the test just filled. The shared helper also kills the actor.
  defp cleanup_run_slots_stream do
    ForemanServer.TestSupport.RunSlotsReset.reset!()
  end

  defp cleanup_lease_stream do
    _ =
      EventStore.delete_stream(
        ForemanServer.Aggregates.BeadsDbLease.stream_id(@lease_path),
        :any_version,
        :hard
      )

    :ok
  end

  defp reset_projection_store do
    ProjectionStoreReset.reset!(keep_subscribers: true)
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  # These are all children of the application tree; a missing one is a boot
  # failure, not something a test should paper over by starting its own copy.
  defp assert_running!(name) do
    assert is_pid(Process.whereis(name)), "#{inspect(name)} is not running in the app tree"
  end

  defp register_project!(project_id) do
    {:ok, _} =
      ForemanServer.CommandRouter.dispatch(%{
        aggregate_id: "project:#{project_id}",
        command_id: "register:#{project_id}",
        type: "project.register",
        payload: %{
          project_id: project_id,
          name: "SlotGate #{project_id}",
          path: System.tmp_dir!()
        }
      })
  end
end
