defmodule StuckDetectorTestHelper do
  def reset_projection_store do
    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      %{state | projects: %{}, runs: %{}}
    end)
  end

  def seed_run_started(run_id, last_event_at_ms) do
    :ok =
      ForemanServer.ProjectionStore.apply_events([
        %{
          event_type: "RunStarted",
          payload: %{
            run_id: run_id,
            task_id: "task-stub",
            project_id: "project-stub",
            workflow_snapshot: %{phases: []}
          }
        }
      ])

    # Force the projection's last_event_at_ms to the requested value so tests
    # can pin the idle window precisely regardless of which clock the
    # projection store is using internally.
    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      run = Map.get(state.runs, run_id, %{})

      Map.put(
        state,
        :runs,
        Map.put(state.runs, run_id, %{
          run
          | last_event_at_ms: last_event_at_ms,
            status: "in_progress",
            terminal?: false
        })
      )
    end)
  end

  def last_event_at_ms(run_id) do
    case ForemanServer.ProjectionStore.run(run_id) do
      %{last_event_at_ms: last} -> last
      _ -> nil
    end
  end
end

defmodule ForemanServer.StuckDetectorTest do
  use ExUnit.Case, async: false

  alias ForemanServer.StuckDetector

  @event [:foreman, :run, :stuck]

  setup do
    StuckDetectorTestHelper.reset_projection_store()
    on_exit(fn -> StuckDetectorTestHelper.reset_projection_store() end)
    :ok
  end

  describe "scan/1" do
    test "flags stuck runs: telemetry fires, dispatch fires" do
      run_id = "run-stuck-1"
      last_event = 1_700_000_000_000
      StuckDetectorTestHelper.seed_run_started(run_id, last_event)

      test_pid = self()
      handler_id = "test-stuck-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        @event,
        fn name, m, mdata, _cfg -> send(test_pid, {:telemetry, name, m, mdata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      dispatch_fun = fn cmd, timeout ->
        send(test_pid, {:dispatched, cmd, timeout})
        {:ok, :stub}
      end

      now_ms = last_event + 5_000
      threshold_ms = 1_000

      results =
        StuckDetector.scan(
          threshold_ms: threshold_ms,
          now_ms_fun: fn -> now_ms end,
          dispatch_fun: dispatch_fun
        )

      assert_receive {:telemetry, [:foreman, :run, :stuck], %{idle_ms: 5_000},
                      %{run_id: ^run_id, threshold_ms: ^threshold_ms}}

      expected_aggregate_id = "run:#{run_id}"

      assert_receive {:dispatched,
                      %{aggregate_id: ^expected_aggregate_id, type: "run.flag_stuck"}, 5_000}

      assert [%{run_id: ^run_id, idle_ms: 5_000, dispatch: :ok}] = results
    end

    test "does not flag recent runs" do
      run_id = "run-fresh"
      last_event = 1_700_000_000_000
      StuckDetectorTestHelper.seed_run_started(run_id, last_event)

      test_pid = self()
      handler_id = "test-noop-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        @event,
        fn _name, _m, _md, _cfg -> send(test_pid, :should_not_fire) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      results =
        StuckDetector.scan(
          threshold_ms: 60_000,
          now_ms_fun: fn -> last_event + 5_000 end,
          dispatch_fun: fn _, _ -> flunk("dispatch should not be called") end
        )

      assert results == []
      refute_received :should_not_fire
      assert StuckDetectorTestHelper.last_event_at_ms(run_id) == last_event
    end

    test "emits telemetry BEFORE dispatching the command" do
      run_id = "run-ordering"
      last_event = 1_700_000_000_000
      StuckDetectorTestHelper.seed_run_started(run_id, last_event)

      test_pid = self()
      handler_id = "test-stuck-order-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        @event,
        fn _name, _m, _md, _cfg -> send(test_pid, :telemetry_fired) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      dispatch_fun = fn _cmd, _timeout ->
        # At the moment dispatch runs, telemetry must already have fired.
        assert_received :telemetry_fired
        {:ok, :stub}
      end

      _ =
        StuckDetector.scan(
          threshold_ms: 1_000,
          now_ms_fun: fn -> last_event + 5_000 end,
          dispatch_fun: dispatch_fun
        )
    end

    test "returns error status when dispatch returns an error" do
      run_id = "run-error"
      last_event = 1_700_000_000_000
      StuckDetectorTestHelper.seed_run_started(run_id, last_event)

      dispatch_fun = fn _cmd, _timeout -> {:error, :boom} end

      results =
        StuckDetector.scan(
          threshold_ms: 1_000,
          now_ms_fun: fn -> last_event + 5_000 end,
          dispatch_fun: dispatch_fun
        )

      assert [%{run_id: ^run_id, idle_ms: 5_000, dispatch: {:error, :boom}}] = results
    end

    # ---- 15-minute boundary (TRD-019 / S4) ----
    # Default threshold = 900_000 ms. These tests pin `now_ms_fun` and verify
    # the exact inclusive boundary against the default rather than an
    # overridden threshold. The existing tests above override `threshold_ms`
    # to 1_000; they prove the dispatch plumbing works but do not verify the
    # 15-minute boundary the S4 contract specifies.

    test "does not flag a run idle 899_999 ms (just below the 15-minute threshold)" do
      run_id = "run-boundary-just-below"
      last_event = 1_700_000_000_000
      StuckDetectorTestHelper.seed_run_started(run_id, last_event)

      test_pid = self()
      handler_id = "test-stuck-just-below-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        @event,
        fn name, m, mdata, _cfg -> send(test_pid, {:telemetry, name, m, mdata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      dispatch_fun = fn cmd, timeout ->
        send(test_pid, {:dispatched, cmd, timeout})
        {:ok, :stub}
      end

      results =
        StuckDetector.scan(
          now_ms_fun: fn -> last_event + 899_999 end,
          dispatch_fun: dispatch_fun
        )

      refute_receive {:telemetry, [:foreman, :run, :stuck], _, _}, 100
      refute_receive {:dispatched, _, _}, 100
      assert results == []
    end

    test "flags a run idle exactly 900_000 ms (the 15-minute boundary)" do
      run_id = "run-boundary-at"
      last_event = 1_700_000_000_000
      StuckDetectorTestHelper.seed_run_started(run_id, last_event)

      test_pid = self()
      handler_id = "test-stuck-at-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        @event,
        fn name, m, mdata, _cfg -> send(test_pid, {:telemetry, name, m, mdata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      dispatch_fun = fn cmd, timeout ->
        send(test_pid, {:dispatched, cmd, timeout})
        {:ok, :stub}
      end

      expected_aggregate_id = "run:#{run_id}"

      results =
        StuckDetector.scan(
          now_ms_fun: fn -> last_event + 900_000 end,
          dispatch_fun: dispatch_fun
        )

      assert_receive {:telemetry, [:foreman, :run, :stuck], %{idle_ms: 900_000},
                      %{run_id: ^run_id, threshold_ms: 900_000}}

      assert_receive {:dispatched,
                      %{aggregate_id: ^expected_aggregate_id, type: "run.flag_stuck"}, 5_000}

      assert [%{run_id: ^run_id, idle_ms: 900_000, dispatch: :ok}] = results
    end

    test "flags a run idle 900_001 ms (just above the 15-minute threshold)" do
      run_id = "run-boundary-just-above"
      last_event = 1_700_000_000_000
      StuckDetectorTestHelper.seed_run_started(run_id, last_event)

      test_pid = self()
      handler_id = "test-stuck-just-above-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        @event,
        fn name, m, mdata, _cfg -> send(test_pid, {:telemetry, name, m, mdata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      dispatch_fun = fn cmd, timeout ->
        send(test_pid, {:dispatched, cmd, timeout})
        {:ok, :stub}
      end

      expected_aggregate_id = "run:#{run_id}"

      results =
        StuckDetector.scan(
          now_ms_fun: fn -> last_event + 900_001 end,
          dispatch_fun: dispatch_fun
        )

      assert_receive {:telemetry, [:foreman, :run, :stuck], %{idle_ms: 900_001},
                      %{run_id: ^run_id, threshold_ms: 900_000}}

      assert_receive {:dispatched,
                      %{aggregate_id: ^expected_aggregate_id, type: "run.flag_stuck"}, 5_000}

      assert [%{run_id: ^run_id, idle_ms: 900_001, dispatch: :ok}] = results
    end

    test "scan/1 falls back to System.system_time(:millisecond) when no now_ms_fun is injected" do
      # The default clock must be a 0-arity function. The previous default
      # was `&System.system_time/1`, which crashed when invoked as
      # `now_ms_fun.()` — hitting the GenServer's `handle_info(:scan, ...)`
      # production path. Pin the contract here.
      run_id = "run-default-clock"
      last_event = 1_700_000_000_000
      StuckDetectorTestHelper.seed_run_started(run_id, last_event)

      results =
        StuckDetector.scan(
          threshold_ms: 1_000,
          dispatch_fun: fn _cmd, _timeout -> {:ok, :stub} end
        )

      assert is_list(results)
      assert [%{run_id: ^run_id}] = results
    end

    # ---- Liveness exemption (S5) ----
    # When an executor is registered under RunExecutorRegistry AND has
    # published a deadline that is still in the future, the stuck run must
    # NOT be flagged. The exemption expires as soon as the deadline passes,
    # even if the registered PID is still alive (wedged agent case).
    test "does not flag a run with a live executor whose deadline is in the future" do
      run_id = "run-live-within-deadline"
      last_event = 1_700_000_000_000
      StuckDetectorTestHelper.seed_run_started(run_id, last_event)

      # Registry.register/2 binds the key to the calling process. The
      # test process is registered here; when the test exits, the key
      # is auto-removed. We deliberately do NOT call unregister from
      # `on_exit` because that handler runs in a different process and
      # cannot unregister this test's own keys.
      Registry.register(ForemanServer.RunExecutorRegistry, run_id, %{})

      now_ms = last_event + 20 * 60 * 1000
      deadline_ms = now_ms + 30 * 60 * 1000
      ForemanServer.RunExecutorLiveness.record(run_id, self(), deadline_ms)
      on_exit(fn -> ForemanServer.RunExecutorLiveness.clear(run_id) end)

      test_pid = self()
      handler_id = "test-liveness-skip-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        @event,
        fn _, _, _, _ -> send(test_pid, :should_not_fire) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      results =
        StuckDetector.scan(
          now_ms_fun: fn -> now_ms end,
          dispatch_fun: fn _, _ -> flunk("dispatch should not be called") end
        )

      assert results == []
      refute_receive :should_not_fire, 100
    end

    test "flags a run with a live executor whose deadline has expired (wedged agent)" do
      run_id = "run-live-past-deadline"
      last_event = 1_700_000_000_000
      StuckDetectorTestHelper.seed_run_started(run_id, last_event)

      Registry.register(ForemanServer.RunExecutorRegistry, run_id, %{})

      # Recorded 30 minutes ago; deadline is 1 minute in the past.
      recorded_at_ms = last_event + 20 * 60 * 1000
      deadline_ms = recorded_at_ms + 1 * 60 * 1000
      now_ms = recorded_at_ms + 30 * 60 * 1000
      ForemanServer.RunExecutorLiveness.record(run_id, self(), deadline_ms)
      on_exit(fn -> ForemanServer.RunExecutorLiveness.clear(run_id) end)

      test_pid = self()
      handler_id = "test-liveness-wedged-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        @event,
        fn name, m, mdata, _cfg -> send(test_pid, {:telemetry, name, m, mdata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      results =
        StuckDetector.scan(
          threshold_ms: 1_000,
          now_ms_fun: fn -> now_ms end,
          dispatch_fun: fn _cmd, _timeout -> {:ok, :stub} end
        )

      assert_receive {:telemetry, [:foreman, :run, :stuck], _, %{run_id: ^run_id}}
      assert [%{run_id: ^run_id}] = results
    end

    test "ignores a stale liveness entry when no executor is registered" do
      # Simulates the brutal-kill scenario: the executor died without
      # clearing the ETS entry. The stuck run must still be flagged,
      # proving the PID guard in `live_within_deadline?/2` is load-bearing
      # and not just a stylistic extra.
      run_id = "run-stale-liveness"
      last_event = 1_700_000_000_000
      StuckDetectorTestHelper.seed_run_started(run_id, last_event)

      now_ms = last_event + 20 * 60 * 1000
      deadline_ms = now_ms + 30 * 60 * 1000
      ForemanServer.RunExecutorLiveness.record(run_id, self(), deadline_ms)
      on_exit(fn -> ForemanServer.RunExecutorLiveness.clear(run_id) end)

      # Deliberately do NOT register any executor under RunExecutorRegistry.

      results =
        StuckDetector.scan(
          threshold_ms: 1_000,
          now_ms_fun: fn -> now_ms end,
          dispatch_fun: fn _cmd, _timeout -> {:ok, :stub} end
        )

      assert [%{run_id: ^run_id}] = results
    end

    test "rejects a stale liveness entry recorded by a brutally-killed predecessor" do
      # Simulates the crash/restart race: P1 records a future deadline,
      # is brutally killed, the supervisor respawns P2 and P2 registers
      # under RunExecutorRegistry. The stale deadline must NOT exempt
      # the run — the stored owner PID won't match the registered one.
      # Without this guard a stale entry from a brutally-killed
      # predecessor would falsely mark a wedged-but-restarted run as
      # healthy.
      run_id = "run-restart-mismatch"
      last_event = 1_700_000_000_000
      StuckDetectorTestHelper.seed_run_started(run_id, last_event)

      on_exit(fn -> ForemanServer.RunExecutorLiveness.clear(run_id) end)

      # The respawned executor P2 must register BEFORE we record the
      # stale entry and run scan/1 — otherwise the test would
      # silently fall through the "no executor registered" path
      # (which the previous test already covers) and the regression
      # being guarded here would be unexercised. We handshake on a
      # dedicated message so scan/1 only runs once Registry.register/3
      # has returned `{:ok, _}`.
      test_pid = self()

      respawned =
        spawn(fn ->
          case Registry.register(ForemanServer.RunExecutorRegistry, run_id, %{}) do
            {:ok, _owner} -> send(test_pid, :registered)
            {:error, _} = err -> send(test_pid, err)
          end

          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> Process.exit(respawned, :kill) end)

      assert_receive :registered, 1_000
      # Sanity-check that pid_for/1 actually resolves to the
      # respawned executor — if it does not, the test would still
      # pass via the "no executor" path, defeating its purpose.
      assert ForemanServer.Workflow.RunExecutor.pid_for(run_id) == respawned

      now_ms = last_event + 20 * 60 * 1000

      # Simulate the brutally-killed predecessor P1: spawn a
      # process, let it die, then record under its now-dead PID.
      # The respawned P2 is the registered executor; the dead PID
      # is what left the stale entry behind.
      dead_owner = spawn(fn -> :ok end)

      # Wait until the spawned process has been scheduled and
      # exited. The Erlang VM does not guarantee a freshly-spawned
      # process has run its first instruction by the time `spawn/1`
      # returns, so we must yield and retry.
      drain_dead = fn pid ->
        Enum.reduce_while(1..200, nil, fn _, _ ->
          cond do
            not Process.alive?(pid) ->
              {:halt, :ok}

            true ->
              Process.sleep(5)
              {:cont, nil}
          end
        end)
      end

      assert drain_dead.(dead_owner) == :ok

      deadline_ms = now_ms + 30 * 60 * 1000
      :ok = ForemanServer.RunExecutorLiveness.record(run_id, dead_owner, deadline_ms)

      # The respawned P2 has NOT yet recorded its own entry, so
      # the only entry is the dead P1's stale future deadline.
      # The owner-PID mismatch must prevent this entry from
      # exempting the run.
      results =
        StuckDetector.scan(
          threshold_ms: 1_000,
          now_ms_fun: fn -> now_ms end,
          dispatch_fun: fn _cmd, _timeout -> {:ok, :stub} end
        )

      assert [%{run_id: ^run_id}] = results

      # Cleanup the respawned executor.
      send(respawned, :stop)
    end
  end

  describe "GenServer start_link" do
    test "starts with the configured threshold + interval" do
      name = :"StuckDetectorTest#{System.unique_integer([:positive])}"
      {:ok, pid} = StuckDetector.start_link(interval_ms: 5_000, threshold_ms: 1_000, name: name)
      state = :sys.get_state(pid)
      assert state.threshold_ms == 1_000
      assert state.interval_ms == 5_000
      GenServer.stop(pid)
    end
  end
end
