defmodule ForemanServer.RunAdmissionSlotGateTest do
  use ExUnit.Case, async: false

  alias EventStore.EventData
  alias ForemanServer.{EventStore, ProjectionStore, RunAdmission}

  @run_slots_stream "run_slots:global"
  @lease_path "/tmp/trd-006-slot-gate.db"

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
    :ok
  end

  setup do
    previous_capacity = Application.get_env(:foreman_server, :max_concurrent_runs)

    cleanup_run_slots_stream()
    cleanup_lease_stream()
    reset_projection_store()

    on_exit(fn ->
      cleanup_run_slots_stream()
      cleanup_lease_stream()
      reset_projection_store()

      if previous_capacity == nil do
        Application.delete_env(:foreman_server, :max_concurrent_runs)
      else
        Application.put_env(:foreman_server, :max_concurrent_runs, previous_capacity)
      end
    end)

    :ok
  end

  describe "slot gate is outermost" do
    test "fourth admission at capacity 3 returns {:ok, :slot_queued}" do
      holder_run_ids = Enum.map(1..3, &unique_id("holder-#{&1}"))
      queued_run_id = unique_id("queued-run")
      project_id = unique_id("project")
      task_id = unique_id("task")

      set_global_capacity!(3)

      Enum.with_index(holder_run_ids, 0)
      |> Enum.each(fn {run_id, version} -> append_run_slot_holder!(run_id, version) end)

      assert {:ok, :slot_queued} =
               RunAdmission.start(project_id, lease_payload(queued_run_id, task_id))

      refute ProjectionStore.run(queued_run_id)
      refute lease_holder?(queued_run_id)

      assert {:ok, events} = EventStore.read_stream_forward(@run_slots_stream, 0, 50)

      assert Enum.any?(events, fn
               %{event_type: "RunSlotQueued", data: data} ->
                 run_id_str =
                   Map.get(data, "run_id") || Map.get(data, :run_id)

                 run_id_str == queued_run_id

               _ ->
                 false
             end)
    end

    test "slot acquire is dispatched before lease acquire" do
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
        set_global_capacity!(3)

        result = RunAdmission.start(project_id, lease_payload(run_id, task_id))
        assert {:ok, _} = result

        refute result in [{:ok, :queued}, {:ok, :slot_queued}],
               "RunAdmission.start returned #{inspect(result)} — slot/lease phase did not proceed"

        assert_receive {:dispatch_system, "run_slots.acquire", "run_slots:global"}
        assert_receive {:dispatch_system, "lease.acquire", aggregate_id}
        assert aggregate_id == ForemanServer.Aggregates.BeadsDbLease.stream_id(@lease_path)

        refute_receive {:dispatch_system, _, _}
      after
        if :meck.validate(ForemanServer.CommandGateway) do
          :meck.unload(ForemanServer.CommandGateway)
        end
      end
    end

    test "first three admissions proceed normally" do
      project_id = unique_id("project")
      run_ids = Enum.map(1..3, &unique_id("run-#{&1}"))

      register_project!(project_id)
      set_global_capacity!(3)

      results =
        Enum.map(run_ids, fn run_id ->
          RunAdmission.start(project_id, lease_payload(run_id, unique_id("task")))
        end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      refute Enum.any?(results, &match?({:ok, :slot_queued}, &1))

      assert {:ok, events} = EventStore.read_stream_forward(@run_slots_stream, 0, 50)

      acquired_run_ids =
        for %{event_type: "RunSlotAcquired", data: data} <- events,
            run_id = Map.get(data, "run_id") || Map.get(data, :run_id),
            do: run_id

      assert acquired_run_ids == run_ids
    end
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

  defp lease_holder?(run_id) do
    aggregate_id = ForemanServer.Aggregates.BeadsDbLease.stream_id(@lease_path)

    case Registry.lookup(ForemanServer.AggregateRegistry, aggregate_id) do
      [{pid, _}] ->
        case ForemanServer.Aggregate.Actor.get_state(pid) do
          %{holder: %{run_id: ^run_id}} -> true
          _ -> false
        end

      [] ->
        false
    end
  end

  defp set_global_capacity!(capacity) do
    Application.put_env(:foreman_server, :max_concurrent_runs, capacity)
  end

  defp cleanup_run_slots_stream do
    _ = EventStore.delete_stream(@run_slots_stream, :any_version, :hard)
    :ok
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

  defp append_run_slot_holder!(run_id, version) do
    acquired_at_ms = System.system_time(:millisecond)

    :ok =
      EventStore.append_to_stream(@run_slots_stream, version, [
        %EventData{
          event_type: "RunSlotAcquired",
          data: %{
            run_id: run_id,
            capacity: 3,
            acquired_at_ms: acquired_at_ms
          },
          metadata: %{}
        }
      ])

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunSlotAcquired",
          payload: %{run_id: run_id, capacity: 3, acquired_at_ms: acquired_at_ms}
        }
      ])
  end

  defp reset_projection_store do
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
        run_slots: %{capacity: 0, holders: %{}, waiters: []},
        works: %{},
        project_active_runs: %{}
      }
    end)
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  defp ensure_started(child_spec, name) do
    case Process.whereis(name) do
      nil -> Supervisor.start_child(ForemanServer.Supervisor, child_spec)
      pid -> {:ok, pid}
    end
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
