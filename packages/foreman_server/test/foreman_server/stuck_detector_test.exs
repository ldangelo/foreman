defmodule StuckDetectorTestHelper do
  def reset_projection_store do
    :sys.replace_state(ForemanServer.ProjectionStore, fn _ -> %{projects: %{}, runs: %{}} end)
  end

  def seed_run_started(run_id, last_event_at_ms) do
    :ok =
      ForemanServer.ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: %{run_id: run_id, task_id: "task-stub"}}
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
    case ForemanServer.ProjectionStore.run_projection(run_id) do
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
