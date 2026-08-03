defmodule ForemanServer.Overwatch.TrackerTest do
  @moduledoc """
  TRD-011 / AC-001-1..AC-001-5: Tracker is the sole dispatch owner for
  worker liveness events.

  These tests pin the AC-001-5 contract end-to-end:

    * AC-001-1: `register + heartbeat` allocates a monotonically increasing
      sequence per worker and appends `WorkerHeartbeat` to the worker stream.
    * AC-001-2: a missing heartbeat within the configured window emits
      `WorkerUnresponsive` EXACTLY once and fans out to the Recovery
      aggregate's `recovery.require` — and ONLY if the fan-out succeeds
      does the Tracker set `unresponsive_emitted?: true`. On failure,
      the timer re-arms so the next gap detection retries.
    * AC-001-3: a worker DOWN emits `WorkerExited` and PRESERVES the
      sequence mirror so a reconnect with the same `worker_id` continues
      from the next sequence.
    * AC-001-4: `unregister/3` clears BOTH the sequence mirror and the
      worker pid (explicit teardown).
    * AC-001-5: run projection stamps `needs_recovery: true` and the
      recovery stream receives `WorkerRecoveryRequired` exactly once.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Overwatch.Tracker
  alias ForemanServer.ProjectionStore

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp start_tracker(opts \\ []) do
    start_supervised!({Tracker, opts}, id: :tracker)
  end

  defp spawn_worker do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp read_worker_events(worker_id, run_id) do
    Store.read_stream_forward(Tracker.stream_id(worker_id, run_id), 0, 99_999_999)
    |> case do
      {:ok, events} -> events
      {:error, _} -> []
    end
  end

  defp read_recovery_events(run_id) do
    Store.read_stream_forward("recovery:#{run_id}", 0, 99_999_999)
    |> case do
      {:ok, events} -> events
      {:error, _} -> []
    end
  end

  defp count(events, type), do: Enum.count(events, &(&1.event_type == type))

  describe "AC-001-1: register + heartbeat" do
    test "allocates an increasing sequence and persists WorkerHeartbeat" do
      tracker = start_tracker()
      worker_id = uuid()
      run_id = uuid()
      worker_pid = spawn_worker()

      :ok = Tracker.register(tracker, worker_id, run_id, worker_pid)

      assert {:ok, 0} = Tracker.heartbeat(tracker, worker_id, run_id)
      assert {:ok, 1} = Tracker.heartbeat(tracker, worker_id, run_id)
      assert {:ok, 2} = Tracker.heartbeat(tracker, worker_id, run_id)

      events = read_worker_events(worker_id, run_id)
      assert count(events, "WorkerHeartbeat") == 3
      assert Enum.map(events, & &1.event_type) == ~w(WorkerHeartbeat WorkerHeartbeat WorkerHeartbeat)

      assert Tracker.sequence(tracker, worker_id, run_id) == 2
    end

    test "stream_id/2 is deterministic" do
      assert Tracker.stream_id("w", "r") == "worker:r:w"
      assert Tracker.stream_id("w", "r") == "worker:r:w"
    end
  end

  describe "AC-001-2 / AC-001-5: heartbeat timeout → WorkerUnresponsive + recovery.require" do
    test "after timeout the worker stream has exactly one WorkerUnresponsive and the recovery stream has exactly one WorkerRecoveryRequired" do
      tracker = start_tracker(heartbeat_timeout_ms: 50)
      worker_id = uuid()
      run_id = uuid()
      worker_pid = spawn_worker()

      :ok = Tracker.register(tracker, worker_id, run_id, worker_pid)

      # The Tracker must reach 60s-of-no-heartbeat (here 50ms) and:
      #   1) dispatch WorkerUnresponsive to the Worker aggregate stream
      #   2) dispatch recovery.require to the Recovery aggregate stream
      #   3) advance the sequence mirror
      # Both appends are synchronous (CommandRouter → EventStore). Wait
      # long enough for the timer to fire and the cross-stream fan-out
      # to round-trip.
      Process.sleep(250)

      worker_events = read_worker_events(worker_id, run_id)
      assert count(worker_events, "WorkerUnresponsive") == 1,
             "expected exactly one WorkerUnresponsive, got: #{inspect(Enum.map(worker_events, & &1.event_type))}"

      recovery_events = read_recovery_events(run_id)
      assert count(recovery_events, "WorkerRecoveryRequired") == 1,
             "expected exactly one WorkerRecoveryRequired, got: #{inspect(Enum.map(recovery_events, & &1.event_type))}"

      # Sequence mirror must have advanced past the unresponsive dispatch.
      # The first sequenced event on a fresh worker is seq=0.

      assert Tracker.sequence(tracker, worker_id, run_id) == 0

      # The Tracker must NOT emit a second WorkerUnresponsive for the
      # same worker even if more time elapses without a heartbeat — the
      # `unresponsive_emitted?` flag gates that path.
      Process.sleep(100)

      worker_events_later = read_worker_events(worker_id, run_id)
      assert count(worker_events_later, "WorkerUnresponsive") == 1
    end

    test "on timeout the run projection stamps needs_recovery: true" do
      tracker = start_tracker(heartbeat_timeout_ms: 50)
      worker_id = uuid()
      run_id = uuid()
      worker_pid = spawn_worker()

      :ok = Tracker.register(tracker, worker_id, run_id, worker_pid)
      Process.sleep(250)

      run = ProjectionStore.run_projection(run_id)
      assert is_map(run), "run projection should exist after WorkerUnresponsive"
      assert run.status == "needs_recovery"
      assert run.needs_recovery == true
      assert is_map(run.workers)
      assert is_map(run.workers[worker_id])
      assert run.workers[worker_id].status == "unresponsive"

      # The Recovery observation must also stamp the run projection.
      assert is_integer(run.recovery_observation_at_ms)
      assert run.recovery_observation_at_ms > 0
    end
  end

  describe "AC-001-3: DOWN preserves sequence, emits WorkerExited" do
    test "worker pid exits → sequence mirror retained, WorkerExited appended" do
      tracker = start_tracker()
      worker_id = uuid()
      run_id = uuid()
      worker_pid = spawn_worker()

      :ok = Tracker.register(tracker, worker_id, run_id, worker_pid)
      assert {:ok, 0} = Tracker.heartbeat(tracker, worker_id, run_id)
      assert {:ok, 1} = Tracker.heartbeat(tracker, worker_id, run_id)

      Process.exit(worker_pid, :kill)
      Process.sleep(100)

      assert Tracker.pid_for(tracker, worker_id, run_id) == nil
      assert Tracker.sequence(tracker, worker_id, run_id) == 2

      events = read_worker_events(worker_id, run_id)
      assert count(events, "WorkerExited") == 1
    end
  end

  describe "AC-001-4: explicit unregister drops BOTH sequence and worker pid" do
    test "after unregister the next register starts from a clean state" do
      tracker = start_tracker()
      worker_id = uuid()
      run_id = uuid()
      worker_pid = spawn_worker()

      :ok = Tracker.register(tracker, worker_id, run_id, worker_pid)
      assert {:ok, 0} = Tracker.heartbeat(tracker, worker_id, run_id)

      :ok = Tracker.unregister(tracker, worker_id, run_id)
      assert Tracker.pid_for(tracker, worker_id, run_id) == nil
      assert Tracker.sequence(tracker, worker_id, run_id) == 0

      new_pid = spawn_worker()
      :ok = Tracker.register(tracker, worker_id, run_id, new_pid)
      assert {:ok, 1} = Tracker.heartbeat(tracker, worker_id, run_id)
    end
  end
end
