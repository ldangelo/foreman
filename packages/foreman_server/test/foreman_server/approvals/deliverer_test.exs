defmodule ForemanServer.Approvals.DelivererTest do
  # End to end through the real gateway, aggregates and projection: a tool call is
  # requested, an operator decides, and the decision reaches the agent either live
  # (fake provider session) or by resuming the paused run with a one-phase
  # approval_mode override.
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.ToolCall
  alias ForemanServer.Approvals.{Deliverer, Live, Requester}
  alias ForemanServer.{CommandGateway, CommandRouter, ProjectionStore}

  defmodule FakeSession do
    @moduledoc false
    def respond_approval(session_id, request_id, decision) do
      send(
        Process.whereis(:approvals_deliverer_test),
        {:responded, session_id, request_id, decision}
      )

      :ok
    end
  end

  setup do
    :ok = ProjectionStore.subscribe(replay_existing: false)
    Process.register(self(), :approvals_deliverer_test)
    live = start_supervised!({Live, name: :deliverer_test_live})
    _ = live

    start_supervised!(
      {Deliverer, name: :deliverer_test, live: :deliverer_test_live, session_module: FakeSession}
    )

    :ok
  end

  defp start_run! do
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

    await("RunStarted", :run_id, run_id)
    {project_id, run_id}
  end

  defp pause!(run_id) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.pause",
        command_id: "test-pause:#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{run_id: run_id, reason: "awaiting_approval"}
      })

    await("RunPaused", :run_id, run_id)
  end

  defp decide!(type, run_id, id) do
    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: type,
        command_id: "op:#{type}:#{run_id}:#{id}",
        aggregate_id: ToolCall.stream_id(run_id, id),
        payload: %{run_id: run_id, tool_call_id: id}
      })
  end

  defp field(data, key) do
    data = if is_struct(data), do: Map.from_struct(data), else: data
    Map.get(data, key, Map.get(data, to_string(key)))
  end

  defp await(type, key, id) do
    receive do
      {:projection_event, %{event_type: ^type, data: data}} ->
        if field(data, key) == id, do: data, else: await(type, key, id)

      {:projection_event, _other} ->
        await(type, key, id)
    after
      15_000 -> flunk("timed out waiting for #{type} on #{id}")
    end
  end

  describe "resume_with_override (pi, claude)" do
    test "approving queues a steer carrying the one-phase override, resumes the paused run and finishes the call" do
      {project_id, run_id} = start_run!()

      {:ok, id} =
        Requester.request(
          %{run_id: run_id, project_id: project_id, provider: :claude},
          "Write",
          "a.txt",
          phase_index: 1
        )

      pause!(run_id)
      decide!("tool.approve", run_id, id)

      steer = await("RunSteerQueued", :run_id, run_id)
      assert field(steer, :approval_mode_override) == "auto_edit"
      assert field(steer, :text) =~ "approved"
      assert field(steer, :steered_by) == "approvals"

      await("RunResumed", :run_id, run_id)
      finished = await("ToolCallFinished", :run_id, run_id)
      assert field(finished, :tool_call_id) == id
      assert field(finished, :outcome) == "delivered"
      assert %{status: "finished"} = ProjectionStore.tool_call(run_id, id)
    end

    test "a non-edit tool gets auto_approve" do
      {project_id, run_id} = start_run!()

      {:ok, id} =
        Requester.request(%{run_id: run_id, project_id: project_id}, "Bash", "ls", phase_index: 1)

      pause!(run_id)
      decide!("tool.approve", run_id, id)

      assert field(await("RunSteerQueued", :run_id, run_id), :approval_mode_override) ==
               "auto_approve"
    end

    test "denying tells the agent not to use the tool, carries no override and resumes" do
      {project_id, run_id} = start_run!()

      {:ok, id} =
        Requester.request(%{run_id: run_id, project_id: project_id}, "Bash", "rm -rf",
          phase_index: 1
        )

      pause!(run_id)
      decide!("tool.deny", run_id, id)

      steer = await("RunSteerQueued", :run_id, run_id)
      assert field(steer, :approval_mode_override) == nil
      assert field(steer, :text) =~ "denied"
      await("RunResumed", :run_id, run_id)
      assert %{status: "denied"} = ProjectionStore.tool_call(run_id, id)
    end

    test "a delivery failure finishes the call with the error instead of leaving it approved" do
      # No such run: the steer cannot be queued.
      run_id = "run-ghost-#{System.unique_integer([:positive])}"

      {:ok, id} =
        Requester.request(%{run_id: run_id, provider: :claude}, "Write", "x", phase_index: 1)

      decide!("tool.approve", run_id, id)

      finished = await("ToolCallFinished", :run_id, run_id)
      assert field(finished, :outcome) =~ "delivery_failed"
    end
  end

  describe "live (ACP providers)" do
    test "approving answers the registered provider session and finishes the call" do
      run_id = "run-live-#{System.unique_integer([:positive])}"

      {:ok, id} = Requester.request(%{run_id: run_id, provider: :opencode}, "edit", "a", [])
      :ok = Live.register(:deliverer_test_live, run_id, id, "ses-1", "req-0")
      decide!("tool.approve", run_id, id)

      assert_receive {:responded, "ses-1", "req-0", :approve}, 15_000
      assert field(await("ToolCallFinished", :run_id, run_id), :outcome) == "delivered"
    end

    test "denying answers the session with :deny" do
      run_id = "run-live-#{System.unique_integer([:positive])}"

      {:ok, id} = Requester.request(%{run_id: run_id, provider: :opencode}, "edit", "a", [])
      :ok = Live.register(:deliverer_test_live, run_id, id, "ses-2", "req-1")
      decide!("tool.deny", run_id, id)

      assert_receive {:responded, "ses-2", "req-1", :deny}, 15_000
    end

    test "approving a live call nobody registered is a failed delivery, never a silent success" do
      run_id = "run-live-#{System.unique_integer([:positive])}"

      {:ok, id} = Requester.request(%{run_id: run_id, provider: :opencode}, "edit", "a", [])
      decide!("tool.approve", run_id, id)

      finished = await("ToolCallFinished", :run_id, run_id)
      assert field(finished, :outcome) =~ "delivery_failed"
      assert field(finished, :outcome) =~ "no_live_request"
      refute_received {:responded, _, _, _}
    end
  end
end
