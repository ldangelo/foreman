defmodule ForemanServer.Questions.RestartDurabilityTest do
  @moduledoc """
  Human waits survive a restart and are answered exactly once (PRD AC-003-1 to AC-003-3).

  A "restart" here is what a server restart does to the question state, with nothing mocked:
  every aggregate actor involved is killed (the next command rehydrates it from the event
  stream), the read model is wiped and rebuilt from the committed event log
  (`ProjectionStore.rebuild/1`). No `Questions.Deliverer` runs by default in the test
  environment (`start_children` is false), so the tests that need one start a fresh one after
  the restart.
  What it does not do is restart the BEAM or the Postgres event store: the event log is the one
  thing that is carried over, as it is in production.

  Each test pins one guard, so removing one guard turns exactly its test red:

    * the question is still pending and listed after the restart (the projection fold of
      `QuestionOpened`),
    * the same `command_id` repeated after the restart is a replay and appends nothing (the
      actor's `command_id` dedupe),
    * a different `command_id` on an answered question is refused as not open (the aggregate's
      `require_open` guard),
    * only the answered question's run is resumed, once (`Questions.Deliverer`).
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Aggregate.Actor
  alias ForemanServer.Aggregates.OperatorQuestion
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Questions.Deliverer
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.{CommandGateway, CommandRouter, ProjectionStore}

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok = ProjectionStore.subscribe(replay_existing: false)
  end

  test "a question left unanswered across a restart is still pending, and listed" do
    {project_id, run_id} = start_run!()
    question_id = open_question!(run_id, project_id)
    assert [%{question_id: ^question_id}] = ProjectionStore.open_questions(project_id)

    restart!([OperatorQuestion.stream_id(run_id, question_id), "run:" <> run_id])

    assert [%{question_id: ^question_id, run_id: ^run_id, status: "open"}] =
             ProjectionStore.open_questions(project_id)

    assert [] = Enum.filter(ProjectionStore.answered_questions(), &(&1.run_id == run_id))

    # The aggregate agrees with the read model: the rehydrated question is open, so it can be
    # answered, once.
    assert {:ok, _} = answer(run_id, question_id, "use postgres", "answer:" <> question_id)

    assert ["QuestionOpened", "QuestionAnswered"] =
             event_types(question_stream(run_id, question_id))
  end

  test "the same command_id repeated after a restart is the first result, marked replayed, and appends nothing" do
    {project_id, run_id} = start_run!()
    question_id = open_question!(run_id, project_id)
    stream = question_stream(run_id, question_id)
    command_id = "answer:" <> question_id

    assert {:ok, first} = answer(run_id, question_id, "use postgres", command_id)
    refute Actor.replayed?(first)
    assert ["QuestionOpened", "QuestionAnswered"] = event_types(stream)

    restart!([stream, "run:" <> run_id])

    assert {:ok, again} = answer(run_id, question_id, "use postgres", command_id)
    assert Actor.replayed?(again)
    # Actor replies are event specs with string keys.
    assert again["event_type"] == "QuestionAnswered"
    assert again["payload"]["text"] == "use postgres"
    assert again["payload"]["at"] == first["payload"]["at"]

    assert ["QuestionOpened", "QuestionAnswered"] = event_types(stream)
  end

  test "a different command_id on an answered question is refused as not open, and records nothing" do
    {project_id, run_id} = start_run!()
    pause!(run_id)
    question_id = open_question!(run_id, project_id)
    stream = question_stream(run_id, question_id)

    deliverer = start_deliverer!()
    assert {:ok, _} = answer(run_id, question_id, "use postgres", "answer:" <> question_id)
    await("RunResumed", run_id, &(field(&1, :reason) == "question_answered"))

    # The delivery has returned (the run actor is no longer mid-call) before the restart.
    _ = :sys.get_state(deliverer)
    restart!([stream, "run:" <> run_id])

    assert {:error, {:question_not_open, "answered"}} =
             answer(run_id, question_id, "use mysql instead", "answer-again:" <> question_id)

    assert ["QuestionOpened", "QuestionAnswered"] = event_types(stream)
    assert [%{text: "use postgres"}] = answered_events(stream)

    # The run resumed once, for the first answer; the refused one resumed nothing more.
    assert [_once] = resumed_by_answer(run_id)
  end

  test "of two runs holding an open question across a restart, answering one resumes only that run, once" do
    {project_a, run_a} = start_run!()
    {project_b, run_b} = start_run!()
    pause!(run_a)
    pause!(run_b)
    question_a = open_question!(run_a, project_a)
    question_b = open_question!(run_b, project_b)

    restart!([
      OperatorQuestion.stream_id(run_a, question_a),
      OperatorQuestion.stream_id(run_b, question_b),
      "run:" <> run_a,
      "run:" <> run_b
    ])

    deliverer = start_deliverer!()

    assert {:ok, _} = answer(run_a, question_a, "use postgres", "answer:" <> question_a)
    await("RunResumed", run_a, &(field(&1, :reason) == "question_answered"))

    # The projection message was queued to the deliverer before `answer/4` returned, so this
    # drains it: nothing the deliverer would do for run_b can still be pending.
    _ = :sys.get_state(deliverer)
    assert [_once] = resumed_by_answer(run_a)
    assert [] = run_events(run_b, "RunResumed")
    assert [] = run_events(run_b, "RunSteerQueued")
    assert %{status: "paused"} = ProjectionStore.run(run_b)
    assert ["QuestionOpened"] = event_types(question_stream(run_b, question_b))

    # A second recovery pass (a further restart of the deliverer) resumes nothing more.
    _ = Deliverer.recover([])
    assert [_once] = resumed_by_answer(run_a)
    assert [] = run_events(run_b, "RunResumed")
  end

  # A server restart as far as question state is concerned: the aggregate actors of `streams`
  # die (the next command replays them from the event log), the read model is wiped and then
  # rebuilt from the committed log, exactly as `ProjectionStore.init/1` does at boot.
  defp restart!(streams) do
    for stream <- streams do
      [{pid, _}] = Registry.lookup(ForemanServer.AggregateRegistry, stream)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end

    :ok = ProjectionStoreReset.reset!(keep_subscribers: true)
    :ok = ProjectionStore.rebuild([])
  end

  defp start_deliverer! do
    name = :"restart_durability_deliverer_#{System.unique_integer([:positive])}"
    start_supervised!({Deliverer, name: name})
  end

  defp start_run! do
    n = System.unique_integer([:positive])
    project_id = "p-rd-#{n}"
    run_id = "run-rd-#{n}"

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
    {project_id, run_id}
  end

  defp pause!(run_id) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.pause",
        command_id: "test-pause:#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{run_id: run_id, reason: "awaiting_answer"}
      })

    await("RunPaused", run_id)
  end

  defp open_question!(run_id, project_id) do
    question_id = "q-rd-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "question.open",
        command_id: "open:" <> question_id,
        aggregate_id: question_stream(run_id, question_id),
        payload: %{
          run_id: run_id,
          question_id: question_id,
          agent_id: "agent-rd",
          project_id: project_id,
          text: "which database?",
          timeout_ms: 300_000
        }
      })

    await("QuestionOpened", run_id)
    question_id
  end

  defp answer(run_id, question_id, text, command_id) do
    CommandGateway.dispatch_operator(%{
      type: "question.answer",
      command_id: command_id,
      aggregate_id: question_stream(run_id, question_id),
      payload: %{run_id: run_id, question_id: question_id, text: text}
    })
  end

  defp question_stream(run_id, question_id), do: OperatorQuestion.stream_id(run_id, question_id)

  defp events(stream) do
    {:ok, events} = Store.read_stream_forward(stream, 0, 1_000)
    events
  end

  defp event_types(stream), do: Enum.map(events(stream), & &1.event_type)

  defp answered_events(stream),
    do: for(%{event_type: "QuestionAnswered", data: data} <- events(stream), do: data)

  defp run_events(run_id, type),
    do: for(%{event_type: ^type, data: data} <- events("run:" <> run_id), do: data)

  defp resumed_by_answer(run_id),
    do:
      Enum.filter(run_events(run_id, "RunResumed"), &(field(&1, :reason) == "question_answered"))

  # Stored and projected event data is atom-keyed (possibly a struct).
  defp field(data, key) do
    data = if is_struct(data), do: Map.from_struct(data), else: data
    Map.fetch!(data, key)
  end

  defp await(type, run_id, match \\ fn _data -> true end) do
    receive do
      {:projection_event, %{event_type: ^type, data: data}} ->
        if field(data, :run_id) == run_id and match.(data),
          do: data,
          else: await(type, run_id, match)

      {:projection_event, _other} ->
        await(type, run_id, match)
    after
      15_000 -> flunk("timed out waiting for #{type} on #{run_id}")
    end
  end
end
