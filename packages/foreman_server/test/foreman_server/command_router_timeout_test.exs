defmodule ForemanServer.CommandRouterTimeoutTest do
  @moduledoc """
  A command whose aggregate actor does not answer within the call timeout is a failed
  command, never a dead caller.

  `CommandRouter.dispatch/2` used to let the `GenServer.call` exit escape, so whichever
  process issued the command died with `{:timeout, {GenServer, :call, ...}}`: the Overwatch
  `Tracker` (and with it every live worker), the `BeadsWatcher`, and a `RunExecutor` that had
  already finished all its phases. It now returns `{:error, %ForemanServer.CommandTimeout{}}`.

  The actor is made slow the two ways a real one is: held (`:sys.suspend/1`, so it answers
  nothing) and busy inside `handle_command/2` (`BlockingAggregate`, so it answers once released).
  Nothing here sleeps for the timeout: it is passed to `dispatch/2`, so a failing test reports
  after tens of milliseconds, not five seconds.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.{Aggregator, CommandRouter, CommandTimeout, Telemetry}
  alias ForemanServer.Aggregates.Worker
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Overwatch.Tracker
  alias ForemanServer.TelemetryTest.Handler
  alias ForemanServer.TestSupport.BlockCommand

  # What the caller is given to answer in. The slow actor never answers inside it.
  @timeout_ms 50

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  # A `Worker` actor that has started and answers nothing: the commands sent to it wait in its
  # mailbox, in order, until it is resumed.
  defp stalled_worker do
    worker_id = uuid()
    run_id = uuid()
    aggregate_id = Tracker.stream_id(worker_id, run_id)
    {:ok, actor} = Aggregator.start_aggregate(Worker, aggregate_id)
    :ok = :sys.suspend(actor)
    on_exit(fn -> resume_quietly(actor) end)

    %{
      actor: actor,
      aggregate_id: aggregate_id,
      worker_id: worker_id,
      run_id: run_id,
      command: heartbeat(aggregate_id, worker_id, run_id)
    }
  end

  # The command the Tracker sends for a worker's first heartbeat.
  defp heartbeat(aggregate_id, worker_id, run_id) do
    %{
      aggregate_id: aggregate_id,
      type: "worker.record",
      command_id: "#{run_id}:#{worker_id}:WorkerHeartbeat:0",
      payload: %{
        "event_type" => "WorkerHeartbeat",
        "worker_id" => worker_id,
        "run_id" => run_id,
        "sequence" => 0,
        "timestamp" => System.system_time(:millisecond)
      }
    }
  end

  # `:sys.resume/1` on an actor the test already killed or resumed is not a failure of the test.
  defp resume_quietly(actor) do
    :sys.resume(actor)
  catch
    :exit, _ -> :ok
  end

  # Runs `fun` in a process of its own, so that what happens to its caller is observable: the
  # result it returns is sent back, and it then stays alive until told to stop. A caller killed by
  # an exit never sends a result, and its DOWN says why.
  defp call_in_own_process(fun) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(parent, {:returned, self(), fun.()})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    {pid, monitor}
  end

  describe "an actor that does not answer in time" do
    test "returns the timeout as a typed error and leaves the caller alive" do
      %{aggregate_id: aggregate_id, command: command} = stalled_worker()

      {caller, monitor} =
        call_in_own_process(fn -> CommandRouter.dispatch(command, @timeout_ms) end)

      assert_receive {:returned, ^caller, result}, 5_000

      assert {:error,
              %CommandTimeout{
                aggregate_id: ^aggregate_id,
                command_type: "worker.record",
                timeout_ms: @timeout_ms
              }} = result

      refute_received {:DOWN, ^monitor, :process, ^caller, _}
      assert Process.alive?(caller)
    end

    test "is observable: a warning naming the command and the dispatch telemetry as an error" do
      %{aggregate_id: aggregate_id, command: command} = stalled_worker()
      {handler_id, ref} = Handler.attach_event_handlers(self(), [[:foreman, :command, :dispatch]])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      log =
        capture_log([level: :warning], fn ->
          assert {:error, %CommandTimeout{}} = CommandRouter.dispatch(command, @timeout_ms)
        end)

      assert log =~ aggregate_id
      assert log =~ "worker.record"
      assert log =~ "#{@timeout_ms}ms"

      assert_received {[:foreman, :command, :dispatch], ^ref, %{duration_ms: duration_ms},
                       %{status: "error", aggregate_id: ^aggregate_id}}

      assert duration_ms >= @timeout_ms - 5
      assert [:foreman, :command, :dispatch] in Telemetry.all_events()
    end

    test "a command without a type is named by what it has: the type is nil, not a crash" do
      aggregate_id = "blocking:#{uuid()}"
      ref = make_ref()

      command = %BlockCommand{
        aggregate_id: aggregate_id,
        aggregate_type: "blocking",
        ref: ref,
        notify_pid: self()
      }

      assert {:error, %CommandTimeout{aggregate_id: ^aggregate_id, command_type: nil}} =
               CommandRouter.dispatch(command, @timeout_ms)

      # The actor is inside `handle_command/2`, waiting to be released.
      assert_received {:block_entered, ^ref, actor}
      send(actor, {:release, ref})
    end

    test "the answer that comes after the timeout never reaches the caller" do
      aggregate_id = "blocking:#{uuid()}"
      ref = make_ref()

      command = %BlockCommand{
        aggregate_id: aggregate_id,
        aggregate_type: "blocking",
        ref: ref,
        notify_pid: self()
      }

      assert {:error, %CommandTimeout{}} = CommandRouter.dispatch(command, @timeout_ms)
      assert_received {:block_entered, ^ref, actor}

      # The actor finishes the command now and replies to a caller that has given up. The next
      # call to it returns only after that reply was sent.
      send(actor, {:release, ref})
      _state = ForemanServer.Aggregate.Actor.get_state(actor)

      refute_receive _anything, 100
    end

    test "the command still lands once the actor answers, and the same command_id is not applied twice" do
      %{actor: actor, aggregate_id: aggregate_id, command: command} = stalled_worker()

      assert {:error, %CommandTimeout{}} = CommandRouter.dispatch(command, @timeout_ms)

      # The timed-out command is still in the actor's mailbox: the outcome the caller was told
      # nothing about is that it is applied as soon as the actor is back.
      :ok = :sys.resume(actor)
      _state = ForemanServer.Aggregate.Actor.get_state(actor)

      # The caller's answer is to send it again. The command id is the same, so the actor answers
      # with the event it already wrote instead of writing a second.
      assert {:ok, %{"event_type" => "WorkerHeartbeat"}} = CommandRouter.dispatch(command)

      {:ok, events} = Store.read_stream_forward(aggregate_id, 0, 99_999_999)
      assert Enum.map(events, & &1.event_type) == ["WorkerHeartbeat"]
    end
  end

  describe "the exits that are not a call timeout" do
    test "still take the caller down, as before" do
      %{actor: actor, command: command} = stalled_worker()

      {caller, monitor} =
        spawn_monitor(fn ->
          # A short timeout, but the actor is killed long before it: not a timeout.
          CommandRouter.dispatch(command, 30_000)
        end)

      # The command is waiting in the actor's mailbox: the caller is inside its call.
      await_queued(actor)
      Process.exit(actor, :kill)

      assert_receive {:DOWN, ^monitor, :process, ^caller, {:killed, {GenServer, :call, _call}}},
                     5_000
    end
  end

  defp await_queued(actor, attempts \\ 200) do
    {:message_queue_len, queued} = Process.info(actor, :message_queue_len)

    cond do
      queued > 0 ->
        :ok

      attempts == 0 ->
        flunk("the command never reached the actor's mailbox")

      true ->
        Process.sleep(10)
        await_queued(actor, attempts - 1)
    end
  end
end
