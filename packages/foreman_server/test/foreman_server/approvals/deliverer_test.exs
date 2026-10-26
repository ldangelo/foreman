defmodule ForemanServer.Approvals.DelivererTest do
  # End to end through the real gateway, aggregates and projection: a tool call is
  # requested, an operator decides, and the decision reaches the agent either live
  # (fake provider session) or by resuming the paused run with a one-phase
  # approval_mode override.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.Aggregates.ToolCall
  alias ForemanServer.Approvals.{Deliverer, Inflight, Live, Requester}
  alias ForemanServer.{CommandGateway, CommandRouter, EventStore, ProjectionStore}

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

  # The real gateway, with every command it is handed reported to the test process.
  defmodule RecordingGateway do
    @moduledoc false
    def dispatch_system(command) do
      send(Process.whereis(:approvals_deliverer_test), {:dispatched, command})
      ForemanServer.CommandGateway.dispatch_system(command)
    end
  end

  # The real gateway, except that the FIRST `tool.finish` kills the calling process: the
  # deliverer dies after the decision reached the agent and before `settle/4` finished
  # the call (the supervisor restarts it, and its startup recovery must settle the call).
  defmodule DiesBeforeSettleGateway do
    @moduledoc false
    def dispatch_system(%{type: "tool.finish"} = command) do
      if Agent.get_and_update(:deliverer_test_died, &{&1, true}),
        do: ForemanServer.CommandGateway.dispatch_system(command),
        else: exit(:deliverer_died_before_settle)
    end

    def dispatch_system(command), do: ForemanServer.CommandGateway.dispatch_system(command)
  end

  setup do
    :ok = ProjectionStore.subscribe(replay_existing: false)
    Process.register(self(), :approvals_deliverer_test)
    live = start_supervised!({Live, name: :deliverer_test_live})
    _ = live

    # The deliverer's startup recovery re-delivers every decided call in the global
    # projection, including in-flight ones other test modules left behind. A private
    # Inflight server (never the app's, which is off in test) answers those, so a stale
    # call settles as a failed delivery instead of crash-looping the deliverer.
    start_supervised!({Inflight, name: :deliverer_test_inflight})

    start_supervised!(
      {Deliverer,
       name: :deliverer_test,
       live: :deliverer_test_live,
       inflight: :deliverer_test_inflight,
       session_module: FakeSession}
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

  defp pause!(run_id, reason \\ "awaiting_approval") do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.pause",
        command_id: "test-pause:#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{run_id: run_id, reason: reason}
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

  defp for_run(commands, run_id),
    do: Enum.filter(commands, &String.contains?(&1.aggregate_id, run_id))

  # Queue a steer message on a paused run and have the run take it, under the deliverer's own
  # deterministic command id (`resume: false`: nothing may resume the run).
  defp take_steer!(run_id, message_id, command_id) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.steer",
        command_id: command_id,
        aggregate_id: "run:" <> run_id,
        payload: %{
          run_id: run_id,
          message_id: message_id,
          text: "decided",
          steered_by: "approvals",
          resume: false
        }
      })

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.steer.consume",
        command_id: "test-consume:" <> command_id,
        aggregate_id: "run:" <> run_id,
        payload: %{run_id: run_id, message_ids: [message_id]}
      })
  end

  # The options every deliverer of these tests is started, or recovered, with.
  defp deliverer_opts(extra \\ []) do
    [live: :deliverer_test_live, inflight: :deliverer_test_inflight, session_module: FakeSession] ++
      extra
  end

  defp call_events(run_id, id) do
    {:ok, events} = EventStore.read_stream_forward(ToolCall.stream_id(run_id, id), 0, 1_000)
    Enum.map(events, & &1.event_type)
  end

  # The durable events of one type on the run's stream (not what the projection broadcast).
  defp run_events(run_id, type) do
    {:ok, events} = EventStore.read_stream_forward("run:" <> run_id, 0, 1_000)
    for %{event_type: ^type, data: data} <- events, do: data
  end

  # Every command a `RecordingGateway` reported so far, oldest first.
  defp dispatched do
    receive do
      {:dispatched, command} -> [command | dispatched()]
    after
      0 -> []
    end
  end

  # The deliverer dies the first time it is about to settle a call (`DiesBeforeSettleGateway`)
  # and its supervisor restarts it. Returns the pid of the first incarnation.
  defp start_dying_deliverer! do
    :ok = stop_supervised(Deliverer)

    start_supervised!(%{
      id: :deliverer_test_died,
      start: {Agent, :start_link, [fn -> false end, [name: :deliverer_test_died]]}
    })

    start_supervised!(
      {Deliverer, deliverer_opts(name: :deliverer_test_dying, gateway: DiesBeforeSettleGateway)},
      id: :deliverer_test_dying
    )

    Process.whereis(:deliverer_test_dying)
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

  describe "startup recovery" do
    test "resume_with_override: an approval committed while the deliverer was down is delivered once on restart" do
      {project_id, run_id} = start_run!()

      {:ok, id} =
        Requester.request(
          %{run_id: run_id, project_id: project_id, provider: :claude},
          "Write",
          "a",
          phase_index: 1
        )

      pause!(run_id)
      :ok = stop_supervised(Deliverer)

      decide!("tool.approve", run_id, id)
      await("ToolCallApproved", :run_id, run_id)
      assert %{status: "approved"} = ProjectionStore.tool_call(run_id, id)

      start_supervised!({Deliverer, deliverer_opts(name: :deliverer_test_2)})

      await("ToolCallFinished", :run_id, run_id)
      assert %{status: "finished", outcome: "delivered"} = ProjectionStore.tool_call(run_id, id)

      # exactly once: a second recovery pass sends nothing for this run and appends nothing
      Deliverer.recover(deliverer_opts(gateway: RecordingGateway))
      assert for_run(dispatched(), run_id) == []
      assert [_once] = run_events(run_id, "RunSteerQueued")
      assert [_once] = run_events(run_id, "RunResumed")

      assert call_events(run_id, id) == [
               "ToolCallRequested",
               "ToolCallApproved",
               "ToolCallFinished"
             ]
    end

    test "live: only the approval committed while the deliverer was down is delivered, once; history is not replayed" do
      run_id = "run-live-#{System.unique_integer([:positive])}"

      for id <- ["a", "b"] do
        {:ok, ^id} =
          Requester.request(%{run_id: run_id, provider: :opencode}, "edit", id, tool_call_id: id)

        :ok = Live.register(:deliverer_test_live, run_id, id, "ses-#{id}", "req-#{id}")
      end

      # `a` is decided and delivered while the deliverer runs: it is history by the restart
      decide!("tool.approve", run_id, "a")
      assert_receive {:responded, "ses-a", "req-a", :approve}, 15_000
      await("ToolCallFinished", :tool_call_id, "a")

      :ok = stop_supervised(Deliverer)
      decide!("tool.approve", run_id, "b")
      await("ToolCallApproved", :tool_call_id, "b")
      assert %{status: "approved"} = ProjectionStore.tool_call(run_id, "b")

      assert Deliverer.recover(deliverer_opts(gateway: RecordingGateway)) >= 1

      assert_received {:responded, "ses-b", "req-b", :approve}
      refute_received {:responded, _, _, _}
      assert %{status: "finished", outcome: "delivered"} = ProjectionStore.tool_call(run_id, "b")
      done = ["ToolCallRequested", "ToolCallApproved", "ToolCallFinished"]
      assert call_events(run_id, "b") == done
      assert call_events(run_id, "a") == done

      # the only command the recovery sent for this run settles `b`: nothing of `a` was replayed
      assert [%{type: "tool.finish", aggregate_id: settled}] = for_run(dispatched(), run_id)
      assert settled == ToolCall.stream_id(run_id, "b")

      # idempotent: a second pass has nothing left to deliver for this run
      Deliverer.recover(deliverer_opts(gateway: RecordingGateway))
      assert for_run(dispatched(), run_id) == []
      refute_received {:responded, _, _, _}
    end

    test "inflight: an approval committed while the deliverer was down wakes the still-blocked agent once" do
      run_id = "run-inflight-#{System.unique_integer([:positive])}"

      {:ok, id} =
        Requester.request(%{run_id: run_id, provider: :claude}, "Bash", "ls",
          tool_call_id: "inf-1",
          delivery: :inflight
        )

      # this process is the blocked agent's waiter
      :ok = Inflight.register(run_id, id, :deliverer_test_inflight)

      :ok = stop_supervised(Deliverer)
      decide!("tool.approve", run_id, id)
      await("ToolCallApproved", :tool_call_id, id)

      Deliverer.recover(deliverer_opts(gateway: RecordingGateway))

      assert {:approve, nil} = Inflight.await(run_id, id, 0)
      assert %{status: "finished", outcome: "delivered"} = ProjectionStore.tool_call(run_id, id)
      assert [%{type: "tool.finish"}] = for_run(dispatched(), run_id)

      # idempotent: the waiter is not woken a second time
      Deliverer.recover(deliverer_opts(gateway: RecordingGateway))
      assert for_run(dispatched(), run_id) == []
      assert Inflight.await(run_id, id, 0) == :timeout
    end

    test "inflight: when the agent died with the server nobody waits, so the recovered approval settles as a failed delivery" do
      run_id = "run-inflight-#{System.unique_integer([:positive])}"

      {:ok, id} =
        Requester.request(%{run_id: run_id, provider: :claude}, "Bash", "ls",
          tool_call_id: "inf-2",
          delivery: :inflight
        )

      :ok = stop_supervised(Deliverer)
      decide!("tool.approve", run_id, id)
      await("ToolCallApproved", :tool_call_id, id)

      Deliverer.recover(deliverer_opts())

      assert %{status: "finished", outcome: "delivery_failed: :no_live_request"} =
               ProjectionStore.tool_call(run_id, id)
    end

    test "resume_with_override: a deliverer that died before settling is restarted and settles the call without redoing the delivery" do
      {project_id, run_id} = start_run!()

      {:ok, id} =
        Requester.request(
          %{run_id: run_id, project_id: project_id, provider: :claude},
          "Write",
          "a",
          phase_index: 1
        )

      pause!(run_id)
      first = start_dying_deliverer!()

      capture_log(fn ->
        decide!("tool.approve", run_id, id)
        await("ToolCallFinished", :tool_call_id, id)
      end)

      assert Process.whereis(:deliverer_test_dying) != first
      assert %{status: "finished", outcome: "delivered"} = ProjectionStore.tool_call(run_id, id)
      assert [_once] = run_events(run_id, "RunSteerQueued")
      assert [_once] = run_events(run_id, "RunResumed")

      assert call_events(run_id, id) == [
               "ToolCallRequested",
               "ToolCallApproved",
               "ToolCallFinished"
             ]
    end

    test "live: a deliverer that died before settling never answers the session twice, and the call is settled" do
      run_id = "run-live-#{System.unique_integer([:positive])}"

      {:ok, id} =
        Requester.request(%{run_id: run_id, provider: :opencode}, "edit", "a", tool_call_id: "d")

      :ok = Live.register(:deliverer_test_live, run_id, id, "ses-d", "req-d")
      first = start_dying_deliverer!()

      capture_log(fn ->
        decide!("tool.approve", run_id, id)
        await("ToolCallFinished", :tool_call_id, id)
      end)

      assert Process.whereis(:deliverer_test_dying) != first
      assert_received {:responded, "ses-d", "req-d", :approve}
      refute_received {:responded, _, _, _}
      assert %{status: "finished", outcome: outcome} = ProjectionStore.tool_call(run_id, id)
      assert outcome =~ ~r/^(delivered|delivery_failed: )/
    end

    test "inflight: a deliverer that died before settling woke the agent once, and the call is settled" do
      run_id = "run-inflight-#{System.unique_integer([:positive])}"

      {:ok, id} =
        Requester.request(%{run_id: run_id, provider: :claude}, "Bash", "ls",
          tool_call_id: "inf-3",
          delivery: :inflight
        )

      :ok = Inflight.register(run_id, id, :deliverer_test_inflight)
      first = start_dying_deliverer!()

      capture_log(fn ->
        decide!("tool.approve", run_id, id)
        await("ToolCallFinished", :tool_call_id, id)
      end)

      assert Process.whereis(:deliverer_test_dying) != first
      assert {:approve, nil} = Inflight.await(run_id, id, 0)
      assert Inflight.await(run_id, id, 0) == :timeout
      assert %{status: "finished", outcome: outcome} = ProjectionStore.tool_call(run_id, id)
      assert outcome =~ ~r/^(delivered|delivery_failed: )/
    end

    test "a decision whose steer the run already took never resumes a run that is paused for another reason" do
      {project_id, run_id} = start_run!()
      :ok = stop_supervised(Deliverer)

      {:ok, id} =
        Requester.request(
          %{run_id: run_id, project_id: project_id, provider: :claude},
          "Bash",
          "rm",
          phase_index: 1
        )

      # the operator paused the run; the pause has nothing to do with this call
      pause!(run_id, "operator")
      decide!("tool.deny", run_id, id)

      # In an earlier life the deliverer already queued this decision's steer and the run took
      # it (the run was running, so no `approval-resume` was ever needed).
      take_steer!(run_id, "approval:" <> id, "approval-steer:#{run_id}:#{id}")

      Deliverer.recover(deliverer_opts())

      assert %{status: "paused"} = ProjectionStore.run(run_id)
      assert run_events(run_id, "RunResumed") == []
    end

    test "an approved call that was never settled is surfaced as a delivery problem" do
      {project_id, run_id} = start_run!()
      :ok = stop_supervised(Deliverer)

      {:ok, id} =
        Requester.request(%{run_id: run_id, project_id: project_id}, "Write", "a", phase_index: 1)

      pause!(run_id)
      decide!("tool.approve", run_id, id)
      await("ToolCallApproved", :run_id, run_id)

      assert %{approvals: %{^run_id => %{failed_deliveries: 1}}} =
               ProjectionStore.needs_you_counts([run_id])
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
