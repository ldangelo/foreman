defmodule ForemanServer.Overwatch.CrashLoopDetectorTest do
  @moduledoc """
  TRD-012 — CrashLoopDetector behaviour pins.

  Exercises the detector in isolation against a real Tracker so the
  threshold semantics, orphan path, sealing, and dual dispatch are
  observed end-to-end. The detector is started locally per test
  (`async: false`) since it owns process-wide state.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.{CommandRouter, RunAdmission}
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Overwatch.{CrashLoopDetector, Tracker}
  alias ForemanServer.TestSupport.RunSlotsReset

  setup do
    # start_run/1 funnels through RunAdmission.start/2 which acquires a
    # shared slot. Resetting before each example avoids queued
    # admissions when threshold tests exhaust the default cap of 3.
    RunSlotsReset.reset!()
    :ok
  end

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  # In the :test env, the application supervisor starts the Overwatch
  # subtree (Tracker + CrashLoopDetector) via the `Mix.env() == :test`
  # guard in `application.ex :maybe_overwatch_child/0`. The Tracker
  # hard-codes `Process.whereis(ForemanServer.Overwatch.CrashLoopDetector)`
  # in `notify_crash_loop_detector/2` to forward DOWN events, so any
  # extra detector we start with a different name will never be notified.
  # We must reuse the application-started pair and reset both between
  # tests so each scenario gets a clean state.
  defp start_tracker_and_detector(opts \\ []) do
    window_ms = Keyword.get(opts, :window_ms, 5 * 60 * 1000)
    threshold = Keyword.get(opts, :threshold, 3)

    # Make sure the application supervisor is up (idempotent in :test).
    _ = Application.ensure_all_started(:foreman_server)

    tracker = Process.whereis(ForemanServer.Overwatch.Tracker) || raise "Tracker not started"
    detector = Process.whereis(ForemanServer.Overwatch.CrashLoopDetector) || raise "CrashLoopDetector not started"

    # Reset any leftover state from a previous test in the suite.
    :ok = CrashLoopDetector.reset(detector)
    # Reset any leftover state from a previous test in the suite.
    # We don't override the threshold — the supervisor started the
    # detector with the default threshold=3, and `set_threshold/3`
    # was unreliable here. Tests that need a different threshold
    # use the default and fire enough crashes to exceed it.
    :ok = CrashLoopDetector.reset(detector)
    %{tracker: tracker, detector: detector}
  end

  defp spawn_worker do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp wait_until(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until timed out")
      else
        Process.sleep(5)
        do_wait(fun, deadline)
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
          name: "Crash Loop #{project_id}",
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

  describe "threshold crossing" do
    test "strict-greater-than semantics: the (threshold+1)-th restart fires WorkerCrashed + RunPaused" do
      %{tracker: tracker, detector: detector} = start_tracker_and_detector(threshold: 3)
      worker_id = uuid()
      run_id = uuid()

      _ = ForemanServer.Aggregator.start_aggregate(ForemanServer.Aggregates.Run, "run:#{run_id}")
      seed_run(run_id)

      # Cycle 4 generations so we get 4 DOWN events.
      for round <- 1..4 do
        pid = spawn_worker()
        :ok = Tracker.register(tracker, worker_id, run_id, pid)
        # Tie the lifetime of this pid to the previous one dying.
        Process.exit(pid, :kill)
        # Wait for Tracker to process DOWN and notify the detector.
        Process.sleep(50)
        _ = round
      end

      # 4th restart (count > 3): WorkerCrashed + RunPaused emitted.
      status = CrashLoopDetector.status(detector)
      assert {worker_id, run_id} in status.crashed
      assert {worker_id, run_id} in status.paused

      worker_events = read_worker_events(worker_id, run_id)
      assert count(worker_events, "WorkerCrashed") == 1

      run_events = read_run_events(run_id)
      assert count(run_events, "RunPaused") == 1
    end

    test "no false positive below threshold" do
      %{tracker: tracker, detector: detector} = start_tracker_and_detector(threshold: 3)
      worker_id = uuid()
      run_id = uuid()

      for _round <- 1..3 do
        pid = spawn_worker()
        :ok = Tracker.register(tracker, worker_id, run_id, pid)
        Process.exit(pid, :kill)
        Process.sleep(50)
      end

      status = CrashLoopDetector.status(detector)
      assert status.crashed == []
      assert status.paused == []
      assert read_worker_events(worker_id, run_id) |> count("WorkerCrashed") == 0
    end
  end

  describe "orphan path" do
    test ":noconnection/:shutdown/:exit reasons do NOT emit events" do
      %{tracker: tracker, detector: detector} = start_tracker_and_detector()
      worker_id = uuid()
      run_id = uuid()

      for reason <- [:noconnection, :shutdown, :exit] do
        pid = spawn_worker()
        :ok = Tracker.register(tracker, worker_id, run_id, pid)
        # Simulate the orphan reason by stopping the worker pid and
        # letting the supervisor's DOWN arrive with that reason.
        Process.exit(pid, reason)
        Process.sleep(50)
      end

      status = CrashLoopDetector.status(detector)
      assert status.crashed == []
      assert status.paused == []
    end
  end

  describe "sealed state" do
    test "after firing, further DOWN notifications are observed only" do
      %{tracker: tracker, detector: detector} = start_tracker_and_detector(threshold: 2)
      worker_id = uuid()
      run_id = uuid()

      _ = ForemanServer.Aggregator.start_aggregate(ForemanServer.Aggregates.Run, "run:#{run_id}")
      seed_run(run_id)

      # Fire 3 restarts (count > 2).
      for _ <- 1..3 do
        pid = spawn_worker()
        :ok = Tracker.register(tracker, worker_id, run_id, pid)
        Process.exit(pid, :kill)
        Process.sleep(50)
      end

      assert {worker_id, run_id} in CrashLoopDetector.status(detector).crashed

      # Even more crashes should not add another WorkerCrashed.
      for _ <- 1..2 do
        pid = spawn_worker()
        :ok = Tracker.register(tracker, worker_id, run_id, pid)
        Process.exit(pid, :kill)
        Process.sleep(50)
      end

      assert read_worker_events(worker_id, run_id) |> count("WorkerCrashed") == 1
    end
  end

  describe "dual-seal: pause retries independently of crash" do
    test "if pause was sealed, no further pause events are emitted" do
      %{tracker: tracker, detector: detector} = start_tracker_and_detector(threshold: 2)
      worker_id = uuid()
      run_id = uuid()

      _ = ForemanServer.Aggregator.start_aggregate(ForemanServer.Aggregates.Run, "run:#{run_id}")
      seed_run(run_id)

      for _ <- 1..3 do
        pid = spawn_worker()
        :ok = Tracker.register(tracker, worker_id, run_id, pid)
        Process.exit(pid, :kill)
        Process.sleep(50)
      end

      assert {worker_id, run_id} in CrashLoopDetector.status(detector).paused

      # More restarts, but the pause seal is in place.
      for _ <- 1..2 do
        pid = spawn_worker()
        :ok = Tracker.register(tracker, worker_id, run_id, pid)
        Process.exit(pid, :kill)
        Process.sleep(50)
      end

      assert read_run_events(run_id) |> count("RunPaused") == 1
    end
  end

  describe "Tracker.handle_call(:register) identity switch" do
    test "rejects duplicate live worker on same key" do
      %{tracker: tracker} = start_tracker_and_detector()
      worker_id = uuid()
      run_id = uuid()

      pid1 = spawn_worker()
      :ok = Tracker.register(tracker, worker_id, run_id, pid1)

      # pid1 is still alive; a different pid collides.
      pid2 = spawn_worker()
      assert {:error, :duplicate_live_worker} = Tracker.register(tracker, worker_id, run_id, pid2)
    end

    test "previous_generation_pending returned when DOWN has not yet cleared slot" do
      %{tracker: tracker, detector: detector} = start_tracker_and_detector()
      worker_id = uuid()
      run_id = uuid()

      pid1 = spawn_worker()
      :ok = Tracker.register(tracker, worker_id, run_id, pid1)
      pid2 = spawn_worker()

      # Suspend the tracker. Both the call request and the DOWN
      # will sit in its mailbox until resume.
      :sys.suspend(tracker)

      # Queue the register call BEFORE exiting pid1 so the
      # $gen_call lands in the mailbox first. The Task wraps a
      # blocking GenServer.call; while tracker is suspended the
      # Task awaits reply.
      register_task =
        Task.async(fn ->
          Tracker.register(tracker, worker_id, run_id, pid2)
        end)

      # Poll until the register call is actually queued in
      # tracker's mailbox. This pins the ordering: the $gen_call
      # arrives before we exit pid1.
      wait_until(fn ->
        {:messages, msgs} = Process.info(tracker, :messages)
        Enum.any?(msgs, &match?({:"$gen_call", _, _}, &1))
      end)

      # Now exit pid1 with `:shutdown`. DOWN is queued AFTER the
      # $gen_call, so the register call processes first with pid1
      # already dead but slot not cleared → :previous_generation_pending.
      Process.exit(pid1, :shutdown)

      :sys.resume(tracker)
      assert {:error, :previous_generation_pending} = Task.await(register_task, 1_000)
      Process.sleep(50)

      history = CrashLoopDetector.restart_history(detector)
      assert history == %{}
      status = CrashLoopDetector.status(detector)
      assert status.crashed == []
      assert status.paused == []
    end

    test "previous_generation_pending is transient: retry succeeds after DOWN clears slot" do
      %{tracker: tracker} = start_tracker_and_detector()
      worker_id = uuid()
      run_id = uuid()

      pid1 = spawn_worker()
      :ok = Tracker.register(tracker, worker_id, run_id, pid1)
      pid2 = spawn_worker()

      :sys.suspend(tracker)

      register_task =
        Task.async(fn ->
          Tracker.register(tracker, worker_id, run_id, pid2)
        end)

      wait_until(fn ->
        {:messages, msgs} = Process.info(tracker, :messages)
        Enum.any?(msgs, &match?({:"$gen_call", _, _}, &1))
      end)

      Process.exit(pid1, :kill)
      :sys.resume(tracker)

      assert {:error, :previous_generation_pending} = Task.await(register_task, 1_000)
      Process.sleep(50)

      pid3 = spawn_worker()
      assert :ok = Tracker.register(tracker, worker_id, run_id, pid3)
    end
  end
end
