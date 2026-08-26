defmodule ForemanServer.Workflow.DispatcherSlotReleaseTest do
  use ExUnit.Case, async: false

  alias EventStore.RecordedEvent
  alias ForemanServer.Aggregates.BeadsDbLease
  alias ForemanServer.CommandGateway
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Workflow.BootReconciliation
  alias ForemanServer.Workflow.Dispatcher
  alias ForemanServer.TestSupport.RunSlotsReset

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
    ensure_started(ForemanServer.TaskProvider.Registry, ForemanServer.TaskProvider.Registry)

    ensure_started(
      {Registry, keys: :unique, name: ForemanServer.RunExecutorRegistry},
      ForemanServer.RunExecutorRegistry
    )

    ensure_started(
      ForemanServer.AgentRuntime.AdapterCatalog,
      ForemanServer.AgentRuntime.AdapterCatalog
    )

    ensure_started(ForemanServer.Workflow.Catalog, ForemanServer.Workflow.Catalog)
    ensure_started(ForemanServer.Workflow.RunSupervisor, ForemanServer.Workflow.RunSupervisor)
    ensure_started(ForemanServer.Workflow.Dispatcher, ForemanServer.Workflow.Dispatcher)

    ensure_started(
      ForemanServer.Workflow.BootReconciliation,
      ForemanServer.Workflow.BootReconciliation
    )

    :ok
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:meck)
    :meck.new(ForemanServer.CommandGateway, [:passthrough, :no_link])

    test_pid = self()

    :meck.expect(ForemanServer.CommandGateway, :dispatch_system, fn command, timeout ->
      if command.type == "run_slots.release" do
        send(test_pid, {:dispatch_system, command, timeout})
      end

      :meck.passthrough([command, timeout])
    end)

    :meck.expect(ForemanServer.CommandGateway, :dispatch_system, fn command ->
      if command.type == "run_slots.release" do
        send(test_pid, {:dispatch_system, command, 5_000})
      end

      :meck.passthrough([command])
    end)

    on_exit(fn ->
      if :meck.validate(ForemanServer.CommandGateway) do
        :meck.unload(ForemanServer.CommandGateway)
      end
    end)

    parent = self()
    boot_name = ForemanServer.Workflow.BootReconciliation
    real_pid = Process.whereis(boot_name)

    forwarder =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        forward_loop(parent, real_pid)
      end)

    Process.unregister(boot_name)
    :erlang.register(boot_name, forwarder)

    on_exit(fn ->
      if Process.whereis(boot_name) == forwarder do
        Process.unregister(boot_name)
      end

      if Process.alive?(real_pid) do
        :erlang.register(boot_name, real_pid)
      end

      Process.exit(forwarder, :kill)
    end)

    :ok
  end

  describe "terminal run events emit run_slots.release" do
    test "RunCompleted emits run_slots.release" do
      assert_slot_release_for_terminal_event("RunCompleted", %{
        run_id: unique_run_id(),
        status: "completed"
      })
    end

    test "RunFailed emits run_slots.release" do
      assert_slot_release_for_terminal_event("RunFailed", %{
        run_id: unique_run_id(),
        status: "failed",
        failure_reason: "boom"
      })
    end

    test "RunCancelled emits run_slots.release" do
      assert_slot_release_for_terminal_event("RunCancelled", %{
        run_id: unique_run_id(),
        status: "cancelled"
      })
    end

    test "RunFlaggedStuck emits run_slots.release" do
      assert_slot_release_for_terminal_event("RunFlaggedStuck", %{
        run_id: unique_run_id(),
        flagged_at: 1_700_000_000_000
      })
    end

    test "RunBlocked emits run_slots.release" do
      assert_slot_release_for_terminal_event("RunBlocked", %{
        run_id: unique_run_id(),
        reason: "gate_timeout"
      })
    end

    test "non-terminal event does not emit release" do
      run_id = unique_run_id()
      send_envelope(%{event_type: "TaskApproved", data: %{task_id: "task-x", run_id: run_id}})
      refute_receive {:"$gen_cast", {:run_terminated, ^run_id, _}}, 100
      assert_no_run_slot_release()
    end

    test "duplicate terminal event is idempotent (one release)" do
      run_id = unique_run_id()

      send_envelope(%{event_type: "RunCompleted", data: %{run_id: run_id, status: "completed"}})

      assert_receive {:dispatch_system, %{type: "run_slots.release", payload: %{run_id: ^run_id}},
                      5_000},
                     500

      send_envelope(%{event_type: "RunCompleted", data: %{run_id: run_id, status: "completed"}})

      releases = collect_slot_release_dispatches(run_id, 200, 0)
      assert releases == 1
    end
  end

  defp assert_slot_release_for_terminal_event(event_type, payload) do
    run_id = payload.run_id
    send_envelope(%{event_type: event_type, data: payload})

    assert_receive {:"$gen_cast", {:run_terminated, ^run_id, _reason}}, 500

    assert_receive {:dispatch_system, command, 5_000}, 500
    assert command.type == "run_slots.release"
    assert command.aggregate_id == "run_slots:global"
    assert command.payload.run_id == run_id
  end

  defp assert_no_run_slot_release do
    refute_receive {:dispatch_system, %{type: "run_slots.release"}, _}, 100
  end

  defp collect_slot_release_dispatches(run_id, timeout_ms, count) do
    receive do
      {:dispatch_system, %{type: "run_slots.release", payload: %{run_id: ^run_id}}, 5_000} ->
        collect_slot_release_dispatches(run_id, timeout_ms, count + 1)
    after
      timeout_ms ->
        count
    end
  end

  defp send_envelope(envelope) do
    {:noreply, _state} = Dispatcher.handle_info({:projection_event, envelope}, %{pending: %{}})
  end

  defp forward_loop(parent, real_pid) do
    receive do
      {:EXIT, _, _} ->
        :ok

      {:"$gen_cast", _} = msg ->
        send(real_pid, msg)
        send(parent, msg)
        forward_loop(parent, real_pid)

      {:dispatch_system, _, _} = msg ->
        send(parent, msg)
        forward_loop(parent, real_pid)

      msg ->
        send(parent, msg)
        forward_loop(parent, real_pid)
    end
  end

  defp unique_run_id do
    "run-slot-release-#{System.unique_integer([:positive])}"
  end

  defp ensure_started(child_spec, name) do
    case Process.whereis(name) do
      nil -> start_supervised!(child_spec)
      _pid -> :ok
    end
  end
end
