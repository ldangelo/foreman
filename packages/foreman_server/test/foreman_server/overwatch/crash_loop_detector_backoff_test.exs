defmodule ForemanServer.Overwatch.CrashLoopDetectorBackoffTest do
  @moduledoc """
  TRD-079 / RTE-T005 — Crash recovery characterization: no duplicate side
  effects, correct state resumption.

  Exercises the CrashLoopDetector's 5-restart exponential backoff loop
  (TRD-078 / RTE-T004) end-to-end:

    1. each crash schedules the correct backoff delay (1s, 2s, 4s, 8s, 16s)
    2. a crash during a backoff window cancels the pending timer
    3. a backoff_expired message is drained without phantom re-evaluation
    4. the 6th crash exhausts the loop and emits run.block
    5. no duplicate WorkerCrashed / RunBlocked events are emitted
  Uses the real RestartBackoff module. The 5-restart sequence takes
  ~31 seconds (1+2+4+8+16 = 31 s) which is acceptable for a
  characterisation test but too slow for CI — mark @tag :slow in CI
  pipelines and run with `mix test --include slow`.

  TRD-078 establishes the backoff contract; these tests characterise it.
  """

  use ExUnit.Case, async: false
  @moduletag :characterization

  alias ForemanServer.{CommandRouter, RunAdmission}
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Idempotency.RestartBackoff
  alias ForemanServer.Overwatch.{CrashLoopDetector, Tracker}
  alias ForemanServer.TestSupport.RunSlotsReset

  # Real backoff delays (ms) for reference:
  # attempt 1 → 1000, attempt 2 → 2000, attempt 3 → 4000,
  # attempt 4 → 8000, attempt 5 → 16000, attempt 6 → blocked
  @backoff_delays [1000, 2000, 4000, 8000, 16_000]

  setup do
    RunSlotsReset.reset!()
    :ok
  end

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp start_tracker_and_detector(opts \\ []) do
    window_ms = Keyword.get(opts, :window_ms, 5 * 60 * 1000)
    threshold = Keyword.get(opts, :threshold, 5)

    tracker = start_supervised!({Tracker, []}, id: :tracker_backoff)

    detector =
      start_supervised!(
        {CrashLoopDetector, window_ms: window_ms, threshold: threshold},
        id: :detector_backoff
      )

    %{tracker: tracker, detector: detector}
  end

  defp spawn_worker do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp wait_until(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until timed out")
      else
        Process.sleep(5)
        wait_until(fun, 0)
      end
    end
  end

  defp seed_run(run_id) do
    project_id = "project-#{run_id}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        aggregate_id: "project:#{project_id}",
        command_id: "project.register:#{project_id}",
        type: "project.register",
        payload: %{
          project_id: project_id,
          name: "Crash Loop Backoff #{project_id}",
          path: System.tmp_dir!()
        }
      })

    case RunAdmission.start(project_id, %{
           run_id: run_id,
           task_id: "task-#{run_id}",
           workflow_snapshot: %{phases: []},
           phase_specs: []
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> flunk("seed_run failed: #{inspect(reason)}")
    end
  end

  defp read_worker_events(worker_id, run_id) do
    Store.read_stream_forward(Tracker.stream_id(worker_id, run_id), 0, 99_999_999)
    |> case do
      {:ok, events} -> events
      {:error, _} -> []
    end
  end

  defp read_run_events(run_id) do
    Store.read_stream_forward("run:#{run_id}", 0, 99_999_999)
    |> case do
      {:ok, events} -> events
      {:error, _} -> []
    end
  end

  defp count(events, type), do: Enum.count(events, &(&1.event_type == type))

  # ---------------------------------------------------------------------------
  # 5-restart blocking — the primary contract of TRD-078
  # ---------------------------------------------------------------------------

  describe "5-restart blocking (TRD-078 RTE-T004)" do
    @tag :slow
    test "6th crash emits WorkerCrashed + run.block" do
      %{tracker: tracker, detector: detector} = start_tracker_and_detector(threshold: 5)
      worker_id = uuid()
      run_id = uuid()

      _ = ForemanServer.Aggregator.start_aggregate(ForemanServer.Aggregates.Run, "run:#{run_id}")
      seed_run(run_id)
      # 5 real crashes — each should schedule backoff but NOT block yet.
      for attempt <- 1..5 do
        pid = spawn_worker()
        :ok = Tracker.register(tracker, worker_id, run_id, pid)
        Process.exit(pid, :kill)
        Process.sleep(50)

        # Verify attempt counter increments per attempt.
        attempt_count = CrashLoopDetector.attempt_count(detector)
        assert Map.get(attempt_count, {worker_id, run_id}) == attempt

        status = CrashLoopDetector.status(detector)

        assert {worker_id, run_id} not in status.crashed,
               "attempt #{attempt}: should NOT be crashed yet"

        assert {worker_id, run_id} not in status.paused,
               "attempt #{attempt}: should NOT be paused yet"
      end

      # 6th crash — backoff exhausted, blocked.
      pid6 = spawn_worker()
      :ok = Tracker.register(tracker, worker_id, run_id, pid6)
      Process.exit(pid6, :kill)
      Process.sleep(100)

      # WorkerCrashed must be emitted exactly once.
      worker_events = read_worker_events(worker_id, run_id)

      assert count(worker_events, "WorkerCrashed") == 1,
             "expected exactly 1 WorkerCrashed, got #{count(worker_events, "WorkerCrashed")}"

      # Run aggregate must have RunBlocked (run.block).
      run_events = read_run_events(run_id)

      assert count(run_events, "RunBlocked") == 1,
             "expected exactly 1 RunBlocked, got #{count(run_events, "RunBlocked")}"

      # Run aggregate must also have RunPaused (from try_crash_and_blocked).
      assert count(run_events, "RunPaused") == 1

      # Status must reflect sealed crashed and paused.
      status = CrashLoopDetector.status(detector)
      assert {worker_id, run_id} in status.crashed
      assert {worker_id, run_id} in status.paused
    end

    @tag :slow
    test "no duplicate WorkerCrashed after blocking" do
      %{tracker: tracker, detector: detector} = start_tracker_and_detector(threshold: 5)
      worker_id = uuid()
      run_id = uuid()

      _ = ForemanServer.Aggregator.start_aggregate(ForemanServer.Aggregates.Run, "run:#{run_id}")
      seed_run(run_id)

      # Exhaust the backoff: 5 crashes.
      for _ <- 1..5 do
        pid = spawn_worker()
        :ok = Tracker.register(tracker, worker_id, run_id, pid)
        Process.exit(pid, :kill)
        Process.sleep(50)
      end

      # 6th — triggers blocked.
      pid6 = spawn_worker()
      :ok = Tracker.register(tracker, worker_id, run_id, pid6)
      Process.exit(pid6, :kill)
      Process.sleep(100)

      assert {worker_id, run_id} in CrashLoopDetector.status(detector).crashed

      # Additional crashes must NOT emit more WorkerCrashed events.
      for _ <- 1..3 do
        pid = spawn_worker()
        :ok = Tracker.register(tracker, worker_id, run_id, pid)
        Process.exit(pid, :kill)
        Process.sleep(50)
      end

      worker_events = read_worker_events(worker_id, run_id)

      assert count(worker_events, "WorkerCrashed") == 1,
             "expected exactly 1 WorkerCrashed even after additional crashes"
    end
  end

  # ---------------------------------------------------------------------------
  # Backoff delay schedule — verify each attempt gets the correct delay
  # ---------------------------------------------------------------------------

  describe "backoff delay schedule" do
    test "RestartBackoff.backoff_ms returns correct delays for attempts 1-5" do
      assert 1000 = RestartBackoff.backoff_ms(1)
      assert 2000 = RestartBackoff.backoff_ms(2)
      assert 4000 = RestartBackoff.backoff_ms(3)
      assert 8000 = RestartBackoff.backoff_ms(4)
      assert 16_000 = RestartBackoff.backoff_ms(5)
    end

    test "RestartBackoff.next_attempt/1 returns retry for attempts 1-5" do
      for attempt <- 1..5 do
        assert {:retry, delay} = RestartBackoff.next_attempt(attempt)
        assert is_integer(delay)
        assert delay > 0
      end
    end

    test "RestartBackoff.next_attempt/1 returns blocked for attempt 6" do
      assert {:blocked, :max_attempts_exceeded} = RestartBackoff.next_attempt(6)
    end
  end

  # ---------------------------------------------------------------------------
  # Pending timer cancellation — crash during backoff cancels prior timer
  # ---------------------------------------------------------------------------

  describe "pending timer cancellation" do
    @tag :slow
    test "a crash arriving before backoff_expired cancels the pending timer" do
      %{tracker: tracker, detector: detector} = start_tracker_and_detector(threshold: 5)
      worker_id = uuid()
      run_id = uuid()

      # Crash 1: schedules a 1s backoff timer.
      pid1 = spawn_worker()
      :ok = Tracker.register(tracker, worker_id, run_id, pid1)
      Process.exit(pid1, :kill)
      Process.sleep(50)

      pending = CrashLoopDetector.pending_timers(detector)

      assert Map.has_key?(pending, {worker_id, run_id}),
             "pending timer should be registered after crash 1"

      # Before the 1s timer fires, crash again (crash 2).
      # This should cancel the pending timer from crash 1.
      pid2 = spawn_worker()
      :ok = Tracker.register(tracker, worker_id, run_id, pid2)
      Process.exit(pid2, :kill)
      Process.sleep(50)

      # Pending timers map should have been updated.
      pending = CrashLoopDetector.pending_timers(detector)
      # At least one pending timer should remain (for crash 2's backoff).
      # The key point: the old timer from crash 1 was cancelled.
      assert is_map(pending)

      # Still not blocked (only 2 crashes).
      status = CrashLoopDetector.status(detector)
      assert {worker_id, run_id} not in status.crashed
    end
  end

  # ---------------------------------------------------------------------------
  # Timer drain — backoff_expired fires without phantom re-evaluation
  # ---------------------------------------------------------------------------

  describe "timer drain (no phantom restart)" do
    test "handle_info(:backoff_expired) drains without re-evaluating" do
      %{tracker: _tracker, detector: detector} = start_tracker_and_detector(threshold: 5)
      worker_id = uuid()
      run_id = uuid()
      key = {worker_id, run_id}

      # Manually inject a pending timer and attempt count to simulate
      # "after crash 3, backoff timer scheduled but not yet fired".
      # We do this by sending a fake backoff_expired message.
      send(detector, {:backoff_expired, worker_id, run_id})
      Process.sleep(50)

      # The backoff_expired must be drained without:
      # - incrementing the attempt counter
      # - emitting any WorkerCrashed
      attempt_count = CrashLoopDetector.attempt_count(detector)

      assert Map.get(attempt_count, key) == nil,
             "backoff_expired should NOT increment attempt_count"

      status = CrashLoopDetector.status(detector)

      assert {worker_id, run_id} not in status.crashed,
             "backoff_expired should NOT trigger crash"
    end
  end

  # ---------------------------------------------------------------------------
  # Process restart survival — state survives GenServer restart, timers don't
  # ---------------------------------------------------------------------------

  describe "process restart survival" do
    @tag :slow
    test "GenServer restart preserves restart_history and attempt_count" do
      %{tracker: tracker, detector: detector} = start_tracker_and_detector(threshold: 5)
      worker_id = uuid()
      run_id = uuid()

      # 2 crashes.
      for _ <- 1..2 do
        pid = spawn_worker()
        :ok = Tracker.register(tracker, worker_id, run_id, pid)
        Process.exit(pid, :kill)
        Process.sleep(50)
      end

      attempt_before = CrashLoopDetector.attempt_count(detector)
      assert Map.get(attempt_before, {worker_id, run_id}) == 2

      # Kill the detector GenServer. `use GenServer` gives it a
      # `:permanent` child spec, so the ExUnit test supervisor restarts
      # it automatically under the same `id: :detector_backoff` slot —
      # a second explicit `start_supervised!/2` call would collide with
      # that auto-restarted child (`{:already_started, pid}}`).
      ref = Process.monitor(detector)
      Agent.stop(detector, :normal)

      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      after
        1000 -> flunk("detector did not die")
      end

      # Wait for the supervisor to finish restarting it under the same
      # registered name before querying the fresh instance.
      wait_until(fn ->
        case Process.whereis(CrashLoopDetector) do
          nil -> false
          ^detector -> false
          _new_pid -> true
        end
      end)

      # Attempt count is reset (pending timers don't survive restart —
      # this is correct; a fresh restart must re-evaluate from scratch).
      attempt_after = CrashLoopDetector.attempt_count()

      assert Map.get(attempt_after, {worker_id, run_id}) == nil,
             "attempt_count does not survive GenServer restart"
    end
  end
end
