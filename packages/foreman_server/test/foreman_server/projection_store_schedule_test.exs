defmodule ForemanServer.ProjectionStoreScheduleTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @at "2026-01-01T00:00:00Z"

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
  end

  defp ev(type, payload), do: %{event_type: type, payload: payload}

  defp created(id, name, extra \\ %{}) do
    ev(
      "ScheduleCreated",
      Map.merge(
        %{
          schedule_id: id,
          project_id: "p",
          name: name,
          spec: %{"every" => "1h"},
          prompt: "do",
          workflow: "implement",
          auto_approve: true,
          overlap: "skip",
          misfire_grace_seconds: 600,
          created_at: @at
        },
        extra
      )
    )
  end

  test "created, updated, paused and fired fold into one current record" do
    :ok =
      ProjectionStore.apply_events([
        created("s1", "b"),
        ev("ScheduleUpdated", %{
          schedule_id: "s1",
          project_id: "p",
          changes: %{"name" => "B2", "spec" => %{"every" => "2h"}},
          updated_at: "2026-01-02T00:00:00Z"
        }),
        ev("SchedulePaused", %{schedule_id: "s1", project_id: "p", at: @at}),
        ev("ScheduleFired", %{
          schedule_id: "s1",
          project_id: "p",
          slot: 100,
          task_id: "t1",
          intent_id: "i",
          collapsed_count: 3,
          fired_at: @at
        })
      ])

    assert %{
             name: "B2",
             spec: %{"every" => "2h"},
             status: "paused",
             last_slot: 100,
             last_task_id: "t1",
             last_outcome: %{kind: "fired", slot: 100, missed_count: 3},
             active_since: since
           } = ProjectionStore.schedule("p", "s1")

    # A spec change restarts the slot baseline at the update time.
    assert since == DateTime.to_unix(~U[2026-01-02 00:00:00Z])
  end

  test "last_outcome reflects the latest of fire and skip; resume resets active_since" do
    :ok =
      ProjectionStore.apply_events([
        created("s1", "a"),
        ev("ScheduleFired", %{
          schedule_id: "s1",
          project_id: "p",
          slot: 1,
          task_id: "t",
          intent_id: "i",
          fired_at: @at
        }),
        ev("ScheduleFireSkipped", %{
          schedule_id: "s1",
          project_id: "p",
          slot: 2,
          reason: "overlap",
          skipped_at: @at
        }),
        ev("ScheduleResumed", %{schedule_id: "s1", project_id: "p", at: "2026-03-01T00:00:00Z"})
      ])

    assert %{
             last_slot: 2,
             last_task_id: "t",
             last_outcome: %{kind: "skipped", reason: "overlap", slot: 2},
             status: "active",
             active_since: since
           } =
             ProjectionStore.schedule("p", "s1")

    assert since == DateTime.to_unix(~U[2026-03-01 00:00:00Z])
  end

  test "readers: deleted hidden by default, paused listed with status, active-only for the ticker" do
    :ok =
      ProjectionStore.apply_events([
        created("s1", "alpha"),
        created("s2", "beta"),
        created("s3", "gamma"),
        ev("SchedulePaused", %{schedule_id: "s2", project_id: "p", at: @at}),
        ev("ScheduleDeleted", %{schedule_id: "s3", project_id: "p", at: @at}),
        created("o1", "other", %{project_id: "q"}) |> then(&put_in(&1.payload.project_id, "q"))
      ])

    assert [{"alpha", "active"}, {"beta", "paused"}] =
             "p" |> ProjectionStore.schedules() |> Enum.map(&{&1.name, &1.status})

    assert 3 == "p" |> ProjectionStore.schedules(include_deleted: true) |> length()
    assert %{status: "deleted"} = ProjectionStore.schedule("p", "s3")

    assert ["o1", "s1"] ==
             ProjectionStore.all_active_schedules() |> Enum.map(& &1.schedule_id) |> Enum.sort()

    assert ProjectionStore.schedule("p", "missing") == nil
  end

  test "a malformed event does not crash the projection and events for unknown schedules are ignored" do
    :ok =
      ProjectionStore.apply_events([
        ev("ScheduleCreated", %{schedule_id: "bad", project_id: "p"}),
        ev("SchedulePaused", %{schedule_id: "ghost", project_id: "p", at: @at}),
        ev("ScheduleFired", %{garbage: true}),
        created("ok", "fine")
      ])

    assert ["ok"] == "p" |> ProjectionStore.schedules() |> Enum.map(& &1.schedule_id)
    assert ProjectionStore.schedule("p", "ghost") == nil
  end

  test "scheduler intents keep schedule_id, project_id and slot" do
    :ok =
      ProjectionStore.apply_events([
        ev("ScheduledFireRecorded", %{
          intent_id: "s1:5",
          schedule_id: "s1",
          project_id: "p",
          slot: 5
        })
      ])

    assert %{schedule_id: "s1", project_id: "p", slot: 5, status: "recorded"} =
             Enum.find(ProjectionStore.list_scheduler_intents(), &(&1.intent_id == "s1:5"))
  end
end
