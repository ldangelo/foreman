defmodule ForemanServer.Aggregates.ProjectLimitsTest do
  # Per-project concurrency limit and daily thread cap are decided INSIDE the
  # aggregate (atomic with the reservation count), from the project's settings.
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Project

  defp registered(settings \\ %{}) do
    {:ok, reg} =
      Project.handle_command(Project.initial_state(), %{
        type: "project.register",
        payload: %{project_id: "p1", path: "/tmp/p1"}
      })

    state = Project.apply_event(Project.initial_state(), reg)

    if settings == %{} do
      state
    else
      {:ok, upd} =
        Project.handle_command(state, %{
          type: "project.update",
          payload: Map.put(settings, :project_id, "p1")
        })

      Project.apply_event(state, upd)
    end
  end

  defp reserve_run(state, run_id) do
    Project.handle_command(state, %{
      type: "project.reserve_run",
      payload: %{
        project_id: "p1",
        run_id: run_id,
        command_id: "cmd-#{run_id}",
        sequence: 0,
        run_start_payload: %{run_id: run_id}
      }
    })
  end

  defp reserve_thread(state, id) do
    Project.handle_command(state, %{
      type: "project.reserve_thread",
      payload: %{
        project_id: "p1",
        thread_kind: "jobsite",
        thread_id: id,
        command_id: "jobsite-thread:#{id}"
      }
    })
  end

  defp admit({:ok, spec}, state), do: Project.apply_event(state, spec)
  defp today, do: Date.utc_today() |> Date.to_iso8601()

  describe "max_concurrent_runs" do
    test "a project limit of 1 admits one run and rejects the second" do
      state = registered(%{max_concurrent_runs: 1})
      state = admit(reserve_run(state, "r1"), state)

      assert {:error, :run_limit_exceeded} = reserve_run(state, "r2")
    end

    test "another project without a setting is unaffected" do
      assert {:ok, %{event_type: "ProjectRunReserved"}} = reserve_run(registered(), "r1")
    end

    test "changing the setting takes effect on the next reservation" do
      state = registered(%{max_concurrent_runs: 1})
      state = admit(reserve_run(state, "r1"), state)
      assert {:error, :run_limit_exceeded} = reserve_run(state, "r2")

      {:ok, upd} =
        Project.handle_command(state, %{
          type: "project.update",
          payload: %{project_id: "p1", max_concurrent_runs: 2}
        })

      state = Project.apply_event(state, upd)
      assert {:ok, %{event_type: "ProjectRunReserved"}} = reserve_run(state, "r2")
    end

    test "a payload override still wins over the setting (test seam)" do
      state = registered(%{max_concurrent_runs: 1})
      state = admit(reserve_run(state, "r1"), state)

      assert {:ok, _} =
               Project.handle_command(state, %{
                 type: "project.reserve_run",
                 payload: %{
                   project_id: "p1",
                   run_id: "r2",
                   command_id: "cmd-r2",
                   sequence: 0,
                   run_start_payload: %{},
                   max_concurrent_runs_per_project: 5
                 }
               })
    end
  end

  describe "daily_thread_cap" do
    test "the (N+1)th thread of the day is rejected, counting runs and jobsites together" do
      state = registered(%{daily_thread_cap: 2})
      state = admit(reserve_run(state, "r1"), state)
      state = admit(reserve_thread(state, "js1"), state)

      assert {:error, {:daily_thread_cap_exceeded, 2, day}} = reserve_run(state, "r2")
      assert day == today()
      assert {:error, {:daily_thread_cap_exceeded, 2, ^day}} = reserve_thread(state, "js2")
    end

    test "re-reserving a counted run id (release then retry) does not count twice" do
      state = registered(%{daily_thread_cap: 2})
      state = admit(reserve_run(state, "r1"), state)

      {:ok, released} =
        Project.handle_command(state, %{
          type: "project.release_run_reservation",
          payload: %{project_id: "p1", run_id: "r1", reason: "x"}
        })

      state = Project.apply_event(state, released)

      assert {:ok, %{event_type: "ProjectRunReserved"}} = reserve_run(state, "r1")
      state = admit(reserve_thread(state, "js1"), state)
      assert {:error, {:daily_thread_cap_exceeded, 2, _}} = reserve_run(state, "r9")
    end

    test "a counted jobsite thread is idempotent" do
      state = registered(%{daily_thread_cap: 1})
      state = admit(reserve_thread(state, "js1"), state)
      assert {:ok, nil} = reserve_thread(state, "js1")
    end

    test "the count rolls over when the UTC day changes" do
      state = registered(%{daily_thread_cap: 1})

      yesterday = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()

      state =
        Project.apply_event(state, %{
          event_type: "ProjectThreadStarted",
          payload: %{
            project_id: "p1",
            thread_kind: "jobsite",
            thread_id: "old",
            day: yesterday
          }
        })

      assert {:ok, %{event_type: "ProjectThreadStarted"}} = reserve_thread(state, "js-today")
    end

    test "reserved_on rides on the event, so replay never consults a clock" do
      state = registered(%{daily_thread_cap: 1})
      {:ok, spec} = reserve_run(state, "r1")
      assert spec.payload.reserved_on == today()
    end

    test "without a cap nothing is rejected" do
      state = registered()
      state = admit(reserve_thread(state, "a"), state)
      state = admit(reserve_thread(state, "b"), state)
      assert {:ok, _} = reserve_thread(state, "c")
    end

    test "only the jobsite thread kind is accepted" do
      assert {:error, {:missing_or_invalid, :thread_kind, "run"}} =
               Project.handle_command(registered(), %{
                 type: "project.reserve_thread",
                 payload: %{
                   project_id: "p1",
                   thread_kind: "run",
                   thread_id: "x",
                   command_id: "c"
                 }
               })
    end
  end

  describe "pause / resume" do
    defp pause(state),
      do: Project.handle_command(state, %{type: "project.pause", payload: %{project_id: "p1"}})

    defp resume(state),
      do: Project.handle_command(state, %{type: "project.resume", payload: %{project_id: "p1"}})

    test "pause refuses new run reservations and thread starts; resume restores both" do
      state = registered()
      state = admit(pause(state), state)
      assert state.status == "paused"

      assert {:error, {:project_paused, "p1"}} = reserve_run(state, "r1")
      assert {:error, {:project_paused, "p1"}} = reserve_thread(state, "js1")

      state = admit(resume(state), state)
      assert state.status == "active"
      assert {:ok, _} = reserve_run(state, "r1")
      assert {:ok, _} = reserve_thread(state, "js1")
    end

    test "a run that is already reserved keeps its reservation while paused (in-flight work continues)" do
      state = registered()
      state = admit(reserve_run(state, "r1"), state)
      state = admit(pause(state), state)

      assert {:ok, nil} = reserve_run(state, "r1")
      assert map_size(state.active_run_reservations) == 1
    end

    test "pause and resume are state-checked with distinct errors" do
      state = registered()
      assert {:error, {:not_paused, :project}} = resume(state)
      state = admit(pause(state), state)
      assert {:error, {:already_paused, :project}} = pause(state)
    end

    test "an archived project cannot be paused" do
      state = registered()

      {:ok, arch} =
        Project.handle_command(state, %{type: "project.archive", payload: %{project_id: "p1"}})

      state = Project.apply_event(state, arch)
      assert {:error, {:project_archived, "p1"}} = pause(state)
    end

    test "status is not editable through project.update" do
      assert {:error, {:setting_not_editable, :status}} =
               Project.handle_command(registered(), %{
                 type: "project.update",
                 payload: %{project_id: "p1", status: "paused"}
               })
    end
  end
end
