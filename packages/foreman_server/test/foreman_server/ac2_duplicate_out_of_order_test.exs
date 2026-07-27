defmodule ForemanServer.AC2DuplicateOutOfOrderTest do
  use ExUnit.Case, async: false

  # ---------------------------------------------------------------------------
  # AC2: Duplicate / Out-of-Order Worker Completion
  #
  # Idempotency via command_id deduplication at the persistence boundary.
  # Every command carries a unique `command_id`. The `event_id` of each appended
  # event is derived deterministically from `{aggregate_id, command_id}`.
  # A second append with the same event_id hits the `events_pkey` unique
  # constraint and returns :duplicate_event — treated as an idempotent no-op.
  #
  # Sequence validation is a domain out-of-order guard in `handle_command`.
  #
  # AC2.1  run.complete sequence 1  → persists RunCompleted
  # AC2.2  same command_id again  → idempotent: still exactly 1 RunCompleted
  # AC2.3  run.complete sequence 3 → out-of-order: rejected before append
  # AC2.4  actor state correct throughout
  # ---------------------------------------------------------------------------

  alias ForemanServer.CommandRouter
  alias ForemanServer.EventStore, as: Store

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp dispatch(command), do: CommandRouter.dispatch(command, 5_000)

  defp run_completed_count(run_id) do
    case Store.read_stream_forward("run:#{run_id}", 0, 99_999_999) do
      {:ok, events} ->
        Enum.count(events, fn e -> e.event_type == "RunCompleted" end)

      {:error, _} ->
        0
    end
  end

  defp run_state(run_id) do
    agg_id = "run:#{run_id}"

    case Registry.lookup(ForemanServer.AggregateRegistry, agg_id) do
      [{pid, _}] -> :sys.get_state(pid).module_state
      [] -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # AC2.1 — sequence 1 succeeds, exactly 1 RunCompleted persisted
  # ---------------------------------------------------------------------------
  test "AC2.1: run.complete sequence 1 persists exactly one RunCompleted" do
    run_id = "run-#{uuid()}"
    cmd_id = "cmd-#{uuid()}"

    # Seed the run so handle_command has an existing aggregate
    {:ok, _} =
      dispatch(%{
        aggregate_id: "run:#{run_id}",
        type: "run.start",
        command_id: "seed-#{uuid()}",
        payload: %{run_id: run_id}
      })

    :timer.sleep(100)

    # AC2 step 1: run.complete with sequence 1
    {:ok, event_spec} =
      dispatch(%{
        aggregate_id: "run:#{run_id}",
        type: "run.complete",
        command_id: cmd_id,
        payload: %{run_id: run_id, sequence: 1, status: "completed"}
      })

    assert event_spec["event_type"] == "RunCompleted"
    assert run_completed_count(run_id) == 1
    assert run_state(run_id).status == "completed"
  end

  # ---------------------------------------------------------------------------
  # AC2.2 — duplicate command_id: idempotent, still exactly 1 RunCompleted
  # ---------------------------------------------------------------------------
  test "AC2.2: run.complete with duplicate command_id is idempotent" do
    run_id = "run-#{uuid()}"
    cmd_id = "dup-#{uuid()}"

    # Seed the run
    {:ok, _} =
      dispatch(%{
        aggregate_id: "run:#{run_id}",
        type: "run.start",
        command_id: "seed-#{uuid()}",
        payload: %{run_id: run_id}
      })

    :timer.sleep(100)

    # AC2 step 1: first run.complete with sequence 1
    {:ok, first} =
      dispatch(%{
        aggregate_id: "run:#{run_id}",
        type: "run.complete",
        command_id: cmd_id,
        payload: %{run_id: run_id, sequence: 1, status: "completed"}
      })

    assert first["event_type"] == "RunCompleted"
    assert run_completed_count(run_id) == 1

    # AC2 step 2: same command_id again — idempotent, no second event appended
    {:ok, second} =
      dispatch(%{
        aggregate_id: "run:#{run_id}",
        type: "run.complete",
        command_id: cmd_id,
        payload: %{run_id: run_id, sequence: 2, status: "completed"}
      })

    # Exactly 1 RunCompleted total — the duplicate was a no-op at the persistence layer
    assert run_completed_count(run_id) == 1
  end

  # ---------------------------------------------------------------------------
  # AC2.3 — out-of-order sequence: rejected before append
  # ---------------------------------------------------------------------------
  test "AC2.3: run.complete with out-of-order sequence returns :out_of_order" do
    run_id = "run-#{uuid()}"

    # Seed the run
    {:ok, _} =
      dispatch(%{
        aggregate_id: "run:#{run_id}",
        type: "run.start",
        command_id: "seed-#{uuid()}",
        payload: %{run_id: run_id}
      })

    :timer.sleep(100)

    count_before = run_completed_count(run_id)

    # AC2 step 4: send run.complete skipping sequence 2 (go straight to 3)
    # Expected: aggregate's sequence guard returns {:error, :out_of_order}
    {:error, :out_of_order} =
      dispatch(%{
        aggregate_id: "run:#{run_id}",
        type: "run.complete",
        command_id: "cmd-#{uuid()}",
        payload: %{run_id: run_id, sequence: 3, status: "completed"}
      })

    # No event was appended
    assert run_completed_count(run_id) == count_before
  end

  # ---------------------------------------------------------------------------
  # AC2.4 — full actor state unchanged after out-of-order rejection
  # ---------------------------------------------------------------------------
  test "AC2.4: aggregate state unchanged after steps 2-5 (duplicate + out-of-order)" do
    run_id = "run-#{uuid()}"
    agg_id = "run:#{run_id}"
    cmd_id = "dup2-#{uuid()}"

    # Seed the run
    {:ok, _} =
      dispatch(%{
        aggregate_id: agg_id,
        type: "run.start",
        command_id: "seed-#{uuid()}",
        payload: %{run_id: run_id}
      })

    :timer.sleep(100)

    state_after_start = run_state(run_id)
    assert state_after_start.status == "in_progress"
    assert state_after_start.terminal? == false

    # AC2 step 1: run.complete sequence 1 — succeeds
    {:ok, _} =
      dispatch(%{
        aggregate_id: agg_id,
        type: "run.complete",
        command_id: cmd_id,
        payload: %{run_id: run_id, sequence: 1, status: "completed"}
      })

    state_after_first = run_state(run_id)
    assert state_after_first.status == "completed"
    assert state_after_first.terminal? == true

    # AC2 step 2: same command_id again — idempotent, state unchanged from above
    {:ok, _} =
      dispatch(%{
        aggregate_id: agg_id,
        type: "run.complete",
        command_id: cmd_id,
        payload: %{run_id: run_id, sequence: 2, status: "completed"}
      })

    state_after_dup = run_state(run_id)
    assert state_after_dup.status == state_after_first.status
    assert state_after_dup.terminal? == state_after_first.terminal?

    # AC2 steps 4-5: out-of-order sequence 3 — rejected, state unchanged from dup
    {:error, :out_of_order} =
      dispatch(%{
        aggregate_id: agg_id,
        type: "run.complete",
        command_id: "cmd-oow-#{uuid()}",
        payload: %{run_id: run_id, sequence: 3, status: "completed"}
      })

    state_after_oow = run_state(run_id)
    assert state_after_oow.status == state_after_dup.status
    assert state_after_oow.terminal? == state_after_dup.terminal?
  end
end
