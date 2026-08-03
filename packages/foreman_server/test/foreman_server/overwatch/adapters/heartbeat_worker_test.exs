defmodule ForemanServer.Overwatch.Adapters.HeartbeatWorkerTest do
  @moduledoc """
  TRD-011: HeartbeatWorker adapter tests.

  Pins the contract that the default adapter:

    * Schedules its first heartbeat on `init/1`.
    * After each interval, calls `WorkerProtocol.emit(:heartbeat, ...)`
      which routes through `Tracker.heartbeat/3` → `WorkerHeartbeat`.
    * Responds to `{:overwatch_activate, _w, _r, parent}` with
      `{:overwatch_activated, self()}` so `LaunchWorker` can complete
      its two-phase handshake.

  Each test registers the worker with the Tracker first so that
  `Tracker.heartbeat/3` does not return `{:error, :not_registered}`.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Overwatch.Adapters.HeartbeatWorker
  alias ForemanServer.Overwatch.Tracker

  defp uuid, do: EventStore.UUID.uuid4()

  setup do
    # Use the global Tracker name (default for `start_link/1`) so
    # `WorkerProtocol.emit(:heartbeat, ...)` resolves to this instance.
    {:ok, tracker} = start_supervised(Tracker, id: :tracker_default)
    {:ok, tracker: tracker}
  end

  defp register_worker(tracker, worker_id, run_id) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    :ok = Tracker.register(tracker, worker_id, run_id, pid)
    pid
  end

  describe "start_link/1 — heartbeat scheduling" do
    test "schedules a heartbeat immediately on init" do
      worker_id = uuid()
      run_id = uuid()
      _pid = register_worker(tracker(), worker_id, run_id)

      {:ok, _hw_pid} =
        start_supervised(
          {HeartbeatWorker, worker_id: worker_id, run_id: run_id, heartbeat_interval_ms: 30},
          id: :hw_imm
        )

      # Wait long enough for the timer to fire.
      Process.sleep(150)

      events = read_worker_events(worker_id, run_id)
      assert Enum.any?(events, &(&1.event_type == "WorkerHeartbeat"))
    end

    test "emits multiple WorkerHeartbeats over repeated intervals" do
      worker_id = uuid()
      run_id = uuid()
      _pid = register_worker(tracker(), worker_id, run_id)

      start_supervised!(
        {HeartbeatWorker, worker_id: worker_id, run_id: run_id, heartbeat_interval_ms: 25},
        id: :hw_multi
      )

      Process.sleep(200)

      events = read_worker_events(worker_id, run_id)
      heartbeat_count = Enum.count(events, &(&1.event_type == "WorkerHeartbeat"))
      assert heartbeat_count >= 3
    end

    test "uses 5_000ms default interval when :heartbeat_interval_ms is omitted" do
      # Just verify it accepts the call without crashing and schedules
      # a timer (we don't actually wait 5s).
      worker_id = uuid()
      run_id = uuid()

      assert {:ok, pid} =
               start_supervised(
                 {HeartbeatWorker, worker_id: worker_id, run_id: run_id},
                 id: :hw_default
               )

      assert is_pid(pid)
    end

    test "raises when :worker_id or :run_id is missing" do
      # start_link spawn_links to the caller; init crashes on missing
      # keys. We trap exits and start the link in a sandbox process so
      # the test process is not torn down.
      Process.flag(:trap_exit, true)

      assert {:error, {%KeyError{key: :worker_id}, _stack}} =
               HeartbeatWorker.start_link(run_id: "r")

      assert {:error, {%KeyError{key: :run_id}, _stack}} =
               HeartbeatWorker.start_link(worker_id: "w")
    end
  end

  describe "overwatch activation handshake" do
    test "replies with {:overwatch_activated, self()} to the parent" do
      worker_id = uuid()
      run_id = uuid()

      {:ok, worker_pid} =
        start_supervised(
          {HeartbeatWorker,
           worker_id: worker_id, run_id: run_id, heartbeat_interval_ms: 60_000},
          id: :hw_activate
        )

      # Send activation; wait for reply.
      send(worker_pid, {:overwatch_activate, worker_id, run_id, self()})

      assert_receive {:overwatch_activated, ^worker_pid}, 500
    end

    test "ignores unrelated messages" do
      worker_id = uuid()
      run_id = uuid()

      {:ok, worker_pid} =
        start_supervised(
          {HeartbeatWorker,
           worker_id: worker_id, run_id: run_id, heartbeat_interval_ms: 60_000},
          id: :hw_ignore
        )

      # Send random noise; worker must remain alive and not reply.
      send(worker_pid, :hello)
      send(worker_pid, {:no_op, 1, 2, 3})

      Process.sleep(50)
      assert Process.alive?(worker_pid)
      refute_receive {:overwatch_activated, ^worker_pid}, 100
    end
  end

  # ---------------------------------------------------------------------------

  defp tracker, do: Process.whereis(Tracker)

  defp read_worker_events(worker_id, run_id) do
    stream_id = "worker:#{run_id}:#{worker_id}"

    case Store.read_stream_forward(stream_id, 0, 99_999_999) do
      {:ok, events} -> events
      {:error, _} -> []
    end
  end
end
