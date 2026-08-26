defmodule ForemanServer.Workflow.BootReconciliationDispatchBackoffTest do
  @moduledoc """
  Regression test for the 5-restart backoff loop applied to BootReconciliation
  orphan slot-release / waiter-remove dispatches (RTE-T004 pattern, extended to
  BootReconciliation). The `run_slots:global` aggregate actor can be force-killed
  by test helpers (`RunSlotsReset.reset!/0`) or operator intervention; without
  backoff, the synchronous `GenServer.call` exit propagates and terminates
  BootReconciliation. With backoff, each orphan accumulates up to 5 consecutive
  failures; on the 6th attempt the orphan is logged as BLOCKED and a telemetry
  event fires for operator-facing observability.
  """

  use ExUnit.Case, async: false

  alias EventStore.EventData
  alias ForemanServer.{ProjectionStore, EventStore}
  alias ForemanServer.Idempotency.RestartBackoff
  alias ForemanServer.Workflow.BootReconciliation

  @run_slots_stream "run_slots:global"
  @attempts_table :boot_recon_dispatch_attempts

  setup_all do
    ensure_supervised(EventStore)
    ensure_supervised(ProjectionStore)
    ensure_supervised(ForemanServer.Aggregator)
    ensure_supervised(ForemanServer.CommandRouter)
    ensure_supervised(BootReconciliation)
    :ok
  end

  setup do
    if :ets.whereis(@attempts_table) != :undefined do
      :ets.delete_all_objects(@attempts_table)
    end

    :ok
  end

  describe "per-orphan dispatch attempt counter" do
    test "Bump returns 1, 2, 3, 4, 5 across successive updates" do
      run_id = unique_id("counter-bump")

      for n <- 1..5 do
        assert n = :ets.update_counter(@attempts_table, run_id, 1, {run_id, 0})
      end

      assert 5 == :ets.lookup(@attempts_table, run_id) |> List.first() |> elem(1)
    end

    test "Counter survives across reads" do
      run_id = unique_id("counter-survive")

      :ets.update_counter(@attempts_table, run_id, 1, {run_id, 0})
      :ets.update_counter(@attempts_table, run_id, 1, {run_id, 0})

      [{^run_id, n}] = :ets.lookup(@attempts_table, run_id)
      assert n == 2

      :ets.update_counter(@attempts_table, run_id, 1, {run_id, 0})
      [{^run_id, n}] = :ets.lookup(@attempts_table, run_id)
      assert n == 3
    end

    test "Deleting the entry clears the counter" do
      run_id = unique_id("counter-clear")

      :ets.update_counter(@attempts_table, run_id, 1, {run_id, 0})
      assert :ets.lookup(@attempts_table, run_id) != []

      :ets.delete(@attempts_table, run_id)
      assert :ets.lookup(@attempts_table, run_id) == []
    end

    test "Different run_ids maintain independent counters" do
      a = unique_id("counter-a")
      b = unique_id("counter-b")

      for _ <- 1..3, do: :ets.update_counter(@attempts_table, a, 1, {a, 0})
      for _ <- 1..5, do: :ets.update_counter(@attempts_table, b, 1, {b, 0})

      assert 3 == :ets.lookup(@attempts_table, a) |> List.first() |> elem(1)
      assert 5 == :ets.lookup(@attempts_table, b) |> List.first() |> elem(1)
    end
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
      append_run_slot_holder!(run_id, 0)

      boot_pid = Process.whereis(BootReconciliation)
      assert is_pid(boot_pid)

      ExUnit.CaptureLog.capture_log(fn ->
        for _ <- 1..5, do: kill_actor_and_scan()
      end)

      assert Process.alive?(boot_pid)
      assert Process.whereis(BootReconciliation) == boot_pid
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_id(prefix) do
    "#{prefix}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  defp ensure_supervised(child) do
    case Process.whereis(child) do
      nil -> start_supervised!(child)
      _pid -> :ok
    end
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

  defp seed_terminal_run!(run_id) do
    project_id = unique_id("project")
    task_id = unique_id("task")

    started_payload = %{
      run_id: run_id,
      task_id: task_id,
      project_id: project_id,
      workflow_snapshot: %{},
      sequence: 0
    }

    completed_payload = %{
      run_id: run_id,
      task_id: task_id,
      project_id: project_id,
      sequence: 1
    }

    :ok =
      EventStore.append_to_stream("run:#{run_id}", 0, [
        %EventData{event_type: "RunStarted", data: started_payload, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: "RunStarted", payload: started_payload}])

    :ok =
      EventStore.append_to_stream("run:#{run_id}", 1, [
        %EventData{event_type: "RunCompleted", data: completed_payload, metadata: %{}}
      ])

    :ok =
      ProjectionStore.apply_events([%{event_type: "RunCompleted", payload: completed_payload}])
  end

  defp append_run_slot_holder!(run_id, version) do
    ForemanServer.CommandGateway.dispatch_system(%{
      type: "run_slots.acquire",
      aggregate_id: @run_slots_stream,
      command_id: "seed-holder:#{run_id}:#{version}",
      payload: %{
        run_id: run_id,
        capacity: 1,
        acquired_at_ms: System.system_time(:millisecond)
      }
    })
  end
end
