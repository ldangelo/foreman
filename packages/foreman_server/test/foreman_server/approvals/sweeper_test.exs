defmodule ForemanServer.Approvals.SweeperTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.{OperatorQuestion, ToolCall}
  alias ForemanServer.Approvals.{Requester, Sweeper}
  alias ForemanServer.{CommandGateway, EventStore, ProjectionStore}

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

  test "a call exactly at the timeout is expired once; a younger one and an approved one are untouched" do
    run_id = "run-sw-#{System.unique_integer([:positive])}"
    old = request!(run_id, "old")
    young = request!(run_id, "young")
    # young is 1ms short of the timeout, old is exactly at it
    now = old.requested_at_ms + @timeout
    assert young.requested_at_ms >= old.requested_at_ms

    server = sweeper(now)
    Sweeper.sweep(server)
    await_projection("ToolCallExpired", :tool_call_id, "old")
    Sweeper.sweep(server)

    assert events(ToolCall.stream_id(run_id, "old")) == ["ToolCallRequested", "ToolCallExpired"]
    assert %{status: "expired"} = ProjectionStore.tool_call(run_id, "old")

    if young.requested_at_ms + @timeout > now,
      do: assert(%{status: "requested"} = ProjectionStore.tool_call(run_id, "young"))
  end

  test "an expired call can no longer be approved" do
    run_id = "run-sw-#{System.unique_integer([:positive])}"
    call = request!(run_id, "c")
    Sweeper.sweep(sweeper(call.requested_at_ms + @timeout))
    await_projection("ToolCallExpired", :tool_call_id, "c")

    assert {:error, {:tool_call_terminal, "expired"}} =
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
end
