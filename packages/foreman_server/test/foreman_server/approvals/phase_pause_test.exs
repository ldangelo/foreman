defmodule ForemanServer.Approvals.PhasePauseTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.ToolCall
  alias ForemanServer.Approvals.PhasePause
  alias ForemanServer.{CommandGateway, CommandRouter, ProjectionStore}

  setup do
    :ok = ProjectionStore.subscribe(replay_existing: false)
    project_id = "p-#{System.unique_integer([:positive])}"
    run_id = "run-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        aggregate_id: "project:#{project_id}",
        command_id: "register:#{project_id}",
        type: "project.register",
        payload: %{project_id: project_id, name: project_id, path: System.tmp_dir!()}
      })

    {:ok, _} =
      CommandRouter.dispatch_run_start(project_id, %{
        run_id: run_id,
        task_id: "task-#{run_id}",
        workflow_snapshot: %{phases: [%{id: "phase-1", kind: "command"}]},
        phase_specs: [%{phase_id: "phase-1", kind: "command"}],
        approval_id: "approval-#{run_id}"
      })

    await("RunStarted", run_id)
    %{run_id: run_id, context: %{run_id: run_id, project_id: project_id, provider: :claude}}
  end

  defp await(type, run_id) do
    receive do
      {:projection_event, %{event_type: ^type, data: data}} ->
        data = if is_struct(data), do: Map.from_struct(data), else: data
        if (data[:run_id] || data["run_id"]) == run_id, do: data, else: await(type, run_id)

      {:projection_event, _other} ->
        await(type, run_id)
    after
      15_000 -> flunk("timed out waiting for #{type} on #{run_id}")
    end
  end

  test "records a request per denied tool and pauses the run as awaiting approval",
       %{run_id: run_id, context: context} do
    assert :ok = PhasePause.request_and_pause(context, 2, ["Write", "Bash", "Write"])

    paused = await("RunPaused", run_id)
    assert paused[:reason] == "awaiting_approval"

    assert ["perm-2-Bash-1", "perm-2-Write-1"] ==
             run_id
             |> ProjectionStore.run_approvals()
             |> Enum.map(& &1.tool_call_id)
             |> Enum.sort()
  end

  test "reporting the same denial again reuses the pending request",
       %{run_id: run_id, context: context} do
    assert :ok = PhasePause.request_and_pause(context, 1, ["Write"])
    assert :ok = PhasePause.request_and_pause(context, 1, ["Write"])
    await("RunPaused", run_id)

    assert [%{tool_call_id: "perm-1-Write-1"}] = ProjectionStore.run_approvals(run_id)
  end

  test "a denial after the first request was decided is a NEW request, so the run cannot stick",
       %{run_id: run_id, context: context} do
    assert :ok = PhasePause.request_and_pause(context, 1, ["Write"])
    await("ToolCallRequested", run_id)

    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "tool.approve",
        command_id: "op:approve:#{run_id}",
        aggregate_id: ToolCall.stream_id(run_id, "perm-1-Write-1"),
        payload: %{run_id: run_id, tool_call_id: "perm-1-Write-1"}
      })

    await("ToolCallApproved", run_id)

    assert :ok = PhasePause.request_and_pause(context, 1, ["Write"])
    await("ToolCallRequested", run_id)

    assert [%{tool_call_id: "perm-1-Write-2", status: "requested"}] =
             ProjectionStore.run_approvals(run_id)
  end

  test "a run that does not exist is an error, so the caller keeps the failure path" do
    assert {:error, _reason} =
             PhasePause.request_and_pause(
               %{run_id: "run-nope-#{System.unique_integer([:positive])}"},
               1,
               ["Write"]
             )
  end

  # claude reports a tool refused in flight in the result's `permission_denials` too
  # (observed on the real CLI). The agent was already told; asking again would pause
  # the run for a decision that has been made.
  test "a tool already denied in flight is not requested again; other denied tools still are",
       %{run_id: run_id, context: context} do
    {:ok, "inflight-toolu_1"} =
      ForemanServer.Approvals.Requester.request(context, "Write", %{"file_path" => "/a"},
        tool_call_id: "inflight-toolu_1",
        delivery: :inflight
      )

    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "tool.deny",
        command_id: "op:deny:#{run_id}",
        aggregate_id: ToolCall.stream_id(run_id, "inflight-toolu_1"),
        payload: %{run_id: run_id, tool_call_id: "inflight-toolu_1"}
      })

    await("ToolCallDenied", run_id)

    assert {:error, :denied_in_flight} = PhasePause.request_and_pause(context, 1, ["Write"])

    assert [%{tool_call_id: "inflight-toolu_1"}] =
             ProjectionStore.run_approvals(run_id, status: :all)

    assert :ok = PhasePause.request_and_pause(context, 1, ["Write", "Bash"])

    assert ["inflight-toolu_1", "perm-1-Bash-1"] ==
             run_id
             |> ProjectionStore.run_approvals(status: :all)
             |> Enum.map(& &1.tool_call_id)
             |> Enum.sort()
  end
end
