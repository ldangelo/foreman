defmodule ForemanServer.Aggregates.ScheduleTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Schedule
  alias ForemanServer.Aggregates.Schedule.State
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @at "2026-01-01T00:00:00Z"

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: "p1", path: "/tmp/p1"}}
      ])
  end

  defp create_payload(overrides \\ %{}) do
    Map.merge(
      %{
        project_id: "p1",
        schedule_id: "s1",
        name: "Daily triage",
        spec: %{"every" => "1h"},
        prompt: "triage the inbox",
        workflow: "implement",
        at: @at
      },
      overrides
    )
  end

  defp cmd(type, payload), do: %{type: type, payload: payload}

  defp ids(extra \\ %{}), do: Map.merge(%{project_id: "p1", schedule_id: "s1", at: @at}, extra)

  # Fold the emitted spec back through apply_event exactly as the actor does.
  defp fold(state, %{event_type: type, payload: payload}),
    do: Schedule.apply_event(state, %{event_type: type, payload: payload})

  defp created_state(overrides \\ %{}) do
    {:ok, spec} =
      Schedule.handle_command(
        Schedule.initial_state(),
        cmd("schedule.create", create_payload(overrides))
      )

    fold(Schedule.initial_state(), spec)
  end

  describe "schedule.create" do
    test "emits ScheduleCreated with a normalised spec anchored at `at`" do
      assert {:ok, spec} =
               Schedule.handle_command(
                 Schedule.initial_state(),
                 cmd("schedule.create", create_payload())
               )

      assert spec.stream_id == "schedule:p1:s1"
      assert spec.event_type == "ScheduleCreated"

      assert %{
               name: "Daily triage",
               spec: %{"every" => "1h", "timezone" => "UTC", "anchor" => @at},
               prompt: "triage the inbox",
               workflow: "implement",
               auto_approve: true,
               overlap: "skip",
               misfire_grace_seconds: 600,
               created_at: @at
             } = spec.payload
    end

    test "creating twice is already_exists" do
      assert {:error, {:already_exists, :schedule, "s1"}} =
               Schedule.handle_command(created_state(), cmd("schedule.create", create_payload()))
    end

    test "project must exist and not be archived" do
      assert {:error, {:project_not_found, "nope"}} =
               Schedule.handle_command(
                 Schedule.initial_state(),
                 cmd("schedule.create", create_payload(%{project_id: "nope"}))
               )

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "ProjectArchived", payload: %{project_id: "p1"}}
        ])

      assert {:error, {:project_archived, "p1"}} =
               Schedule.handle_command(
                 Schedule.initial_state(),
                 cmd("schedule.create", create_payload())
               )
    end

    test "spec errors pass through typed" do
      assert {:error, {:invalid_schedule_spec, :every, :below_minimum}} =
               Schedule.handle_command(
                 Schedule.initial_state(),
                 cmd("schedule.create", create_payload(%{spec: %{"every" => "1m"}}))
               )
    end

    test "prompt, name, workflow, overlap and grace validation have distinct errors" do
      run = fn overrides ->
        Schedule.handle_command(
          Schedule.initial_state(),
          cmd("schedule.create", create_payload(overrides))
        )
      end

      assert {:error, {:missing_or_invalid, :prompt}} = run.(%{prompt: "  "})
      assert {:error, {:prompt_too_long, 16_001}} = run.(%{prompt: String.duplicate("x", 16_001)})
      assert {:ok, _} = run.(%{prompt: String.duplicate("x", 16_000)})
      assert {:error, {:missing_or_invalid, :name}} = run.(%{name: ""})

      assert {:error, {:unknown_workflow, "no-such-workflow"}} =
               run.(%{workflow: "no-such-workflow"})

      assert {:error, {:unknown_workflow, "../etc/passwd"}} = run.(%{workflow: "../etc/passwd"})
      assert {:error, {:invalid_overlap, "queue"}} = run.(%{overlap: "queue"})
      assert {:error, {:invalid_misfire_grace_seconds, -1}} = run.(%{misfire_grace_seconds: -1})
      assert {:error, {:missing_or_invalid, :at}} = run.(%{at: nil})
    end

    test "per-project active schedule cap" do
      original = Application.get_env(:foreman_server, :schedule, [])
      on_exit(fn -> Application.put_env(:foreman_server, :schedule, original) end)
      Application.put_env(:foreman_server, :schedule, Keyword.put(original, :max_per_project, 2))

      for id <- ~w(a b) do
        :ok =
          ProjectionStore.apply_events([
            %{
              event_type: "ScheduleCreated",
              payload: %{
                schedule_id: id,
                project_id: "p1",
                name: id,
                spec: %{"every" => "1h"},
                prompt: "x",
                workflow: "implement",
                created_at: @at
              }
            }
          ])
      end

      assert {:error, {:schedule_limit_reached, 2}} =
               Schedule.handle_command(
                 Schedule.initial_state(),
                 cmd("schedule.create", create_payload(%{schedule_id: "c"}))
               )

      # A deleted schedule frees a slot.
      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "ScheduleDeleted",
            payload: %{schedule_id: "a", project_id: "p1", at: @at}
          }
        ])

      assert {:ok, _} =
               Schedule.handle_command(
                 Schedule.initial_state(),
                 cmd("schedule.create", create_payload(%{schedule_id: "c"}))
               )
    end
  end

  describe "pause / resume / delete / update" do
    test "unknown schedule" do
      for type <-
            ~w(schedule.pause schedule.resume schedule.delete schedule.update schedule.mark_fired schedule.skip_fire) do
        assert {:error, {:schedule_not_found, "s1"}} =
                 Schedule.handle_command(Schedule.initial_state(), cmd(type, ids(%{slot: 1})))
      end
    end

    test "pause then pause again, resume when active" do
      active = created_state()

      assert {:error, {:schedule_not_paused, "s1"}} =
               Schedule.handle_command(active, cmd("schedule.resume", ids()))

      {:ok, paused_spec} = Schedule.handle_command(active, cmd("schedule.pause", ids()))
      paused = fold(active, paused_spec)
      assert %State{status: :paused} = paused

      assert {:error, {:schedule_already_paused, "s1"}} =
               Schedule.handle_command(paused, cmd("schedule.pause", ids()))

      {:ok, resumed_spec} =
        Schedule.handle_command(
          paused,
          cmd("schedule.resume", ids(%{at: "2026-02-01T00:00:00Z"}))
        )

      resumed = fold(paused, resumed_spec)
      assert %State{status: :active, active_since: since} = resumed
      assert since == DateTime.to_unix(~U[2026-02-01 00:00:00Z])
    end

    test "a deleted schedule rejects every mutation, including fires" do
      active = created_state()
      {:ok, deleted_spec} = Schedule.handle_command(active, cmd("schedule.delete", ids()))
      deleted = fold(active, deleted_spec)

      for type <-
            ~w(schedule.update schedule.pause schedule.resume schedule.delete schedule.mark_fired schedule.skip_fire) do
        assert {:error, {:schedule_deleted, "s1"}} =
                 Schedule.handle_command(deleted, cmd(type, ids(%{slot: 5})))
      end
    end

    test "update re-parses the spec, whitelists fields and rejects empty changes" do
      active = created_state()

      assert {:ok, %{event_type: "ScheduleUpdated", payload: %{changes: changes}}} =
               Schedule.handle_command(
                 active,
                 cmd(
                   "schedule.update",
                   ids(%{name: "Renamed", spec: %{"cron" => "0 9 * * 1-5"}, bogus: 1})
                 )
               )

      assert changes == %{
               "name" => "Renamed",
               "spec" => %{"cron" => "0 9 * * 1-5", "timezone" => "UTC"}
             }

      assert {:error, {:invalid_schedule_spec, :every, :below_minimum}} =
               Schedule.handle_command(
                 active,
                 cmd("schedule.update", ids(%{spec: %{"every" => "1m"}}))
               )

      assert {:error, {:missing_or_invalid, :changes, %{}}} =
               Schedule.handle_command(active, cmd("schedule.update", ids(%{bogus: 1})))
    end
  end

  describe "mark_fired / skip_fire" do
    test "advance last_slot; the same or an older slot is already processed" do
      active = created_state()

      {:ok, fired} =
        Schedule.handle_command(
          active,
          cmd(
            "schedule.mark_fired",
            ids(%{slot: 100, task_id: "t1", intent_id: "i1", collapsed_count: 2})
          )
        )

      assert fired.payload.fired_at == @at
      state = fold(active, fired)
      assert %State{last_slot: 100, last_task_id: "t1", last_outcome: :fired} = state

      for slot <- [100, 99] do
        assert {:error, {:slot_already_processed, ^slot}} =
                 Schedule.handle_command(
                   state,
                   cmd("schedule.skip_fire", ids(%{slot: slot, reason: "overlap"}))
                 )

        assert {:error, {:slot_already_processed, ^slot}} =
                 Schedule.handle_command(
                   state,
                   cmd("schedule.mark_fired", ids(%{slot: slot, task_id: "t", intent_id: "i"}))
                 )
      end

      assert {:ok,
              %{
                event_type: "ScheduleFireSkipped",
                payload: %{slot: 101, reason: "missed", missed_count: 4}
              }} =
               Schedule.handle_command(
                 state,
                 cmd("schedule.skip_fire", ids(%{slot: 101, reason: "missed", missed_count: 4}))
               )
    end

    test "skip reason must be allowed; fire needs task and intent ids" do
      active = created_state()

      assert {:error, {:invalid_skip_reason, "bogus"}} =
               Schedule.handle_command(
                 active,
                 cmd("schedule.skip_fire", ids(%{slot: 1, reason: "bogus"}))
               )

      assert {:error, {:missing_or_invalid, :task_id}} =
               Schedule.handle_command(
                 active,
                 cmd("schedule.mark_fired", ids(%{slot: 1, intent_id: "i"}))
               )

      assert {:error, {:missing_or_invalid, :slot}} =
               Schedule.handle_command(
                 active,
                 cmd("schedule.mark_fired", ids(%{slot: "1", task_id: "t", intent_id: "i"}))
               )
    end
  end

  test "replay folds every stored event and tolerates unknown ones" do
    active = created_state()
    assert ^active = Schedule.apply_event(active, %{event_type: "FutureEvent", payload: %{}})
    assert Schedule.skip_reasons() == ~w(missed overlap project_paused daily_cap error)
  end
end
