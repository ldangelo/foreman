defmodule ForemanServer.RecoveryTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Recovery
  alias ForemanServer.TestSupport.{ProjectionStoreReset, RunSlotsReset}
  alias ForemanServer.ProjectionStore

  # `scan_now/0` pins the scan this far past the seeded run; the staleness
  # threshold is half of it. See `scan_now/0` for why neither may be 0.
  @scan_ahead_ms 60_000
  @stale_after_ms 30_000

  setup do
    RunSlotsReset.reset!()
    ProjectionStoreReset.reset!()

    on_exit(fn ->
      ProjectionStoreReset.reset!()
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

      assert {:ok, 0} = Recovery.do_detect(now: scan_now(), stale_after_ms: @stale_after_ms)
    end

    test "emits a run.recovery_event for stale non-terminal runs" do
      run_id = fresh_run_id()
      start_run(run_id)

      assert {:ok, count} = Recovery.do_detect(now: scan_now(), stale_after_ms: @stale_after_ms)
      assert count >= 1
    end

    test "respects custom stale_after_ms threshold" do
      run_id = fresh_run_id()
      start_run(run_id)

      near_past = DateTime.add(DateTime.utc_now(), -1, :second)

      assert {:ok, 0} = Recovery.do_detect(now: near_past, stale_after_ms: 60_000)
    end
  end

  describe "interrupted_intents/2" do
    # Seeds through the projection with an explicit event time so the age filter
    # is exercised against real recorded/confirmed/stale intents.
    defp seed_intent(id, status, at_ms) do
      base = %{intent_id: id, schedule_id: "s", project_id: "p", slot: 1}

      events =
        [%{event_type: "ScheduledFireRecorded", payload: base}] ++
          case status do
            "recorded" -> []
            "confirmed" -> [%{event_type: "ScheduledFireConfirmed", payload: %{intent_id: id}}]
            "skipped" -> [%{event_type: "ScheduledFireSkipped", payload: %{intent_id: id}}]
            "stale" -> [%{event_type: "SchedulerIntentStale", payload: %{intent_id: id}}]
          end

      # The projection stamps `recorded_at` from this per-process clock hook.
      Process.put(:projection_store_now_ms, fn -> at_ms end)
      :ok = ProjectionStore.apply_events(events)
      Process.delete(:projection_store_now_ms)
      :ok
    end

    test "returns only recorded intents older than the grace, never terminal ones" do
      now = 10_000_000
      grace = 300_000

      seed_intent("old-recorded", "recorded", now - 600_000)
      seed_intent("fresh-recorded", "recorded", now - 1_000)
      seed_intent("old-confirmed", "confirmed", now - 600_000)
      seed_intent("old-skipped", "skipped", now - 600_000)
      seed_intent("old-stale", "stale", now - 600_000)

      assert ["old-recorded"] ==
               Enum.map(Recovery.interrupted_intents(now, grace), & &1.intent_id)
    end

    test "the grace boundary is exclusive and the function is pure over its arguments" do
      seed_intent("edge", "recorded", 1_000)

      assert [] = Recovery.interrupted_intents(1_000 + 300_000, 300_000)
      assert [%{intent_id: "edge"}] = Recovery.interrupted_intents(1_000 + 300_001, 300_000)
      # Same inputs, same answer, and nothing was written.
      assert Recovery.interrupted_intents(1_000 + 300_001, 300_000) ==
               Recovery.interrupted_intents(1_000 + 300_001, 300_000)

      assert %{status: "recorded"} =
               Enum.find(ProjectionStore.list_scheduler_intents(), &(&1.intent_id == "edge"))
    end
  end

  describe "mark_interrupted/1" do
    test "appends exactly one SchedulerIntentStale however often it is called" do
      intent_id = fresh_intent_id()

      {:ok, _} =
        Recovery.record_intent(intent_id, %{run_id: "r-1", scheduled_at: "2026-01-01T00:00:00Z"})

      [intent] =
        Enum.filter(ProjectionStore.list_scheduler_intents(), &(&1.intent_id == intent_id))

      assert {:ok, first} = Recovery.mark_interrupted(intent)
      assert {:ok, replay} = Recovery.mark_interrupted(intent)
      assert replay == ForemanServer.Aggregate.Actor.mark_replayed(first)

      {:ok, events} =
        ForemanServer.EventStore.read_stream_forward("scheduler_intent:" <> intent_id, 0, 99)

      assert Enum.map(events, & &1.event_type) == [
               "ScheduledFireRecorded",
               "SchedulerIntentStale"
             ]

      assert %{status: "stale"} =
               Enum.find(ProjectionStore.list_scheduler_intents(), &(&1.intent_id == intent_id))
    end

    test "a dispatch failure is returned as an error tuple, not folded into success" do
      # No such intent stream state: confirm it first so mark_stale is terminal.
      intent_id = fresh_intent_id()
      {:ok, _} = Recovery.record_intent(intent_id, %{run_id: "r-1"})
      {:ok, _} = Recovery.confirm_execution(intent_id)

      assert {:error, {:scheduler_intent_terminal, "confirmed"}} =
               Recovery.mark_interrupted(%{intent_id: intent_id})
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
        apply(Recovery, :record_intent, [123, %{intent_id: "x"}])
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

  # `Recovery.do_detect/1` measures staleness as `now - last_event_at_ms`, but the
  # two sides come from different clocks: `now` defaults to `DateTime.utc_now/0`
  # (the OS clock) while `ProjectionStore` stamps `last_event_at_ms` from
  # `System.system_time/1` (the Erlang clock). They only agree to within the read
  # gap between the two calls, and not even that while the OS clock is being
  # slewed (macOS `timed` applies an `adjtime` of tens of ms about every 22
  # minutes): the Erlang clock then briefly leads by ~0.1 ms, so a run seeded
  # "just now" reads as newer than `now`. With `stale_after_ms: 0` and the default
  # `now`, `diff_ms >= 0` went false, `do_detect` returned `{:ok, 0}` and
  # `assert count >= 1` failed for a few seconds at a time, on any seed (and the
  # terminal-run test passed vacuously). Pin the scan time a full `@scan_ahead_ms`
  # after the seed so staleness no longer depends on how two clocks round against
  # each other.
  defp scan_now, do: DateTime.add(DateTime.utc_now(), @scan_ahead_ms, :millisecond)

  # `RunAdmission.start/2` routes through the shared, capacity-limited
  # `run_slots:global` singleton (default capacity 3, contended by every
  # concurrently-running test file — see `skill://foreman-test-isolation`).
  # A concurrent test can exhaust that capacity in the narrow window
  # between this test's own `RunSlotsReset.reset!()` (in `setup`) and this
  # call, making admission return `{:ok, :queued}`/`{:ok, :slot_queued}`
  # with NO run projection ever created — `do_detect` then sees 0 runs
  # and `assert count >= 1` fails, nondeterministically, under full-suite
  # load only. This test exists to verify `Recovery.do_detect`'s own
  # filtering logic, not the run-admission slot gate, so it seeds the run
  # projection directly via `ProjectionStore.apply_events/1` (the same
  # pattern `boot_reconciliation_dispatch_backoff_test.exs` uses),
  # bypassing `RunAdmission`/`run_slots` entirely.
  defp start_run(run_id) do
    project_id = "project-#{run_id}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunStarted",
          payload: %{
            run_id: run_id,
            task_id: "task-#{run_id}",
            project_id: project_id,
            workflow_snapshot: %{},
            sequence: 0
          }
        }
      ])

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
        run = ProjectionStore.run(run_id)
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
