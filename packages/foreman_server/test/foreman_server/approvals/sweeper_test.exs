defmodule ForemanServer.Approvals.SweeperTest.RecordingGateway do
  @moduledoc false
  # Delegates to the real CommandGateway and tells the registered test process which
  # command each dispatch carried, so the sweeper's command id can be read.
  def dispatch_system(command) do
    if pid = Process.whereis(:sweeper_test_probe), do: send(pid, {:dispatched, command})
    ForemanServer.CommandGateway.dispatch_system(command)
  end
end

defmodule ForemanServer.Approvals.SweeperTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.{OperatorQuestion, ToolCall}
  alias ForemanServer.Approvals.{Requester, Sweeper}
  alias ForemanServer.{CommandGateway, EventStore, Overview, ProjectionStore}
  alias ForemanServer.TestSupport.{Eventually, ProjectionStoreReset}

  @timeout 30 * 60 * 1000

  setup do
    :ok = ProjectionStore.subscribe(replay_existing: false)
    :ok
  end

  defp events(stream) do
    {:ok, evs} = EventStore.read_stream_forward(stream, 0, 100)
    Enum.map(evs, & &1.event_type)
  end

  defp await_projection(type, id_key, id) do
    receive do
      {:projection_event, %{event_type: ^type, data: data}} ->
        data = if is_struct(data), do: Map.from_struct(data), else: data

        if (data[id_key] || data[to_string(id_key)]) == id,
          do: :ok,
          else: await_projection(type, id_key, id)

      {:projection_event, _} ->
        await_projection(type, id_key, id)
    after
      10_000 -> flunk("timed out waiting for #{type}")
    end
  end

  defp request!(run_id, id) do
    {:ok, ^id} = Requester.request(%{run_id: run_id}, "Write", "x", tool_call_id: id)
    await_projection("ToolCallRequested", :tool_call_id, id)
    ProjectionStore.tool_call(run_id, id)
  end

  defp start_run!(project_id, run_id) do
    {:ok, _} =
      ForemanServer.CommandRouter.dispatch(%{
        aggregate_id: "project:#{project_id}",
        command_id: "register:#{project_id}",
        type: "project.register",
        payload: %{project_id: project_id, name: project_id, path: System.tmp_dir!()}
      })

    {:ok, _} =
      ForemanServer.CommandRouter.dispatch_run_start(project_id, %{
        run_id: run_id,
        task_id: "task-#{run_id}",
        workflow_snapshot: %{phases: [%{id: "phase-1", kind: "command"}]},
        phase_specs: [%{phase_id: "phase-1", kind: "command"}],
        approval_id: "approval-#{run_id}"
      })

    await_projection("RunStarted", :run_id, run_id)
  end

  defp pause!(run_id) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.pause",
        command_id: "test-pause:#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{run_id: run_id, reason: "awaiting_answer"}
      })

    await_projection("RunPaused", :run_id, run_id)
  end

  defp sweeper(now_ms, opts \\ []) do
    name = :"sweeper_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {Sweeper, [name: name, interval_ms: :manual, now_fun: fn -> now_ms end] ++ opts},
        id: name
      )
    )

    name
  end

  test "a call one ms short of the timeout is untouched; exactly at it, it is expired once" do
    run_id = "run-sw-#{System.unique_integer([:positive])}"
    call = request!(run_id, "edge")
    deadline = call.requested_at_ms + @timeout

    Sweeper.sweep(sweeper(deadline - 1))
    assert %{status: "requested"} = ProjectionStore.tool_call(run_id, "edge")
    assert events(ToolCall.stream_id(run_id, "edge")) == ["ToolCallRequested"]

    server = sweeper(deadline)
    Sweeper.sweep(server)
    await_projection("ToolCallExpired", :tool_call_id, "edge")
    Sweeper.sweep(server)

    assert events(ToolCall.stream_id(run_id, "edge")) == ["ToolCallRequested", "ToolCallExpired"]
    assert %{status: "expired"} = ProjectionStore.tool_call(run_id, "edge")
  end

  test "an expired call can no longer be approved" do
    run_id = "run-sw-#{System.unique_integer([:positive])}"
    call = request!(run_id, "c")
    Sweeper.sweep(sweeper(call.requested_at_ms + @timeout))
    await_projection("ToolCallExpired", :tool_call_id, "c")

    assert {:error, {:tool_call_expired, "timeout"}} =
             CommandGateway.dispatch_operator(%{
               type: "tool.approve",
               command_id: "op-late-#{run_id}",
               aggregate_id: ToolCall.stream_id(run_id, "c"),
               payload: %{run_id: run_id, tool_call_id: "c"}
             })
  end

  test "on_timeout :deny denies with reason timeout and records no expiry" do
    run_id = "run-sw-#{System.unique_integer([:positive])}"
    call = request!(run_id, "d")
    Sweeper.sweep(sweeper(call.requested_at_ms + @timeout, on_timeout: :deny))
    await_projection("ToolCallDenied", :tool_call_id, "d")

    assert events(ToolCall.stream_id(run_id, "d")) == ["ToolCallRequested", "ToolCallDenied"]

    assert %{status: "denied", reason: "timeout", decided_by: "system"} =
             ProjectionStore.tool_call(run_id, "d")
  end

  test "a restarted sweeper over the same log expires nothing twice" do
    run_id = "run-sw-#{System.unique_integer([:positive])}"
    call = request!(run_id, "r")
    now = call.requested_at_ms + @timeout
    Sweeper.sweep(sweeper(now))
    await_projection("ToolCallExpired", :tool_call_id, "r")
    Sweeper.sweep(sweeper(now))
    assert events(ToolCall.stream_id(run_id, "r")) == ["ToolCallRequested", "ToolCallExpired"]
  end

  test "an open question past its own timeout expires; the answer afterwards is rejected" do
    run_id = "global"
    qid = "q-sw-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "question.open",
        command_id: "question-open:#{qid}",
        aggregate_id: OperatorQuestion.stream_id(run_id, qid),
        payload: %{run_id: run_id, question_id: qid, timeout_ms: 1_000, text: "ok?"}
      })

    await_projection("QuestionOpened", :question_id, qid)
    q = ProjectionStore.question(run_id, qid)
    Sweeper.sweep(sweeper(q.opened_at_ms + 1_000))
    await_projection("QuestionExpired", :question_id, qid)

    assert {:error, {:question_not_open, "expired"}} =
             CommandGateway.dispatch_operator(%{
               type: "question.answer",
               command_id: "op-ans-#{qid}",
               aggregate_id: OperatorQuestion.stream_id(run_id, qid),
               payload: %{run_id: run_id, question_id: qid, text: "late"}
             })
  end

  describe "a question that expires while the server is down" do
    # Real path end to end: the project, run, optional pause and question are created
    # through real commands (aggregates, event store). The restart is
    # `ProjectionStoreReset.reset!(keep_subscribers: true)` + `ProjectionStore.rebuild([])`,
    # so the read model holds only what the event log folds back. A freshly started
    # Sweeper's boot sweep (`handle_continue(:recover)`) then has to find the question in
    # that rebuilt projection. "Server down" is modelled by the injected clock being past
    # the deadline when that sweeper starts; the earlier pre-deadline sweeper is stopped.
    setup do
      on_exit(&ProjectionStoreReset.reset!/0)
      :ok
    end

    for on_timeout <- [:surface, :deny], paused? <- [false, true] do
      test "is expired exactly once by the boot sweep, shown as waiting on you (on_timeout #{on_timeout}, paused #{paused?})" do
        on_timeout = unquote(on_timeout)
        paused? = unquote(paused?)
        tag = System.unique_integer([:positive])
        project = "p-sw-#{tag}"
        run_id = "run-swq-#{tag}"
        qid = "q-swq-#{tag}"
        stream = OperatorQuestion.stream_id(run_id, qid)
        Process.register(self(), :sweeper_test_probe)
        gateway = ForemanServer.Approvals.SweeperTest.RecordingGateway

        start_run!(project, run_id)
        if paused?, do: pause!(run_id)

        {:ok, _} =
          CommandGateway.dispatch_system(%{
            type: "question.open",
            command_id: "question-open:#{qid}",
            aggregate_id: stream,
            payload: %{
              run_id: run_id,
              question_id: qid,
              project_id: project,
              timeout_ms: 1_000,
              text: "which database?"
            }
          })

        await_projection("QuestionOpened", :question_id, qid)

        # Restart: wipe the read model and rebuild it from the event log alone.
        :ok = ProjectionStoreReset.reset!(keep_subscribers: true)
        :ok = ProjectionStore.rebuild([])
        assert %{status: "open"} = q = ProjectionStore.question(run_id, qid)
        deadline = q.opened_at_ms + 1_000

        # One ms before the deadline: nothing is expired early.
        early = sweeper(deadline - 1, on_timeout: on_timeout, gateway: gateway)
        Sweeper.sweep(early)
        assert events(stream) == ["QuestionOpened"]
        stop_supervised!(early)

        # Boot sweep after the deadline: no explicit sweep call, only the startup sweep.
        _boot = sweeper(deadline, on_timeout: on_timeout, gateway: gateway)

        Eventually.await(fn -> events(stream) == ["QuestionOpened", "QuestionExpired"] end,
          message: "boot sweep expires the overdue question"
        )

        # The sweeper dispatched with the deterministic id, not a random one.
        assert_receive {:dispatched,
                        %{type: "question.expire", command_id: command_id, aggregate_id: ^stream}}

        assert command_id == "expire:question:#{run_id}:#{qid}"

        # Another restart sweeper and manual sweeps add nothing.
        again = sweeper(deadline, on_timeout: on_timeout, gateway: gateway)
        Sweeper.sweep(again)
        Sweeper.sweep(again)
        assert events(stream) == ["QuestionOpened", "QuestionExpired"]

        Eventually.await(fn ->
          match?(%{status: "expired"}, ProjectionStore.question(run_id, qid))
        end)

        # The thread waits on the operator with reason :question_expired.
        {:ok, overview} = Overview.build(project)

        assert Enum.any?(
                 overview.groups.waiting_on_you,
                 &(&1.thread_id == "run:#{run_id}" and &1.reason == :question_expired)
               )

        # Not asked again silently: no question is open for the project.
        assert ProjectionStore.open_questions(project) == []
      end
    end

    test "a second question.expire with a fresh command id is rejected and appends nothing" do
      tag = System.unique_integer([:positive])
      run_id = "run-swg-#{tag}"
      qid = "q-swg-#{tag}"
      stream = OperatorQuestion.stream_id(run_id, qid)

      {:ok, _} =
        CommandGateway.dispatch_system(%{
          type: "question.open",
          command_id: "question-open:#{qid}",
          aggregate_id: stream,
          payload: %{run_id: run_id, question_id: qid, timeout_ms: 1_000, text: "ok?"}
        })

      await_projection("QuestionOpened", :question_id, qid)
      q = ProjectionStore.question(run_id, qid)
      Sweeper.sweep(sweeper(q.opened_at_ms + 1_000))
      Eventually.await(fn -> events(stream) == ["QuestionOpened", "QuestionExpired"] end)

      assert {:error, {:question_not_open, "expired"}} =
               CommandGateway.dispatch_system(%{
                 type: "question.expire",
                 command_id: "fresh-#{tag}",
                 aggregate_id: stream,
                 payload: %{run_id: run_id, question_id: qid, reason: "timeout"}
               })

      assert events(stream) == ["QuestionOpened", "QuestionExpired"]
    end
  end
end
