defmodule ForemanServer.Workflow.BootReconciliationDispatchBackoffTest do
  @moduledoc """
  The 5-restart backoff applied to BootReconciliation's orphan slot-release /
  waiter-remove dispatches (RTE-T004 pattern), and its DURABLE budget (TRD-003).

  The `run_slots:global` aggregate actor can be force-killed by test helpers or
  operator intervention. Each orphan's consecutive failures are counted on the
  `run_slots:global` stream as `RunSlotRecoveryAttempted` (a holder or waiter whose
  run is absent or terminal has no aggregate of its own to carry a count), so the
  count survives a BootReconciliation restart. Five retries are permitted; the sixth
  failure records the entry `exhausted` and boot stops dispatching it.

  The failed dispatch is forced with `BootReconciliation.record_dispatch_failure/4`,
  which runs the real `handle_dispatch_failure/4` inside the reconciler process. It
  bypasses only the timing of killing the `run_slots:global` actor mid-dispatch; the
  count read, the backoff decision, the telemetry and the durable append are the
  production ones. Restarts, scans, releases and reads are real.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EventStore.EventData
  alias EventStore.RecordedEvent
  alias ForemanServer.{Aggregate, CommandGateway, Incarnation, ProjectionStore, Telemetry}
  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Idempotency.RestartBackoff
  alias ForemanServer.TestSupport.Eventually
  alias ForemanServer.Workflow.BootReconciliation

  @run_slots_stream "run_slots:global"
  @blocked_event [:foreman_server, :workflow, :boot_reconciliation, :dispatch_blocked]

  setup_all do
    ensure_supervised(ForemanServer.EventStore)
    ensure_supervised(ProjectionStore)
    ensure_supervised(ForemanServer.Aggregator)
    ensure_supervised(ForemanServer.CommandRouter)
    ensure_supervised(BootReconciliation)
    :ok
  end

  setup do
    cleanup_run_slots_stream()
    ForemanServer.TestSupport.ProjectionStoreReset.reset!(keep_subscribers: true)

    {handler_id, ref} =
      ForemanServer.TelemetryTest.Handler.attach_event_handlers(self(), Telemetry.all_events())

    on_exit(fn ->
      :telemetry.detach(handler_id)
      cleanup_run_slots_stream()
    end)

    {:ok, telemetry_ref: ref}
  end

  describe "RestartBackoff.next_attempt/1 contract (RTE-T004)" do
    test "Attempts 1..5 are {:retry, delay} with exponential growth" do
      assert {:retry, 1_000} = RestartBackoff.next_attempt(1)
      assert {:retry, 2_000} = RestartBackoff.next_attempt(2)
      assert {:retry, 4_000} = RestartBackoff.next_attempt(3)
      assert {:retry, 8_000} = RestartBackoff.next_attempt(4)
      assert {:retry, 16_000} = RestartBackoff.next_attempt(5)
    end

    test "Attempt 6+ is {:blocked, :max_attempts_exceeded}" do
      assert {:blocked, :max_attempts_exceeded} = RestartBackoff.next_attempt(6)
      assert {:blocked, :max_attempts_exceeded} = RestartBackoff.next_attempt(7)
      assert {:blocked, :max_attempts_exceeded} = RestartBackoff.next_attempt(100)
    end
  end

  describe "BootReconciliation survives repeated dispatch failures (integration)" do
    test "process stays alive across 5 kill+scan cycles" do
      run_id = unique_id("survival")
      seed_terminal_run!(run_id)
      append_run_slot_holder!(run_id)

      boot_pid = Process.whereis(BootReconciliation)
      assert is_pid(boot_pid)

      capture_log(fn ->
        for _ <- 1..5, do: kill_actor_and_scan()
      end)

      assert Process.alive?(boot_pid)
      assert Process.whereis(BootReconciliation) == boot_pid
    end
  end

  describe "the durable budget of a holder whose run is TERMINAL" do
    test "five failures are retried, the sixth is exhausted without blocking any run" do
      run_id = unique_id("terminal-holder")
      seed_terminal_run!(run_id)
      append_run_slot_holder!(run_id)
      run_stream_events = stream_event_types("run:#{run_id}")

      capture_log(fn -> charge(run_id, :slot_release, 6) end)

      assert [
               {"failed", 1},
               {"failed", 2},
               {"failed", 3},
               {"failed", 4},
               {"failed", 5},
               {"exhausted", 6}
             ] =
               recovery_outcomes(run_id)

      assert Enum.all?(recovery_events(run_id), &(field(&1, :kind) == "slot_release"))
      # The run is terminal: nothing is blocked, and its stream is untouched.
      assert stream_event_types("run:#{run_id}") == run_stream_events

      assert recovery_entry(run_id) |> Map.take([:attempt, :outcome]) == %{
               attempt: 6,
               outcome: "exhausted"
             }
    end

    test "the count survives a restart; the exhausted entry is skipped, logged, emitted and not counted",
         %{telemetry_ref: ref} do
      run_id = unique_id("terminal-exhausted")
      seed_terminal_run!(run_id)
      append_run_slot_holder!(run_id)
      capture_log(fn -> charge(run_id, :slot_release, 6) end)

      :telemetry.attach(
        "backoff-test-#{run_id}",
        @blocked_event,
        fn _event, _measurements, metadata, parent -> send(parent, {:blocked, metadata}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach("backoff-test-#{run_id}") end)

      log = capture_log(fn -> restart_boot_reconciliation!() end)

      assert log =~ "orphan slot entry #{run_id}"
      assert log =~ "exhausted"
      assert_receive {:blocked, %{run_id: ^run_id, skipped: true, attempts: 6}}, 2_000

      assert_receive {[:foreman_server, :run_slots, :reconciled], ^ref,
                      %{holders_dropped: 0, waiters_dropped: 0}, %{phase: :boot}},
                     2_000

      refute_received {[:foreman_server, :run_slots, :reconciled], ^ref, %{holders_dropped: 1}, _}

      # Still held, still six, nothing dispatched for it.
      assert :ok = BootReconciliation.scan_run_slot_orphans()
      _ = :sys.get_state(BootReconciliation)
      assert slot_event_types() |> Enum.filter(&(&1 == "RunSlotReleased")) == []

      assert recovery_entry(run_id) |> Map.take([:attempt, :outcome]) == %{
               attempt: 6,
               outcome: "exhausted"
             }

      Eventually.await(
        fn ->
          match?(
            [%{run_id: ^run_id, outcome: "exhausted", attempt: 6, kind: "slot_release"}],
            ProjectionStore.queue_status().orphan_recovery
          )
        end,
        message: "queue_status/0 to list the exhausted entry"
      )
    end

    test "an exhausted entry is dropped with its holder when another route releases it" do
      run_id = unique_id("terminal-released")
      seed_terminal_run!(run_id)
      append_run_slot_holder!(run_id)
      capture_log(fn -> charge(run_id, :slot_release, 6) end)
      capture_log(fn -> restart_boot_reconciliation!() end)

      # The Dispatcher's terminal release / the periodic backstop sweep.
      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 type: "run_slots.release",
                 aggregate_id: @run_slots_stream,
                 command_id: "backstop-release:#{run_id}",
                 payload: %{run_id: run_id, released_at_ms: System.system_time(:millisecond)}
               })

      assert recovery_entry(run_id) == nil

      Eventually.await(
        fn ->
          Enum.all?(ProjectionStore.queue_status().orphan_recovery, &(&1.run_id != run_id))
        end,
        message: "projection to drop the entry with its holder"
      )
    end

    test "four failures, a restart and one more failure make attempt 5 (still retried)" do
      run_id = unique_id("terminal-four")
      seed_terminal_run!(run_id)
      append_run_slot_holder!(run_id)

      capture_log(fn ->
        charge(run_id, :slot_release, 4)
        restart_with_stuck_actor!()
        charge(run_id, :slot_release, 1)
      end)

      assert List.last(recovery_outcomes(run_id)) == {"failed", 5}
    end
  end

  describe "the durable budget of a holder whose run is ABSENT" do
    test "five failures are retried and the sixth is exhausted, across a restart" do
      run_id = unique_id("absent-holder")
      append_run_slot_holder!(run_id)
      assert ProjectionStore.run(run_id) == nil

      capture_log(fn ->
        charge(run_id, :slot_release, 3)
        restart_with_stuck_actor!()
        charge(run_id, :slot_release, 3)
      end)

      assert [
               {"failed", 1},
               {"failed", 2},
               {"failed", 3},
               {"failed", 4},
               {"failed", 5},
               {"exhausted", 6}
             ] =
               recovery_outcomes(run_id)

      # No run stream exists or was created for the absent run.
      assert stream_event_types("run:#{run_id}") == []

      capture_log(fn -> restart_boot_reconciliation!() end)
      assert slot_event_types() |> Enum.filter(&(&1 == "RunSlotReleased")) == []
    end
  end

  describe "the durable budget of a waiter" do
    test "a waiter at 3 failures that fails again is at 4, and one budget is shared across kinds" do
      run_id = unique_id("terminal-waiter")
      seed_terminal_run!(run_id)
      other_holder = unique_id("other-holder")
      append_and_apply("run:#{other_holder}", 0, "RunStarted", started_payload(other_holder))
      append_run_slot_holder!(other_holder)
      append_run_slot_waiter!(run_id)

      capture_log(fn ->
        charge(run_id, :waiter_remove, 2)
        restart_with_stuck_actor!()
        charge(run_id, :waiter_remove, 1)
        # A failure of the other kind for the same run continues the same count.
        charge(run_id, :slot_release, 1)
      end)

      assert recovery_outcomes(run_id) == [
               {"failed", 1},
               {"failed", 2},
               {"failed", 3},
               {"failed", 4}
             ]

      assert %{kind: "slot_release", attempt: 4} = recovery_entry(run_id)
    end
  end

  describe "a successful dispatch" do
    test "after a recorded failure appends dispatched with attempt 0 and elapsed_since_boot_ms" do
      run_id = unique_id("success-after-failure")
      seed_terminal_run!(run_id)
      append_run_slot_holder!(run_id)
      capture_log(fn -> charge(run_id, :slot_release, 2) end)

      assert :ok = BootReconciliation.scan_run_slot_orphans()
      _ = :sys.get_state(BootReconciliation)

      types = slot_event_types()
      assert Enum.take(types, -2) == ["RunSlotReleased", "RunSlotRecoveryAttempted"]

      assert %RecordedEvent{data: data} = List.last(slot_events())
      assert field(data, :outcome) == "dispatched"
      assert field(data, :attempt) == 0
      assert field(data, :run_id) == run_id
      assert field(data, :kind) == "slot_release"
      elapsed = field(data, :elapsed_since_boot_ms)
      assert is_integer(elapsed) and elapsed >= 0
      assert elapsed <= System.monotonic_time(:millisecond) - Incarnation.started_at_ms()
      assert recovery_entry(run_id) == nil
    end

    test "on the first try appends nothing beyond the release" do
      run_id = unique_id("first-try")
      seed_terminal_run!(run_id)
      append_run_slot_holder!(run_id)

      assert :ok = BootReconciliation.scan_run_slot_orphans()
      _ = :sys.get_state(BootReconciliation)

      assert slot_event_types() == ["RunSlotAcquired", "RunSlotReleased"]
    end
  end

  describe "a dispatch that answers {:error, _}" do
    # The answer is forced through the module's dispatch hook: `CommandGateway.dispatch_system/1`
    # gives an error here only when an append fails, which a test cannot cause on demand. The
    # count read, the backoff decision and the durable append are the production ones.
    setup do
      Application.put_env(:foreman_server, :boot_reconciliation_slot_dispatch_hook, fn _command ->
        {:error, :append_refused}
      end)

      on_exit(fn ->
        Application.delete_env(:foreman_server, :boot_reconciliation_slot_dispatch_hook)
      end)
    end

    test "a holder's release is counted as a failure and the recorded count is not cleared" do
      run_id = unique_id("error-holder")
      seed_terminal_run!(run_id)
      append_run_slot_holder!(run_id)
      capture_log(fn -> charge(run_id, :slot_release, 1) end)

      capture_log(fn -> assert :ok = BootReconciliation.scan_run_slot_orphans() end)
      _ = :sys.get_state(BootReconciliation)

      assert recovery_outcomes(run_id) == [{"failed", 1}, {"failed", 2}]

      assert recovery_entry(run_id) |> Map.take([:attempt, :outcome]) == %{
               attempt: 2,
               outcome: "failed"
             }
    end

    test "a waiter's removal is counted as a failure and the recorded count is not cleared" do
      run_id = unique_id("error-waiter")
      seed_terminal_run!(run_id)
      append_run_slot_holder!(unique_id("other-holder"))
      append_run_slot_waiter!(run_id)
      capture_log(fn -> charge(run_id, :waiter_remove, 1) end)

      capture_log(fn -> assert :ok = BootReconciliation.scan_run_slot_orphans() end)
      _ = :sys.get_state(BootReconciliation)

      assert recovery_outcomes(run_id) == [{"failed", 1}, {"failed", 2}]
    end
  end

  describe "an append that exits" do
    test "is caught, logged and not counted; the reconciler stays up" do
      run_id = unique_id("append-exits")
      seed_terminal_run!(run_id)
      append_run_slot_holder!(run_id)
      boot_pid = Process.whereis(BootReconciliation)

      # A suspended actor never answers, so the append's call exits (a timeout).
      [{actor, _}] = Registry.lookup(ForemanServer.AggregateRegistry, @run_slots_stream)
      :ok = :sys.suspend(actor)

      log =
        capture_log(fn ->
          assert :ok =
                   BootReconciliation.record_dispatch_failure(
                     run_id,
                     :boot_orphan_holder,
                     :slot_release,
                     :killed
                   )
        end)

      # Kill (not resume) the actor: the timed-out command still sits in its mailbox
      # and must not be applied; the Aggregator restarts it from the stream.
      Process.exit(actor, :kill)

      assert log =~ "recovery record failed for #{run_id}"
      assert Process.whereis(BootReconciliation) == boot_pid
      assert Process.alive?(boot_pid)

      Eventually.await(
        fn -> match?({:ok, _}, safe_events()) end,
        message: "run_slots:global to be readable again"
      )

      assert recovery_events(run_id) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_id(prefix) do
    "#{prefix}-slot-orphan-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  defp ensure_supervised(child) do
    case Process.whereis(child) do
      nil -> start_supervised!(child)
      _pid -> :ok
    end
  end

  defp charge(run_id, kind, times) do
    for _ <- 1..times do
      assert :ok =
               BootReconciliation.record_dispatch_failure(
                 run_id,
                 :boot_orphan_holder,
                 kind,
                 :killed
               )
    end
  end

  defp restart_boot_reconciliation! do
    old = Process.whereis(BootReconciliation)
    ref = Process.monitor(old)
    GenServer.stop(old)
    assert_receive {:DOWN, ^ref, :process, ^old, _}, 2_000

    Eventually.await(
      fn ->
        new = Process.whereis(BootReconciliation)
        is_pid(new) and new != old
      end,
      message: "BootReconciliation to be restarted"
    )

    # Its init-time reconcile scan has finished once this call is answered.
    _ = :sys.get_state(BootReconciliation, 30_000)
    :ok
  end

  # Restart while the `run_slots:global` actor does not answer, so the restarted
  # reconciler's own scan fails its release/removal dispatch for real (the call
  # times out and is caught) and cannot clear the entry. The actor is then killed,
  # not resumed, so the timed-out commands in its mailbox are never applied; the
  # Aggregator restarts it from the stream.
  defp restart_with_stuck_actor! do
    [{actor, _}] = Registry.lookup(ForemanServer.AggregateRegistry, @run_slots_stream)
    :ok = :sys.suspend(actor)
    restart_boot_reconciliation!()
    ref = Process.monitor(actor)
    Process.exit(actor, :kill)
    assert_receive {:DOWN, ^ref, :process, ^actor, _}, 1_000

    Eventually.await(
      fn ->
        case Registry.lookup(ForemanServer.AggregateRegistry, @run_slots_stream) do
          [{pid, _}] -> pid != actor
          [] -> true
        end
      end,
      message: "registry to drop the killed actor"
    )
  end

  defp kill_actor_and_scan do
    case Registry.lookup(ForemanServer.AggregateRegistry, @run_slots_stream) do
      [{actor_pid, _}] ->
        ref = Process.monitor(actor_pid)
        Process.exit(actor_pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^actor_pid, _}, 1_000

      [] ->
        :ok
    end

    assert :ok = BootReconciliation.scan_run_slot_orphans()
  end

  defp safe_events do
    case Store.read_stream_forward(@run_slots_stream, 0, 200) do
      {:ok, events} -> {:ok, events}
      {:error, :stream_not_found} -> {:ok, []}
      other -> other
    end
  end

  defp slot_events do
    {:ok, events} = safe_events()
    events
  end

  defp slot_event_types, do: Enum.map(slot_events(), & &1.event_type)

  defp stream_event_types(stream) do
    case Store.read_stream_forward(stream, 0, 200) do
      {:ok, events} -> Enum.map(events, & &1.event_type)
      {:error, :stream_not_found} -> []
    end
  end

  defp recovery_events(run_id) do
    for %RecordedEvent{event_type: "RunSlotRecoveryAttempted", data: data} <- slot_events(),
        field(data, :run_id) == run_id,
        do: data
  end

  defp recovery_outcomes(run_id) do
    Enum.map(recovery_events(run_id), &{field(&1, :outcome), field(&1, :attempt)})
  end

  defp field(data, key), do: Aggregate.get(data, key)

  defp recovery_entry(run_id) do
    {state, _version} = Aggregate.load(RunSlots, @run_slots_stream)
    Map.get(state.recovery, run_id)
  end

  defp cleanup_run_slots_stream do
    # A scan cast still in flight appends to the stream; the reconciler is the barrier.
    _ = :sys.get_state(BootReconciliation)

    case Store.delete_stream(@run_slots_stream, :any_version, :hard) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, :stream_not_found} -> :ok
      {:error, :not_supported} -> :ok
    end

    case Registry.lookup(ForemanServer.AggregateRegistry, @run_slots_stream) do
      [{pid, _}] when is_pid(pid) ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end

        Eventually.await(
          fn ->
            ForemanServer.AggregateRegistry
            |> Registry.lookup(@run_slots_stream)
            |> Enum.all?(fn {registered, _value} -> registered != pid end)
          end,
          message: "registry to drop the killed #{@run_slots_stream} actor"
        )

      _ ->
        :ok
    end

    :ok
  end

  defp append_run_slot_holder!(run_id) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run_slots.acquire",
        aggregate_id: @run_slots_stream,
        command_id: "seed-holder:#{run_id}",
        payload: %{run_id: run_id, capacity: 1, acquired_at_ms: System.system_time(:millisecond)}
      })
  end

  defp append_run_slot_waiter!(run_id) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run_slots.acquire",
        aggregate_id: @run_slots_stream,
        command_id: "seed-waiter:#{run_id}",
        payload: %{run_id: run_id, capacity: 0, acquired_at_ms: System.system_time(:millisecond)}
      })
  end

  defp started_payload(run_id) do
    %{
      run_id: run_id,
      task_id: unique_id("task"),
      project_id: unique_id("project"),
      workflow_snapshot: %{},
      sequence: 0
    }
  end

  defp seed_terminal_run!(run_id) do
    append_and_apply("run:#{run_id}", 0, "RunStarted", started_payload(run_id))
    append_and_apply("run:#{run_id}", 1, "RunCompleted", %{run_id: run_id, sequence: 1})
  end

  defp append_and_apply(stream_uuid, expected_version, event_type, payload) do
    :ok =
      Store.append_to_stream(stream_uuid, expected_version, [
        %EventData{event_type: event_type, data: payload, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: event_type, payload: payload}])
  end
end
