defmodule ForemanServer.TelemetryRunSlotsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Telemetry

  @events [
    [:foreman_server, :run_slots, :acquired],
    [:foreman_server, :run_slots, :queued],
    [:foreman_server, :run_slots, :released],
    [:foreman_server, :run_slots, :transferred],
    [:foreman_server, :run_slots, :waiter_removed],
    [:foreman_server, :run_slots, :reconciled]
  ]

  setup do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok = :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  test "[:foreman_server, :run_slots, :acquired] has correct metadata" do
    assert :ok = Telemetry.run_slots_acquired("run-1", 2, 3)

    assert_receive {:telemetry, [:foreman_server, :run_slots, :acquired],
                    %{holders: 2, capacity: 3}, %{run_id: "run-1", source: :aggregate}}
  end

  test "[:foreman_server, :run_slots, :queued] has correct metadata" do
    assert :ok = Telemetry.run_slots_queued("run-2", 4, 4)

    assert_receive {:telemetry, [:foreman_server, :run_slots, :queued], %{depth: 4},
                    %{run_id: "run-2", position: 4}}
  end

  test "[:foreman_server, :run_slots, :released] has correct metadata" do
    assert :ok = Telemetry.run_slots_released("run-3", 1, :aggregate)

    assert_receive {:telemetry, [:foreman_server, :run_slots, :released], %{holders: 1},
                    %{run_id: "run-3", reason: :aggregate}}
  end

  test "[:foreman_server, :run_slots, :transferred] has correct metadata" do
    assert :ok = Telemetry.run_slots_transferred("run-4", "run-5", 2)

    assert_receive {:telemetry, [:foreman_server, :run_slots, :transferred], %{depth: 2},
                    %{released_run_id: "run-4", acquired_run_id: "run-5"}}
  end

  test "[:foreman_server, :run_slots, :waiter_removed] has correct metadata" do
    assert :ok = Telemetry.run_slots_waiter_removed("run-6", 0, :boot_orphan_waiter)

    assert_receive {:telemetry, [:foreman_server, :run_slots, :waiter_removed], %{depth: 0},
                    %{run_id: "run-6", reason: :boot_orphan_waiter}}
  end

  test "[:foreman_server, :run_slots, :reconciled] has correct metadata" do
    assert :ok = Telemetry.run_slots_reconciled(1, 2, :boot)

    assert_receive {:telemetry, [:foreman_server, :run_slots, :reconciled],
                    %{holders_dropped: 1, waiters_dropped: 2}, %{phase: :boot}}
  end
end
