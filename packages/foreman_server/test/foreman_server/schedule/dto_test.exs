defmodule ForemanServer.Schedule.DTOTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Schedule.DTO
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @anchor "2026-01-01T00:00:00Z"

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    project_id = "dto-#{System.unique_integer([:positive])}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: project_id, path: "/tmp/#{project_id}"}
        }
      ])

    {:ok, p: project_id}
  end

  # Written to the projection directly, so the spec may be anything the event log can hold.
  defp store!(project_id, schedule_id, name, spec) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ScheduleCreated",
          payload: %{
            schedule_id: schedule_id,
            project_id: project_id,
            name: name,
            spec: spec,
            prompt: "x",
            workflow: "implement",
            created_at: @anchor
          }
        }
      ])
  end

  defp every(interval), do: %{"every" => interval, "timezone" => "UTC", "anchor" => @anchor}

  defp names(project_id, now), do: project_id |> DTO.list(now) |> Enum.map(& &1.name)

  describe "list/2 order: next_fire_at, then name, schedules without a next fire last" do
    # The same four schedules under two injected clocks. The HTTP read uses the wall clock, so
    # it can only assert the ordering contract; here both regimes are pinned exactly.
    setup %{p: p} do
      store!(p, "s1", "zeta", every("1h"))
      store!(p, "s2", "alpha", every("1h"))
      store!(p, "s3", "early", every("5m"))
      store!(p, "s4", "aaa-paused", every("1h"))

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "SchedulePaused",
            payload: %{schedule_id: "s4", project_id: p, at: @anchor}
          }
        ])

      :ok
    end

    test "mid-hour the 5m schedule fires first", %{p: p} do
      assert names(p, ~U[2026-06-01 10:30:00Z]) == ["early", "alpha", "zeta", "aaa-paused"]
    end

    test "in the last five minutes of the hour all three fire together and the name breaks the tie",
         %{p: p} do
      assert names(p, ~U[2026-06-01 10:57:00Z]) == ["alpha", "early", "zeta", "aaa-paused"]
    end
  end

  describe "list/2 never fails the read over a schedule it cannot compute a next fire for" do
    test "no representable next slot lists with next_fire_at nil and says why", %{p: p} do
      store!(p, "s1", "ok", every("1h"))

      log =
        capture_log(fn ->
          assert [%DTO{schedule_id: "s1", status: "active", next_fire_at: nil}] =
                   DTO.list(p, ~U[9999-12-31 23:59:59Z])
        end)

      assert log =~ "could not compute next_fire_at for s1"
      assert log =~ "no_next_slot"
    end

    test "a stored spec beyond today's limits lists with next_fire_at nil and says why", %{p: p} do
      store!(p, "huge", "b-huge", every("3000000d"))
      store!(p, "ok", "a-ok", every("1h"))

      log =
        capture_log(fn ->
          assert [
                   %DTO{schedule_id: "ok", next_fire_at: next},
                   %DTO{schedule_id: "huge", status: "active", next_fire_at: nil}
                 ] = DTO.list(p, ~U[2026-06-01 10:30:00Z])

          assert next == "2026-06-01T11:00:00Z"
        end)

      assert log =~ "could not compute next_fire_at for huge"
      assert log =~ "above_maximum"
    end
  end
end
