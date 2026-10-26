defmodule ForemanServer.Agents.OperatorTimeoutTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.Agents.OperatorTimeout
  alias ForemanServer.Aggregates.OperatorQuestion
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.TelemetryTest.Handler, as: TelemetryHandler
  alias ForemanServer.TestSupport.Eventually
  alias ForemanServer.{CommandGateway, ProjectionStore}

  # OperatorTimeout is part of the application tree under test
  # (config/test.exs enables :operator_timeout), so it is already running.

  # The policy's gateway, when the timer's `:gateway` option names one: records the command it is
  # handed (in the calling process) and refuses it.
  defmodule RefusingGateway do
    @moduledoc false
    def dispatch_system(command) do
      send(self(), {:dispatched, command})
      {:error, :boom}
    end
  end

  test "schedule and cancel" do
    assert :ok = OperatorTimeout.schedule("wf-1", "task-1", 60_000)
    assert :ok = OperatorTimeout.cancel("wf-1", "task-1")
  end

  test "cancel of unknown id is a no-op" do
    assert :ok = OperatorTimeout.cancel("wf-x", "task-x")
  end

  describe "when the deadline fires" do
    setup do
      :ok = ProjectionStore.subscribe(replay_existing: false)
    end

    test "an open question is expired once, by the timer it was scheduled with" do
      {run_id, question_id, agent_id} = open_question!()

      assert :ok = OperatorTimeout.schedule(question_id, agent_id, 1)

      assert %{reason: "timeout"} = await_event("QuestionExpired", question_id)

      assert %{status: "expired", reason: "timeout"} =
               ProjectionStore.question(run_id, question_id)

      assert event_types(run_id, question_id) == ["QuestionOpened", "QuestionExpired"]

      # A second expiry for the same question (a duplicate timer, or the sweeper racing this
      # one) finds nothing open: no command reaches the question, and it is recorded once.
      assert [] = dispatches_to(question_id, fn -> expire_now(question_id, agent_id) end)
      assert event_types(run_id, question_id) == ["QuestionOpened", "QuestionExpired"]
    end

    test "the expiry is the question.expire command for that question, and a refusal is logged" do
      {run_id, question_id, agent_id} = open_question!()

      log =
        capture_log(fn ->
          assert {:noreply, _state} =
                   OperatorTimeout.handle_info(
                     {:expire, question_id, agent_id},
                     %{policy_opts: [gateway: RefusingGateway]}
                   )
        end)

      assert_received {:dispatched, command}

      assert command == %{
               type: "question.expire",
               command_id: "expire:question:#{run_id}:#{question_id}",
               aggregate_id: "question:#{run_id}:#{question_id}",
               payload: %{run_id: run_id, question_id: question_id, reason: "timeout"}
             }

      refute_received {:dispatched, _another}

      assert log =~
               "Operator timeout for question=#{question_id} agent=#{agent_id} could not expire it: :boom"

      assert event_types(run_id, question_id) == ["QuestionOpened"]
    end

    test "a question answered in time is left alone: nothing is dispatched to it" do
      {run_id, question_id, agent_id} = open_question!()

      {:ok, _} =
        CommandGateway.dispatch_operator(%{
          type: "question.answer",
          command_id: "answer:" <> question_id,
          aggregate_id: OperatorQuestion.stream_id(run_id, question_id),
          payload: %{run_id: run_id, question_id: question_id, text: "use postgres"}
        })

      await_event("QuestionAnswered", question_id)
      timeout_pid = Process.whereis(OperatorTimeout)

      assert [] = dispatches_to(question_id, fn -> expire_now(question_id, agent_id) end)

      assert Process.whereis(OperatorTimeout) == timeout_pid
      assert %{status: "answered"} = ProjectionStore.question(run_id, question_id)
      assert event_types(run_id, question_id) == ["QuestionOpened", "QuestionAnswered"]
    end

    test "a question that was never opened is ignored, and the timer survives it" do
      timeout_pid = Process.whereis(OperatorTimeout)
      question_id = "q-never-opened-#{System.unique_integer([:positive])}"

      assert [] = dispatches_to(question_id, fn -> expire_now(question_id, "agent-ghost") end)

      assert Process.whereis(OperatorTimeout) == timeout_pid
    end
  end

  # A question the way the operator-question dispatcher opens one for an agent that has no run.
  defp open_question! do
    n = System.unique_integer([:positive])
    run_id = OperatorQuestion.global_run()
    question_id = "q-timeout-#{n}"

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "question.open",
        command_id: "question-open:" <> question_id,
        aggregate_id: OperatorQuestion.stream_id(run_id, question_id),
        payload: %{
          run_id: run_id,
          question_id: question_id,
          agent_id: "agent-timeout-#{n}",
          text: "which database?",
          timeout_ms: 300_000
        }
      })

    Eventually.await(fn -> ProjectionStore.open_question_by_id(question_id) end,
      message: "question #{question_id} never became open in the projection"
    )

    {run_id, question_id, "agent-timeout-#{n}"}
  end

  # What the timer sends when it fires, then a barrier: OperatorTimeout has handled it (and every
  # command it dispatched has been sent) once `:sys.get_state/1` answers.
  defp expire_now(question_id, agent_id) do
    pid = Process.whereis(OperatorTimeout)
    send(pid, {:expire, question_id, agent_id})
    _ = :sys.get_state(pid)
    :ok
  end

  # The commands `fun` sent to `question_id`'s aggregate, seen at the command router. The handler
  # runs in the dispatching process, so after the barrier in `fun` they are all in the mailbox.
  defp dispatches_to(question_id, fun) do
    {handler_id, ref} =
      TelemetryHandler.attach_event_handlers(self(), [[:foreman, :command, :dispatch]])

    try do
      :ok = fun.()
      drain_dispatches(ref, question_id, [])
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_dispatches(ref, question_id, acc) do
    receive do
      {[:foreman, :command, :dispatch], ^ref, _measurements, %{aggregate_id: aggregate_id}} ->
        if String.ends_with?(aggregate_id, ":" <> question_id),
          do: drain_dispatches(ref, question_id, [aggregate_id | acc]),
          else: drain_dispatches(ref, question_id, acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp event_types(run_id, question_id) do
    {:ok, events} =
      Store.read_stream_forward(OperatorQuestion.stream_id(run_id, question_id), 0, 100)

    Enum.map(events, & &1.event_type)
  end

  defp await_event(type, question_id) do
    receive do
      {:projection_event, %{event_type: ^type, data: data}} ->
        data = if is_struct(data), do: Map.from_struct(data), else: data

        if Map.get(data, :question_id) == question_id,
          do: data,
          else: await_event(type, question_id)

      {:projection_event, _other} ->
        await_event(type, question_id)
    after
      15_000 -> flunk("timed out waiting for #{type} on #{question_id}")
    end
  end
end
