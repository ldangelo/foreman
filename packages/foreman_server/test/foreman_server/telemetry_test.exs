defmodule ForemanServer.TelemetryTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandRouter, Overwatch, Telemetry}
  alias ForemanServer.TestSupport.BlockCommand

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

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


  test "fires command, aggregate, and worker telemetry events" do
    ref = :telemetry_test.attach_event_handlers(self(), Telemetry.all_events())
    on_exit(fn -> :telemetry.detach(ref) end)

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

    overwatch = start_supervised!({Overwatch, [name: nil]})

    worker_run_id = uuid()
    worker_id = uuid()

    assert :ok = Overwatch.heartbeat(overwatch, %{run_id: worker_run_id, worker_id: worker_id})

    assert_receive {[:foreman, :worker, :heartbeat], ^ref, %{count: 1},
                    %{run_id: ^worker_run_id, worker_id: ^worker_id}}, 5_000

    worker_pid = spawn(fn -> Process.sleep(:infinity) end)
    _monitor_ref = Overwatch.monitor_worker(overwatch, worker_pid, %{run_id: worker_run_id, worker_id: worker_id})
    Process.exit(worker_pid, :kill)

    assert_receive {[:foreman, :worker, :exit], ^ref, %{count: 1},
                    %{run_id: ^worker_run_id, worker_id: ^worker_id, reason: ":killed"}}, 5_000
  end
end
