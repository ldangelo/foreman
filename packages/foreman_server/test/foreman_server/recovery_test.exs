defmodule ForemanServer.RecoveryTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Recovery
  alias ForemanServer.{Aggregate, CommandRouter, ProjectionStore}

  setup do
    :sys.replace_state(ProjectionStore, fn _ ->
      %{projects: %{}, runs: %{}, pr_associations: %{}, scheduler_intents: %{}}
    end)

    on_exit(fn ->
      :sys.replace_state(ProjectionStore, fn _ ->
        %{projects: %{}, runs: %{}, pr_associations: %{}, scheduler_intents: %{}}
      end)
    end)

    :ok
  end

  describe "do_detect/1" do
    test "returns {:ok, 0} when there are no runs" do
      assert {:ok, 0} = Recovery.do_detect([])
    end

    test "skips terminal runs" do
      run_id = fresh_run_id()
      start_run(run_id)

      update_run_status(run_id, "completed", terminal?: true)

      assert {:ok, 0} = Recovery.do_detect(stale_after_ms: 0)
    end

    test "emits a run.recovery_event for stale non-terminal runs" do
      run_id = fresh_run_id()
      start_run(run_id)

      assert {:ok, count} = Recovery.do_detect(stale_after_ms: 0)
      assert count >= 1
    end

    test "respects custom stale_after_ms threshold" do
      run_id = fresh_run_id()
      start_run(run_id)

      near_past = DateTime.add(DateTime.utc_now(), -1, :second)

      assert {:ok, 0} = Recovery.do_detect(now: near_past, stale_after_ms: 60_000)
    end
  end

  describe "detect_unconfirmed_intents/1" do
    test "returns {:ok, 0} when no intents are pending" do
      IO.puts("[detect-returns-0] counter=#{System.unique_integer([:positive])}")
      assert {:ok, 0} = Recovery.detect_unconfirmed_intents([])
    end
    test "emits a scheduler_intent.mark_stale for recorded intents" do
      intent_id = fresh_intent_id()
      IO.puts("[emits-mark-stale] intent_id=#{intent_id}")

      {:ok, record_result} =
        Recovery.record_intent(intent_id, %{
          intent_id: intent_id,
          run_id: "r-1",
          scheduled_at: DateTime.to_iso8601(DateTime.utc_now())
        })

      IO.inspect(record_result, label: "[emits-mark-stale] record_result")

      intents = ProjectionStore.list_scheduler_intents()
      IO.inspect(intents, label: "[emits-mark-stale] list_scheduler_intents after record")

      assert {:ok, count} = Recovery.detect_unconfirmed_intents([])
      IO.inspect(count, label: "[emits-mark-stale] detect count")
      assert count >= 1
    end

    test "does not re-flag an intent already confirmed" do
      intent_id = fresh_intent_id()
      IO.puts("[does-not-reflag] intent_id=#{intent_id}")

      {:ok, _} =
        Recovery.record_intent(intent_id, %{
          intent_id: intent_id,
          run_id: "r-1",
          scheduled_at: DateTime.to_iso8601(DateTime.utc_now())
        })

      {:ok, _} = Recovery.confirm_execution(intent_id)

      assert {:ok, 0} = Recovery.detect_unconfirmed_intents([])
    end
  end

  describe "record_intent/2" do
    test "dispatches a scheduler_intent.record command" do
      intent_id = fresh_intent_id()

      assert {:ok, spec} =
               Recovery.record_intent(intent_id, %{
                 intent_id: intent_id,
                 run_id: "r-1",
                 scheduled_at: DateTime.to_iso8601(DateTime.utc_now())
               })

      assert spec["stream_id"] == "scheduler_intent:#{intent_id}"
      assert spec["event_type"] == "ScheduledFireRecorded"
    end

    test "returns error for non-binary intent_id" do
      assert_raise FunctionClauseError, fn ->
        Recovery.record_intent(123, %{intent_id: "x"})
      end
    end
  end

  describe "confirm_execution/1" do
    test "dispatches a scheduler_intent.confirm command" do
      intent_id = fresh_intent_id()

      {:ok, _} =
        Recovery.record_intent(intent_id, %{
          intent_id: intent_id,
          run_id: "r-1",
          scheduled_at: DateTime.to_iso8601(DateTime.utc_now())
        })

      assert {:ok, spec} = Recovery.confirm_execution(intent_id)
      assert spec["stream_id"] == "scheduler_intent:#{intent_id}"
      assert spec["event_type"] == "ScheduledFireConfirmed"
    end
  end

  describe "skip_fire/2" do
    test "dispatches a scheduler_intent.skip command" do
      intent_id = fresh_intent_id()

      {:ok, _} =
        Recovery.record_intent(intent_id, %{
          intent_id: intent_id,
          run_id: "r-1",
          scheduled_at: DateTime.to_iso8601(DateTime.utc_now())
        })

      assert {:ok, spec} = Recovery.skip_fire(intent_id, "abandoned")
      assert spec["stream_id"] == "scheduler_intent:#{intent_id}"
      assert spec["event_type"] == "ScheduledFireSkipped"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_run(run_id) do
    {:ok, _} =
      CommandRouter.dispatch(%{
        aggregate_id: "run:#{run_id}",
        command_id: "run.start:#{run_id}",
        type: "run.start",
        payload: %{
          run_id: run_id,
          task_id: "task-#{run_id}",
          project_id: "proj-1"
        }
      })

    :ok
  end

  defp update_run_status(run_id, status, opts) do
    terminal = Keyword.get(opts, :terminal?, false)

    cond do
      terminal ->
        ProjectionStore.apply_events([
          %{event_type: "RunCompleted", payload: %{run_id: run_id, status: status}}
        ])

      true ->
        run = ProjectionStore.run_projection(run_id)
        updated = Map.merge(run, %{status: status, terminal?: terminal, run_id: run_id})

        ProjectionStore.apply_events([
          %{event_type: "RunUpdated", payload: updated}
        ])
    end
  end

  # Use UUIDs for intent_id so collisions with prior BEAM sessions' event-store
  # rows can't trigger the actor's duplicate-idempotency path. `System.unique_integer/1`
  # is monotonic per BEAM session, so a counter from a previous run can match a
  # counter generated in this run and cause a stale event to be returned.
  defp fresh_intent_id, do: "intent-#{EventStore.UUID.uuid4()}"

  # Use UUIDs for run_id so collisions with prior BEAM sessions' event-store
  # rows can't trigger the actor's duplicate-idempotency path. The actor's
  # `duplicate_in_stream?` fast path then returns `{:ok, existing_event_spec}`
  # without updating the projection, so `list_runs()` stays empty and recovery
  # never sees the run.
  defp fresh_run_id, do: "run-#{EventStore.UUID.uuid4()}"
end
