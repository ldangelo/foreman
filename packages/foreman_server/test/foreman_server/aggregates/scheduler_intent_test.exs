defmodule ForemanServer.Aggregates.SchedulerIntentTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.SchedulerIntent
  alias ForemanServer.Aggregates.SchedulerIntent.State
  alias ForemanServer.CommandGateway
  alias ForemanServer.Events.{ScheduledFireConfirmed, ScheduledFireRecorded}
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Recovery

  # UUID ids: the event store outlives a BEAM session, and a recycled id would
  # hit the actor's idempotency path instead of the aggregate under test.
  defp fresh_id, do: "sched:#{EventStore.UUID.uuid4()}:1"

  defp fire(intent_id) do
    %{
      intent_id: intent_id,
      schedule_id: "s-1",
      project_id: "p-1",
      slot: 1_700_000_000,
      task_id: "sched-s-1-1700000000"
    }
  end

  defp cmd(type, payload), do: %{type: type, payload: payload}

  defp state_after(events) do
    Enum.reduce(events, SchedulerIntent.initial_state(), fn {type, payload}, state ->
      SchedulerIntent.apply_event(state, %{event_type: type, payload: payload})
    end)
  end

  describe "record" do
    test "a second record under a different command id is rejected and appends nothing" do
      id = fresh_id()

      assert {:ok, %{"event_type" => "ScheduledFireRecorded"}} =
               Recovery.record_intent(id, fire(id))

      other = %{
        aggregate_id: "scheduler_intent:#{id}",
        command_id: "a-different-command-id",
        type: "scheduler_intent.record",
        payload: fire(id)
      }

      assert {:error, {:scheduler_intent_exists, ^id}} = CommandGateway.dispatch_system(other)

      assert [%{intent_id: ^id, status: "recorded", slot: 1_700_000_000, schedule_id: "s-1"}] =
               Enum.filter(ProjectionStore.list_scheduler_intents(), &(&1.intent_id == id))
    end

    test "an identical retry (same command id) is a router-level no-op, not an error" do
      id = fresh_id()
      assert {:ok, first} = Recovery.record_intent(id, fire(id))
      assert {:ok, ^first} = Recovery.record_intent(id, fire(id))
    end

    test "the event carries schedule, project and slot and drops unknown keys" do
      id = fresh_id()

      assert {:ok, spec} =
               SchedulerIntent.handle_command(
                 SchedulerIntent.initial_state(),
                 cmd("scheduler_intent.record", Map.put(fire(id), :bogus, "x"))
               )

      assert spec.event_type == "ScheduledFireRecorded"

      assert spec.payload == %{
               intent_id: id,
               schedule_id: "s-1",
               project_id: "p-1",
               slot: 1_700_000_000,
               task_id: "sched-s-1-1700000000",
               run_id: nil,
               scheduled_for: nil,
               scheduled_at: nil,
               payload: nil
             }
    end

    test "intent_id is required, on the command and on the struct" do
      assert {:error, {:missing_or_invalid, :intent_id}} =
               SchedulerIntent.handle_command(
                 SchedulerIntent.initial_state(),
                 cmd("scheduler_intent.record", %{schedule_id: "s"})
               )

      assert_raise ArgumentError, ~r/intent_id/, fn ->
        struct!(ScheduledFireRecorded, schedule_id: "s")
      end

      assert_raise ArgumentError, ~r/intent_id/, fn ->
        struct!(ScheduledFireConfirmed, confirmed_at: "now")
      end
    end
  end

  describe "lifecycle" do
    setup do
      id = fresh_id()

      {:ok, %{payload: recorded}} =
        SchedulerIntent.handle_command(
          SchedulerIntent.initial_state(),
          cmd("scheduler_intent.record", fire(id))
        )

      {:ok, id: id, recorded: state_after([{"ScheduledFireRecorded", recorded}])}
    end

    test "confirm and skip are accepted once, from recorded", %{id: id, recorded: recorded} do
      assert %State{status: "recorded"} = recorded

      assert {:ok, %{event_type: "ScheduledFireConfirmed"}} =
               SchedulerIntent.handle_command(
                 recorded,
                 cmd("scheduler_intent.confirm", %{intent_id: id})
               )

      assert {:ok, %{event_type: "ScheduledFireSkipped"}} =
               SchedulerIntent.handle_command(
                 recorded,
                 cmd("scheduler_intent.skip", %{intent_id: id, reason: "deleted"})
               )

      assert {:ok, %{event_type: "SchedulerIntentStale"}} =
               SchedulerIntent.handle_command(
                 recorded,
                 cmd("scheduler_intent.mark_stale", %{intent_id: id})
               )
    end

    test "every terminal status rejects confirm, skip and mark_stale with its own status", %{
      id: id,
      recorded: recorded
    } do
      for {event, status} <- [
            {"ScheduledFireConfirmed", "confirmed"},
            {"ScheduledFireSkipped", "skipped"},
            {"SchedulerIntentStale", "stale"}
          ] do
        terminal =
          SchedulerIntent.apply_event(recorded, %{event_type: event, payload: %{intent_id: id}})

        assert %State{status: ^status} = terminal

        for type <- ~w(scheduler_intent.confirm scheduler_intent.skip scheduler_intent.mark_stale) do
          assert {:error, {:scheduler_intent_terminal, ^status}} =
                   SchedulerIntent.handle_command(terminal, cmd(type, %{intent_id: id}))
        end

        assert {:error, {:scheduler_intent_exists, ^id}} =
                 SchedulerIntent.handle_command(
                   terminal,
                   cmd("scheduler_intent.record", fire(id))
                 )
      end
    end

    test "unknown events replay through the catch-all", %{recorded: recorded} do
      assert ^recorded =
               SchedulerIntent.apply_event(recorded, %{
                 event_type: "SomeFutureEvent",
                 payload: %{}
               })
    end
  end
end
