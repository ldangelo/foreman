defmodule ForemanServer.ProjectRunLimitTest do
  use ExUnit.Case

  alias ForemanServer.Aggregates.ProjectRunLimit
  alias ForemanServer.Aggregates.ProjectRunLimit.State

  test "tracks active run ids with idempotent reserve and release" do
    assert %State{active_run_ids: active} = ProjectRunLimit.initial_state()
    assert active == MapSet.new()

    payload = %{project_id: "project-1", run_id: "run-1"}

    assert {:ok, start_spec} =
             ProjectRunLimit.handle_command(ProjectRunLimit.initial_state(), %{
               type: "run.start",
               payload: payload
             })

    assert start_spec.event_type == "ProjectRunStarted"

    started =
      ProjectRunLimit.apply_event(ProjectRunLimit.initial_state(), %{
        type: start_spec.event_type,
        payload: start_spec.payload
      })

    assert started.active_run_ids == MapSet.new(["run-1"])

    assert :unhandled =
             ProjectRunLimit.handle_command(started, %{type: "run.start", payload: payload})

    assert {:ok, complete_spec} =
             ProjectRunLimit.handle_command(started, %{type: "run.complete", payload: payload})

    assert complete_spec.event_type == "ProjectRunCompleted"

    completed =
      ProjectRunLimit.apply_event(started, %{
        type: complete_spec.event_type,
        payload: complete_spec.payload
      })

    assert completed.active_run_ids == MapSet.new()

    assert :unhandled =
             ProjectRunLimit.handle_command(completed, %{type: "run.complete", payload: payload})
  end

  test "rejects a distinct run when 100 slots are active" do
    state = %State{active_run_ids: MapSet.new(for index <- 1..100, do: "run-#{index}")}

    assert {:error, :run_limit_exceeded} =
             ProjectRunLimit.handle_command(state, %{
               type: "run.start",
               payload: %{project_id: "project-1", run_id: "run-101"}
             })

    assert :unhandled =
             ProjectRunLimit.handle_command(state, %{
               type: "run.start",
               payload: %{project_id: "project-1", run_id: "run-100"}
             })
  end
end
