defmodule ForemanServer.TelemetryTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandRouter, Overwatch, Telemetry}
  alias ForemanServer.Overwatch.Tracker
  alias ForemanServer.TestSupport.BlockCommand

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defmodule Handler do
    def attach_event_handlers(pid, events) do
      ref = make_ref()
      handler_id = {:telemetry_test, ref}
      :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, {pid, ref})
      {handler_id, ref}
    end

    def handle_event(event, measurements, metadata, {pid, ref}) do
      send(pid, {event, ref, measurements, metadata})
    end
  end

  defp aggregate_pid(aggregate_id) do
    [{pid, _}] = Registry.lookup(ForemanServer.AggregateRegistry, aggregate_id)
    pid
  end

  defp await_actor_alive(aggregate_id, retries) do
    Enum.reduce_while(1..retries, nil, fn _, _ ->
      case Registry.lookup(ForemanServer.AggregateRegistry, aggregate_id) do
        [{pid, _}] ->
          if Process.alive?(pid) do
            {:halt, {:ok, pid}}
          else
            Process.sleep(10)
            {:cont, nil}
          end

        _ ->
          Process.sleep(10)
          {:cont, nil}
      end
    end)
  end

  test "fires command and aggregate telemetry events" do
    {handler_id, ref} = Handler.attach_event_handlers(self(), Telemetry.all_events())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    aggregate_id = "blocking:#{uuid()}"
    release_ref = make_ref()
    test_pid = self()

    dispatch_task =
      Task.async(fn ->
        CommandRouter.dispatch(%BlockCommand{
          aggregate_id: aggregate_id,
          aggregate_type: "blocking",
          ref: release_ref,
          notify_pid: test_pid
        })
      end)

    assert_receive {:block_entered, ^release_ref, actor_pid}, 5_000
    send(actor_pid, {:release, release_ref})

    assert {:ok, %{"event_type" => "BlockEvent"}} = Task.await(dispatch_task, 5_000)

    assert_received {[:foreman, :command, :dispatch], ^ref,
                     %{duration_ms: duration_ms, append_latency_ms: append_latency_ms},
                     %{status: "ok", aggregate_id: ^aggregate_id}}

    assert is_integer(duration_ms) and duration_ms >= 0
    assert is_integer(append_latency_ms) and append_latency_ms >= 0

    old_pid = aggregate_pid(aggregate_id)
    down_ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)

    assert_receive {:DOWN, ^down_ref, :process, ^old_pid, :killed}, 5_000
    assert {:ok, new_pid} = await_actor_alive(aggregate_id, 50)
    refute new_pid == old_pid

    assert_receive {[:foreman, :aggregate, :rehydrated], ^ref, %{event_count: 1}, %{}}, 5_000

    # Smoke-test that the new Supervisor-based Overwatch is startable and that
    # the Tracker accepts a heartbeat. Worker-telemetry events are not yet
    # wired through the new Supervisor (they were emitted by the older
    # telemetry-only Overwatch GenServer that this rewrite replaces); the
    # dispatch/aggregate telemetry surface above is the contract under test.
    _overwatch = start_supervised!({Overwatch, [name: nil]})

    worker_run_id = uuid()
    worker_id = uuid()

    worker_pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill) end)

    :ok = Tracker.register(worker_id, worker_run_id, worker_pid)
    assert {:ok, _seq} = Tracker.heartbeat(worker_id, worker_run_id)

    Process.exit(worker_pid, :kill)
    _ = Tracker.unregister(worker_id, worker_run_id)
  end

  test "fires dispatcher and run_slots telemetry helpers" do
    {handler_id, ref} = Handler.attach_event_handlers(self(), Telemetry.all_events())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    Telemetry.run_dispatcher_admission_failed(task_id: "task-1", reason: ":boom")
    Telemetry.run_slots_acquired("run-1", 2, 3)
    Telemetry.run_slots_queued("run-2", 4, 4)
    Telemetry.run_slots_released("run-1", 1, :aggregate)
    Telemetry.run_slots_transferred("run-1", "run-2", 3)
    Telemetry.run_slots_waiter_removed("run-3", 2, :aggregate)
    Telemetry.run_slots_reconciled(1, 2, :boot)

    assert_receive {[:foreman_server, :dispatcher, :admission_failed], ^ref, %{},
                    %{task_id: "task-1", reason: ":boom"}}

    assert_receive {[:foreman_server, :run_slots, :acquired], ^ref, %{holders: 2, capacity: 3},
                    %{run_id: "run-1", source: :aggregate}}

    assert_receive {[:foreman_server, :run_slots, :queued], ^ref, %{depth: 4},
                    %{run_id: "run-2", position: 4}}

    assert_receive {[:foreman_server, :run_slots, :released], ^ref, %{holders: 1},
                    %{run_id: "run-1", reason: :aggregate}}

    assert_receive {[:foreman_server, :run_slots, :transferred], ^ref, %{depth: 3},
                    %{released_run_id: "run-1", acquired_run_id: "run-2"}}

    assert_receive {[:foreman_server, :run_slots, :waiter_removed], ^ref, %{depth: 2},
                    %{run_id: "run-3", reason: :aggregate}}

    assert_receive {[:foreman_server, :run_slots, :reconciled], ^ref,
                    %{holders_dropped: 1, waiters_dropped: 2}, %{phase: :boot}}
  end

  test "dispatch_run_stop/2 emits [:foreman, :dispatch, :run, :stop] with the expected measurements and metadata" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:foreman, :dispatch, :run, :stop]])
    on_exit(fn -> :telemetry.detach(ref) end)

    measurements = %{duration_ms: 42}
    metadata = %{provider: :pi, status: :ok, run_id: "run-1", adapter: :jido_harness}

    assert :ok = Telemetry.dispatch_run_stop(measurements, metadata)

    assert_receive {[:foreman, :dispatch, :run, :stop], ^ref, %{duration_ms: 42},
                    %{provider: :pi, status: :ok, run_id: "run-1", adapter: :jido_harness}}
  end

  test "dispatch_run_stop/2 with status: :ok emits metadata containing provider, status, run_id, adapter" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:foreman, :dispatch, :run, :stop]])
    on_exit(fn -> :telemetry.detach(ref) end)

    Telemetry.dispatch_run_stop(
      %{duration_ms: 17},
      %{provider: :claude, status: :ok, run_id: "run-2", adapter: :jido_harness}
    )

    assert_receive {[:foreman, :dispatch, :run, :stop], ^ref, _measurements, received_metadata}

    assert received_metadata.provider == :claude
    assert received_metadata.status == :ok
    assert received_metadata.run_id == "run-2"
    assert received_metadata.adapter == :jido_harness
  end

  test "dispatch_provider_check/2 emits [:foreman, :dispatch, :provider, :check] with installed: true and the install_hint" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [[:foreman, :dispatch, :provider, :check]])

    on_exit(fn -> :telemetry.detach(ref) end)

    metadata = %{
      provider: :pi,
      installed: true,
      install_hint: "npm install -g @earendil-works/pi-coding-agent"
    }

    assert :ok = Telemetry.dispatch_provider_check(%{}, metadata)

    assert_receive {[:foreman, :dispatch, :provider, :check], ^ref, %{},
                    %{
                      provider: :pi,
                      installed: true,
                      install_hint: "npm install -g @earendil-works/pi-coding-agent"
                    }}
  end

  test "dispatch_provider_check/2 with installed: false emits metadata containing installed: false" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [[:foreman, :dispatch, :provider, :check]])

    on_exit(fn -> :telemetry.detach(ref) end)

    Telemetry.dispatch_provider_check(
      %{},
      %{
        provider: :pi,
        installed: false,
        install_hint: "npm install -g @earendil-works/pi-coding-agent"
      }
    )

    assert_receive {[:foreman, :dispatch, :provider, :check], ^ref, _measurements,
                    received_metadata}

    assert received_metadata.installed == false
    assert received_metadata.provider == :pi
  end
end
