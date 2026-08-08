defmodule ForemanServer.RouterOptimisticConcurrencyTest do
  @moduledoc """
  Router+EventStore boundary test for AC-005-3 (Phase aggregate).

  Single end-to-end sequence that proves all clauses of AC-005-3 at the
  router+EventStore boundary:

    1. Start phase via CommandRouter → PhaseStarted at version 1, actor state
       is in_progress (not terminal).
    2. Two `phase.complete` events routed concurrently to the same stream via
       direct `:append` messages at expected_version=1 → exactly one wins, the
       other is rejected with `{:error, :wrong_expected_version}` from the
       EventStore's optimistic-concurrency check. The actor's local state is
       unchanged (it never saw either append).
    3. A fresh dispatch of `phase.complete` via the normal actor+router path
       converges to terminal state via the actor's bounded retry: first append
       conflicts (actor's local version is stale), reload rehydrates state
       with the loser's PhaseCompleted applied → re-decide returns
       `{:error, :phase_terminal}` without appending a duplicate.

  Stream invariants at end: exactly one PhaseStarted and exactly one
  PhaseCompleted. Actor's terminal? is true.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.{Aggregate, CommandRouter}
  alias ForemanServer.EventStore, as: Store

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp await_append_reply(ref) do
    receive do
      {:append_ok, ^ref, _count, _latency} -> :ok
      {:error, ^ref, reason, _latency} -> {:error, reason}
    after
      5_000 -> :timeout
    end
  end

  defp completed_event_data(run_id, phase_id) do
    %Elixir.EventStore.EventData{
      event_type: "PhaseCompleted",
      data: %{
        run_id: run_id,
        phase_id: phase_id,
        index: 1,
        artifact_path: "report.md",
        artifact_sha256: String.duplicate("a", 64),
        artifact_bytes: 1
      },
      metadata: %{}
    }
  end

  test "AC-005-3 phase.complete race at router+EventStore boundary, fresh dispatch converges to terminal" do
    run_id = "run-#{uuid()}"
    phase_id = "phase-#{uuid()}"
    stream = "phase:#{run_id}:#{phase_id}"

    # 1. Start phase via the normal actor+router path.
    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "phase.start",
        payload: %{
          phase_id: phase_id,
          run_id: run_id,
          index: 1,
          name: "build",
          attempt: 1,
          artifact_template: "report.md"
        },
        aggregate_id: stream
      })

    [{actor_pid, _}] = Registry.lookup(ForemanServer.AggregateRegistry, stream)

    state_initial = Aggregate.Actor.get_state(actor_pid)
    assert Map.get(state_initial, :status) == "in_progress"
    refute Map.get(state_initial, :terminal?)

    # 2. Two concurrent :append of PhaseCompleted at expected_version=1.
    ref_a = make_ref()
    ref_b = make_ref()

    task_a =
      Task.async(fn ->
        send(
          CommandRouter,
          {:append, stream, [completed_event_data(run_id, phase_id)], 1, ref_a, self()}
        )

        await_append_reply(ref_a)
      end)

    task_b =
      Task.async(fn ->
        send(
          CommandRouter,
          {:append, stream, [completed_event_data(run_id, phase_id)], 1, ref_b, self()}
        )

        await_append_reply(ref_b)
      end)

    outcomes =
      [Task.await(task_a, 5_000), Task.await(task_b, 5_000)]
      |> Enum.sort()

    assert outcomes == [:ok, {:error, :wrong_expected_version}],
           "exactly one concurrent append must win; the other is rejected at the EventStore layer"

    # Stream is now at version 2 with one PhaseCompleted. Actor's local state
    # is unchanged — still version 1, status=in_progress, not terminal.
    {:ok, events_after_race} = Store.read_stream_forward(stream, 0, 10)
    assert length(events_after_race) == 2
    assert Enum.map(events_after_race, & &1.event_type) == ["PhaseStarted", "PhaseCompleted"]

    state_after_race = Aggregate.Actor.get_state(actor_pid)

    assert Map.get(state_after_race, :status) == "in_progress",
           "actor must not have observed the racing :append messages"

    refute Map.get(state_after_race, :terminal?)

    # 3. Fresh dispatch via the normal actor+router path. Locally the actor
    # sees in_progress, so handle_command returns a PhaseCompleted event
    # spec and the first append fails with :wrong_expected_version. The
    # actor's bounded-retry path reloads state via Aggregate.load/2 (which
    # replays PhaseCompleted → status=completed, terminal?=true), re-decides
    # via handle_command, and returns {:error, :phase_terminal} without
    # appending a duplicate.
    fresh_result =
      CommandRouter.dispatch(%{
        type: "phase.complete",
        payload: %{phase_id: phase_id, run_id: run_id},
        aggregate_id: stream
      })

    assert {:error, :phase_terminal} = fresh_result,
           "fresh dispatch must reject on re-decision rather than appending a duplicate"

    state_final = Aggregate.Actor.get_state(actor_pid)
    assert Map.get(state_final, :status) == "completed"
    assert Map.get(state_final, :terminal?) == true

    # Presence must reflect the actor's actual post-reload version (2), not the
    # stale pre-conflict version (1). reload_after_conflict/1 calls
    # update_presence/3 so observability stays consistent with the stream —
    # without it, Presence would lie about the actor's true position.
    %{^stream => %{metas: [%{version: presence_version} | _]}} =
      ForemanServerWeb.Presence.list("debug:aggregates")

    assert presence_version == 2,
           "Presence must reflect the reloaded version after bounded-retry reload"

    # Stream invariants: exactly one PhaseStarted, exactly one PhaseCompleted.
    {:ok, events_final} = Store.read_stream_forward(stream, 0, 10)
    assert length(events_final) == 2
    assert Enum.map(events_final, & &1.event_type) == ["PhaseStarted", "PhaseCompleted"]

    completed_count =
      Enum.count(events_final, fn e -> e.event_type == "PhaseCompleted" end)

    assert completed_count == 1,
           "fresh dispatch must not append a duplicate PhaseCompleted"
  end
end
