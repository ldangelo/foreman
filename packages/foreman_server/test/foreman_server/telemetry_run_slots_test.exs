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

  # ---------------------------------------------------------------------
  # TRD-013: project_id, running and waiting counts, queue_wait_ms
  # ---------------------------------------------------------------------

  describe "per-project slot telemetry (AC-014-1)" do
    alias ForemanServer.Aggregates.RunSlots
    alias ForemanServer.Aggregates.RunSlots.{State, Waiter}

    defp state(holders, waiters, capacity \\ 2) do
      %State{
        capacity: capacity,
        holders: Map.new(holders, &{&1, %{acquired_at_ms: 1}}),
        waiters: Enum.map(waiters, fn {id, at} -> %Waiter{run_id: id, enqueued_at_ms: at} end)
      }
    end

    defp envelope(type, payload), do: %{type: type, payload: payload}

    test "acquired carries project, running and waiting counts" do
      assert :ok =
               Telemetry.run_slots_acquired("run-1", 2, 3, project_id: "proj-a", waiting: 4)

      assert_receive {:telemetry, [:foreman_server, :run_slots, :acquired],
                      %{holders: 2, capacity: 3, waiting: 4},
                      %{run_id: "run-1", project_id: "proj-a"}}
    end

    test "aggregate: grant, queue and release each report project and counts" do
      st = state(["h1"], [])

      assert {:ok, _} =
               RunSlots.handle_command(
                 st,
                 envelope("run_slots.acquire", %{run_id: "r2", capacity: 2, project_id: "proj-a"})
               )

      assert_receive {:telemetry, [:foreman_server, :run_slots, :acquired],
                      %{holders: 2, capacity: 2, waiting: 0},
                      %{run_id: "r2", project_id: "proj-a"}}

      full = state(["h1", "h2"], [{"w1", 10}])

      assert {:ok, _} =
               RunSlots.handle_command(
                 full,
                 envelope("run_slots.acquire", %{run_id: "w2", capacity: 2, project_id: "proj-a"})
               )

      assert_receive {:telemetry, [:foreman_server, :run_slots, :queued],
                      %{depth: 2, holders: 2, waiting: 2},
                      %{run_id: "w2", position: 2, project_id: "proj-a"}}

      only_holders = state(["h1", "h2"], [])

      assert {:ok, _} =
               RunSlots.handle_command(
                 only_holders,
                 envelope("run_slots.release", %{run_id: "h1", capacity: 2, project_id: "proj-a"})
               )

      assert_receive {:telemetry, [:foreman_server, :run_slots, :released],
                      %{holders: 1, waiting: 0}, %{run_id: "h1", project_id: "proj-a"}}
    end

    test "aggregate: promotion by release reports queue_wait_ms (AC-014-2)" do
      enq = System.system_time(:millisecond) - 5_000
      st = state(["h1", "h2"], [{"w1", enq}, {"w2", enq + 1}])

      assert {:ok, _} =
               RunSlots.handle_command(
                 st,
                 envelope("run_slots.release", %{run_id: "h1", capacity: 2, project_id: "proj-a"})
               )

      assert_receive {:telemetry, [:foreman_server, :run_slots, :transferred],
                      %{depth: 1, holders: 2, waiting: 1, queue_wait_ms: wait},
                      %{released_run_id: "h1", acquired_run_id: "w1", project_id: "proj-a"}}

      assert wait >= 5_000 and wait < 60_000
    end

    test "aggregate: run_slots.promote reports queue_wait_ms (AC-014-2)" do
      enq = System.system_time(:millisecond) - 3_000
      st = state(["h1"], [{"w1", enq}])

      assert {:ok, _} =
               RunSlots.handle_command(
                 st,
                 envelope("run_slots.promote", %{capacity: 2, project_id: "proj-a"})
               )

      assert_receive {:telemetry, [:foreman_server, :run_slots, :acquired],
                      %{holders: 2, waiting: 0, queue_wait_ms: wait},
                      %{run_id: "w1", project_id: "proj-a"}}

      assert wait >= 3_000 and wait < 60_000
    end

    test "a non-promoted grant carries no queue_wait_ms" do
      st = state([], [])

      assert {:ok, _} =
               RunSlots.handle_command(
                 st,
                 envelope("run_slots.acquire", %{run_id: "r1", capacity: 2, project_id: "proj-a"})
               )

      assert_receive {:telemetry, [:foreman_server, :run_slots, :acquired], measurements, _}
      refute Map.has_key?(measurements, :queue_wait_ms)
    end
  end
end
