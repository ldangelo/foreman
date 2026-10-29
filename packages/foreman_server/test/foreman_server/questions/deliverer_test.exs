defmodule ForemanServer.Questions.DelivererTest do
  @moduledoc """
  `Questions.Deliverer`: an operator's answer reaches the agent that asked, exactly once.

  A question of a workflow run is delivered as an idempotent `run.steer` (and the paused run
  is resumed); a question of no run is published on the operator reply topic; a delivery that
  fails is logged and reported `{:failed, reason}`, never `:delivered`; an answer recorded while
  the deliverer was down is recovered. The end-to-end tests go through the real gateway,
  aggregates and projection; the command-shape and failure tests hand the deliverer a recording
  gateway through its `:gateway` option.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.Agents.JidoSignalTopics
  alias ForemanServer.Aggregates.OperatorQuestion
  alias ForemanServer.Aggregates.Run
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Questions.Deliverer
  alias ForemanServer.TestSupport.{Eventually, ProjectionStoreReset, UniqueIds}
  alias ForemanServer.{CommandGateway, CommandRouter, ProjectionStore}

  # Gateways the deliverer's `:gateway` option can name; each tells the test what it was handed.
  defmodule RecordingGateway do
    @moduledoc false
    def dispatch_system(command) do
      send(Process.whereis(:questions_deliverer_test), {:dispatched, command})
      {:ok, nil}
    end
  end

  defmodule SteerRefusingGateway do
    @moduledoc false
    def dispatch_system(command) do
      send(Process.whereis(:questions_deliverer_test), {:dispatched, command})
      {:error, :steer_refused}
    end
  end

  defmodule ResumeRefusingGateway do
    @moduledoc false
    def dispatch_system(%{type: "run.resume"} = command) do
      send(Process.whereis(:questions_deliverer_test), {:dispatched, command})
      {:error, :resume_refused}
    end

    def dispatch_system(command) do
      send(Process.whereis(:questions_deliverer_test), {:dispatched, command})
      {:ok, nil}
    end
  end

  # The real dispatcher's reaction to a steer of a RUNNING run, folded into the read model
  # before the steer returns: the message is queued and the run is paused for it (the
  # dispatcher resumes it by itself).
  defmodule SteerPausesRunGateway do
    @moduledoc false
    def dispatch_system(
          %{type: "run.steer", payload: %{run_id: run_id, message_id: message_id}} = command
        ) do
      send(Process.whereis(:questions_deliverer_test), {:dispatched, command})

      :ok =
        ForemanServer.ProjectionStore.apply_events([
          %{
            event_type: "RunSteerQueued",
            payload: %{run_id: run_id, message_id: message_id, text: "answer"}
          },
          %{event_type: "RunPaused", payload: %{run_id: run_id}}
        ])

      {:ok, nil}
    end

    def dispatch_system(command) do
      send(Process.whereis(:questions_deliverer_test), {:dispatched, command})
      {:ok, nil}
    end
  end

  # The real gateway, except that the FIRST `run.resume` kills the calling process: the
  # deliverer dies after the answer was queued and before the paused run was resumed (the
  # supervisor restarts it, and its startup recovery must finish the delivery).
  defmodule DiesBeforeResumeGateway do
    @moduledoc false
    def dispatch_system(%{type: "run.resume"} = command) do
      if Agent.get_and_update(:questions_deliverer_test_died, &{&1, true}),
        do: ForemanServer.CommandGateway.dispatch_system(command),
        else: exit(:deliverer_died_before_resume)
    end

    def dispatch_system(command), do: ForemanServer.CommandGateway.dispatch_system(command)
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_signal)
    :ok
  end

  setup do
    Process.register(self(), :questions_deliverer_test)
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok = ProjectionStore.subscribe(replay_existing: false)
  end

  describe "a question of a workflow run (real gateway)" do
    test "the answer is queued as a steering message and the paused run is resumed with it" do
      start_deliverer!()
      {project_id, run_id} = start_run!()
      pause!(run_id)
      question_id = open_question!(run_id, project_id)

      answer!(run_id, question_id, "use postgres")

      steer = await("RunSteerQueued", run_id)
      assert field(steer, :message_id) == "question:" <> question_id
      assert field(steer, :text) == "Answer to your question #{question_id}: use postgres"
      assert field(steer, :steered_by) == "question"
      assert field(steer, :resume) == true

      await("RunResumed", run_id, &(field(&1, :reason) == "question_answered"))
    end

    test "a repeated QuestionAnswered event is delivered once" do
      deliverer = start_deliverer!()
      {project_id, run_id} = start_run!()
      pause!(run_id)
      question_id = open_question!(run_id, project_id)
      answer!(run_id, question_id, "use postgres")

      await("RunSteerQueued", run_id)
      await("RunResumed", run_id, &(field(&1, :reason) == "question_answered"))

      send(
        deliverer,
        {:projection_event,
         %{
           event_type: "QuestionAnswered",
           data: %{run_id: run_id, question_id: question_id, text: "use postgres"}
         }}
      )

      _ = :sys.get_state(deliverer)

      assert [_once] =
               for(
                 data <- run_events(run_id, "RunSteerQueued"),
                 field(data, :message_id) == "question:" <> question_id,
                 do: data
               )

      assert [_once] =
               for(
                 data <- run_events(run_id, "RunResumed"),
                 field(data, :reason) == "question_answered",
                 do: data
               )
    end
  end

  # An answer reaches a run as a `run.steer` message and a steer is capped, so the limit on an
  # answer is what the cap leaves after the delivery prefix. 8000 characters used to be accepted
  # by `question.answer` and then refused by the steer: recorded, never delivered, nobody told.
  describe "the answer length limit" do
    test "the longest answer is delivered whole, as a steering message that fills the cap exactly" do
      start_deliverer!()
      {project_id, run_id} = start_run!()
      pause!(run_id)
      question_id = open_question!(run_id, project_id)
      prefix = "Answer to your question #{question_id}: "
      answer = String.duplicate("a", Run.steer_text_max_chars() - String.length(prefix))

      answer!(run_id, question_id, answer)

      steer = await("RunSteerQueued", run_id)
      assert field(steer, :text) == prefix <> answer
      assert String.length(field(steer, :text)) == Run.steer_text_max_chars()
      await("RunResumed", run_id, &(field(&1, :reason) == "question_answered"))
    end

    test "one character more is refused at question.answer, naming the limit: nothing is recorded or steered and a shorter answer still works" do
      start_deliverer!()
      {project_id, run_id} = start_run!()
      pause!(run_id)
      question_id = open_question!(run_id, project_id)

      limit =
        Run.steer_text_max_chars() -
          String.length("Answer to your question #{question_id}: ")

      too_long = answer_command(run_id, question_id, String.duplicate("a", limit + 1))

      assert {:error, {:answer_too_long, over, ^limit}} =
               CommandGateway.dispatch_operator(%{
                 too_long
                 | command_id: "too-long:" <> question_id
               })

      assert over == limit + 1
      assert %{status: "open"} = ProjectionStore.question(run_id, question_id)

      assert [%{event_type: "QuestionOpened"}] =
               stream_events(OperatorQuestion.stream_id(run_id, question_id))

      assert run_events(run_id, "RunSteerQueued") == []

      answer!(run_id, question_id, "use postgres")
      steer = await("RunSteerQueued", run_id)
      assert field(steer, :text) == "Answer to your question #{question_id}: use postgres"
    end

    # Whatever the asker's own question id (it is in the prefix, and unbounded), the longest answer
    # `question.answer` takes is one the run aggregate takes as the steer the deliverer sends.
    for {label, question_id} <- [
          short: "q1",
          uuid: "q-6f1c2d9e-3b7a-4c58-9a10-2e8d5b7c4f31",
          multibyte: String.duplicate("日", 40),
          emoji: String.duplicate("👨‍👩‍👧‍👦", 10),
          very_long: String.duplicate("x", 3_000)
        ] do
      test "the steer sent for the longest answer to a #{label} question id is accepted by the run aggregate" do
        question_id = unquote(question_id)
        run_id = projected_run(:running)
        # multibyte on purpose: both limits count characters, not bytes
        answer = String.duplicate("é", OperatorQuestion.max_answer_chars(question_id))
        assert answer != ""

        open =
          OperatorQuestion.apply_event(OperatorQuestion.initial_state(), %{
            event_type: "QuestionOpened",
            payload: %{}
          })

        assert {:ok, %{event_type: "QuestionAnswered"}} =
                 OperatorQuestion.handle_command(
                   open,
                   answer_command(run_id, question_id, answer)
                 )

        assert :delivered =
                 Deliverer.deliver(run_id, question_id, answer, gateway: RecordingGateway)

        assert_received {:dispatched, %{type: "run.steer", payload: payload}}

        started =
          Run.apply_event(Run.initial_state(), %{
            event_type: "RunStarted",
            payload: %{run_id: run_id, task_id: "t", project_id: "p"}
          })

        assert {:ok, %{event_type: "RunSteerQueued"}} =
                 Run.handle_command(started, %{type: "run.steer", payload: payload})
      end
    end
  end

  describe "the commands the deliverer sends" do
    test "a running run is steered with the answer and left running" do
      run_id = projected_run(:running)

      assert :delivered = Deliverer.deliver(run_id, "q-run", "yes", gateway: RecordingGateway)

      assert_received {:dispatched, command}

      assert command == %{
               type: "run.steer",
               command_id: "question-steer:#{run_id}:q-run",
               aggregate_id: "run:" <> run_id,
               payload: %{
                 run_id: run_id,
                 message_id: "question:q-run",
                 text: "Answer to your question q-run: yes",
                 steered_by: "question",
                 resume: true
               }
             }

      refute_received {:dispatched, _resume}
    end

    test "a paused run holding the answer is steered, then resumed with the reason question_answered" do
      run_id = projected_run(:paused, "q-paused")

      assert :delivered = Deliverer.deliver(run_id, "q-paused", "yes", gateway: RecordingGateway)

      assert_received {:dispatched, %{type: "run.steer"}}
      assert_received {:dispatched, resume}

      assert resume == %{
               type: "run.resume",
               command_id: "question-resume:#{run_id}:q-paused",
               aggregate_id: "run:" <> run_id,
               payload: %{run_id: run_id, reason: "question_answered"}
             }

      refute_received {:dispatched, _another}
    end

    test "a paused run that no longer holds the answer is steered (a no-op) but not resumed" do
      run_id = projected_run(:paused)

      assert :delivered = Deliverer.deliver(run_id, "q-taken", "yes", gateway: RecordingGateway)

      assert_received {:dispatched, %{type: "run.steer"}}
      refute_received {:dispatched, _resume}
    end

    test "a run the dispatcher pauses for the steer is left to the dispatcher to resume" do
      run_id = projected_run(:running)

      assert :delivered =
               Deliverer.deliver(run_id, "q-race", "yes", gateway: SteerPausesRunGateway)

      assert_received {:dispatched, %{type: "run.steer"}}
      refute_received {:dispatched, _resume}
    end
  end

  describe "a question of no run" do
    test "the answer is published on the operator reply topic, naming the asking agent" do
      bus = start_bus!()
      start_deliverer!(bus: bus)
      question_id = open_question!(OperatorQuestion.global_run(), nil, "agent-7")

      answer!(OperatorQuestion.global_run(), question_id, "ship it", %{answered_by: "alice"})

      assert_receive {:signal, %Jido.Signal{} = signal}, 15_000
      assert signal.type == JidoSignalTopics.foreman_operator_reply()
      assert signal.source == "foreman.questions.deliverer"

      assert signal.data == %{
               "question_id" => question_id,
               "agent_id" => "agent-7",
               "answer" => "ship it",
               "answered_by" => "alice"
             }
    end

    test "the supervised signal bus is the default" do
      {:ok, subscription} =
        Jido.Signal.Bus.subscribe(
          :foreman_jido_signal_bus,
          JidoSignalTopics.foreman_operator_reply(),
          dispatch: {:pid, target: self()}
        )

      on_exit(fn -> Jido.Signal.Bus.unsubscribe(:foreman_jido_signal_bus, subscription) end)

      assert :delivered = Deliverer.deliver("global", "q-default-bus", "on the default bus")

      assert_receive {:signal, %Jido.Signal{data: %{"question_id" => "q-default-bus"} = data}},
                     15_000

      assert data["answer"] == "on the default bus"
    end
  end

  describe "a delivery that fails" do
    test "a refused steer is logged and reported failed, and the run is not resumed" do
      run_id = projected_run(:paused)

      log =
        capture_log(fn ->
          assert {:failed, :steer_refused} =
                   Deliverer.deliver(run_id, "q-1", "x", gateway: SteerRefusingGateway)
        end)

      assert log =~ "questions: answer to q-1 was not delivered: :steer_refused"
      assert_received {:dispatched, %{type: "run.steer"}}
      refute_received {:dispatched, _resume}
    end

    test "a refused resume is logged and reported failed" do
      run_id = projected_run(:paused, "q-2")

      log =
        capture_log(fn ->
          assert {:failed, :resume_refused} =
                   Deliverer.deliver(run_id, "q-2", "x", gateway: ResumeRefusingGateway)
        end)

      assert log =~ "questions: answer to q-2 was not delivered: :resume_refused"
      assert_received {:dispatched, %{type: "run.steer"}}
      assert_received {:dispatched, %{type: "run.resume"}}
    end

    test "a run that already ended refuses the steer; the answer is not reported delivered" do
      {_project_id, run_id} = start_run!()

      {:ok, _} =
        CommandGateway.dispatch_operator(%{
          type: "run.cancel",
          command_id: "cancel:" <> run_id,
          aggregate_id: "run:" <> run_id,
          payload: %{run_id: run_id}
        })

      log =
        capture_log(fn ->
          assert {:failed, {:run_terminal, "cancelled"}} =
                   Deliverer.deliver(run_id, "q-3", "too late")
        end)

      assert log =~ "questions: answer to q-3 was not delivered: {:run_terminal, \"cancelled\"}"
    end

    test "an unreachable signal bus is logged and reported failed" do
      log =
        capture_log(fn ->
          assert {:failed, :not_found} =
                   Deliverer.deliver("global", "q-4", "x", bus: :no_such_signal_bus)
        end)

      assert log =~ "questions: answer to q-4 was not delivered: :not_found"
    end
  end

  describe "the projection subscription" do
    test "only QuestionAnswered is delivered; a malformed one is dropped and logged" do
      run_id = projected_run(:running)
      deliverer = start_deliverer!(gateway: RecordingGateway)

      for type <- ~w(QuestionOpened QuestionExpired RunSteerQueued) do
        send(
          deliverer,
          {:projection_event,
           %{
             event_type: type,
             data: %{run_id: run_id, question_id: "q-x", text: "not an answer"}
           }}
        )
      end

      _ = :sys.get_state(deliverer)
      refute_received {:dispatched, _}

      log =
        capture_log(fn ->
          send(
            deliverer,
            {:projection_event,
             %{
               event_type: "QuestionAnswered",
               data: %{run_id: run_id, question_id: "q-x", text: nil}
             }}
          )

          _ = :sys.get_state(deliverer)
        end)

      assert log =~ "questions: malformed QuestionAnswered event dropped"
      refute_received {:dispatched, _}

      send(
        deliverer,
        {:projection_event,
         %{
           event_type: "QuestionAnswered",
           data: %{run_id: run_id, question_id: "q-x", text: "go", answered_by: "alice"}
         }}
      )

      _ = :sys.get_state(deliverer)

      assert_received {:dispatched, %{type: "run.steer", payload: %{message_id: "question:q-x"}}}
    end
  end

  describe "recovery" do
    test "recover/1 re-delivers the answers of runs that have not ended, reading the text back from the event" do
      {project_id, paused_run} = start_run!()
      pause!(paused_run)
      paused_question = open_question!(paused_run, project_id)
      answer!(paused_run, paused_question, "use postgres")

      {other_project, running_run} = start_run!()
      running_question = open_question!(running_run, other_project)
      answer!(running_run, running_question, "use mysql")

      Eventually.await(fn -> length(ProjectionStore.answered_questions()) == 2 end,
        message: "both answers never reached the projection"
      )

      assert Deliverer.recover([]) == 2

      assert [paused_steer] = run_events(paused_run, "RunSteerQueued")

      assert field(paused_steer, :text) ==
               "Answer to your question #{paused_question}: use postgres"

      assert [running_steer] = run_events(running_run, "RunSteerQueued")

      assert field(running_steer, :text) ==
               "Answer to your question #{running_question}: use mysql"

      # Idempotent: the steer commands have deterministic ids, so a second pass appends nothing.
      assert Deliverer.recover([]) == 2
      assert [_once] = run_events(paused_run, "RunSteerQueued")
      assert [_once] = run_events(running_run, "RunSteerQueued")
      assert [_once] = resumed_by_answer(paused_run)
    end

    test "an answer recorded while the deliverer was down is delivered when it starts" do
      {project_id, run_id} = start_run!()
      pause!(run_id)
      question_id = open_question!(run_id, project_id)
      answer!(run_id, question_id, "use postgres")

      Eventually.await(fn -> ProjectionStore.answered_questions() != [] end,
        message: "the answer never reached the projection"
      )

      start_deliverer!()

      steer = await("RunSteerQueued", run_id)
      assert field(steer, :message_id) == "question:" <> question_id
      assert field(steer, :text) == "Answer to your question #{question_id}: use postgres"
    end

    test "an answer recorded while the deliverer was down reaches a RUNNING run when it starts, once" do
      {project_id, run_id} = start_run!()
      question_id = open_question!(run_id, project_id)
      answer!(run_id, question_id, "use postgres")

      Eventually.await(fn -> ProjectionStore.answered_questions() != [] end,
        message: "the answer never reached the projection"
      )

      deliverer = start_deliverer!()
      _ = :sys.get_state(deliverer)

      assert [steer] = run_events(run_id, "RunSteerQueued")
      assert field(steer, :message_id) == "question:" <> question_id
      assert field(steer, :text) == "Answer to your question #{question_id}: use postgres"

      # A restart of the deliverer (or a second pass) delivers nothing more.
      assert Deliverer.recover([]) == 1
      assert [_once] = run_events(run_id, "RunSteerQueued")
    end

    test "a deliverer that died between the steer and the resume is restarted and resumes the run once" do
      {project_id, run_id} = start_run!()
      pause!(run_id)
      question_id = open_question!(run_id, project_id)

      start_supervised!(%{
        id: :questions_deliverer_test_died,
        start: {Agent, :start_link, [fn -> false end, [name: :questions_deliverer_test_died]]}
      })

      name = :questions_deliverer_test_dying
      start_supervised!({Deliverer, name: name, gateway: DiesBeforeResumeGateway}, id: name)
      first = Process.whereis(name)

      capture_log(fn ->
        answer!(run_id, question_id, "use postgres")
        await("RunResumed", run_id, &(field(&1, :reason) == "question_answered"))
      end)

      assert Process.whereis(name) != first
      assert [_once] = run_events(run_id, "RunSteerQueued")
      assert [_once] = resumed_by_answer(run_id)
    end

    test "an answer the run already took never resumes a run that is paused for another reason" do
      {project_id, run_id} = start_run!()
      question_id = open_question!(run_id, project_id)

      # The operator paused the run; the pause has nothing to do with the question.
      pause!(run_id, "operator")

      # In an earlier life the deliverer already queued the answer's steer and the run took it
      # (the run was running, so no `question-resume` was ever needed).
      take_steer!(run_id, "question:" <> question_id, "question-steer:#{run_id}:#{question_id}")
      answer!(run_id, question_id, "use postgres")

      Eventually.await(fn -> ProjectionStore.answered_questions() != [] end,
        message: "the answer never reached the projection"
      )

      assert Deliverer.recover([]) == 1

      assert %{status: "paused"} = ProjectionStore.run(run_id)
      assert run_events(run_id, "RunResumed") == []
      assert [_once] = run_events(run_id, "RunSteerQueued")
    end

    test "an answer to a run that has ended, or to a question of no run, is not retried at startup" do
      {project_id, ended_run} = start_run!()
      ended_question = open_question!(ended_run, project_id)
      answer!(ended_run, ended_question, "too late")

      {:ok, _} =
        CommandGateway.dispatch_system(%{
          type: "run.cancel",
          command_id: "test-cancel:" <> ended_run,
          aggregate_id: "run:" <> ended_run,
          payload: %{run_id: ended_run}
        })

      await("RunCancelled", ended_run)

      # No run: the reply goes to in-memory bus subscribers and has no durable delivery marker,
      # so replaying it would re-publish history to agents that already got their answer.
      bus_question = open_question!("global", project_id)
      answer!("global", bus_question, "go ahead")

      Eventually.await(fn -> length(ProjectionStore.answered_questions()) == 2 end,
        message: "both answers never reached the projection"
      )

      assert Deliverer.recover(bus: start_bus!()) == 0
      assert run_events(ended_run, "RunSteerQueued") == []
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp start_deliverer!(opts \\ []) do
    name = :"questions_deliverer_#{System.unique_integer([:positive])}"
    start_supervised!({Deliverer, Keyword.put(opts, :name, name)}, id: name)
    Process.whereis(name)
  end

  defp start_bus! do
    bus = :"questions_bus_#{System.unique_integer([:positive])}"
    start_supervised!({Jido.Signal.Bus, name: bus}, id: bus)

    {:ok, _subscription} =
      Jido.Signal.Bus.subscribe(bus, JidoSignalTopics.foreman_operator_reply(),
        dispatch: {:pid, target: self()}
      )

    bus
  end

  # A run that exists only in the read model: the deliverer asks the projection for its status.
  # `holds` is the question whose answer the run still has queued (what a real steer leaves
  # behind; the fake gateways apply nothing, so the test folds it).
  defp projected_run(status, holds \\ nil) do
    run_id = UniqueIds.unique_run_id("qd")

    started = %{
      event_type: "RunStarted",
      payload: %{run_id: run_id, task_id: "t-" <> run_id, project_id: "p-qd"}
    }

    paused = %{event_type: "RunPaused", payload: %{run_id: run_id}}

    queued = %{
      event_type: "RunSteerQueued",
      payload: %{run_id: run_id, message_id: "question:" <> to_string(holds), text: "answer"}
    }

    events =
      case {status, holds} do
        {:paused, nil} -> [started, paused]
        {:paused, _question} -> [started, paused, queued]
        {:running, nil} -> [started]
      end

    :ok = ProjectionStore.apply_events(events)

    run_id
  end

  defp start_run! do
    n = System.unique_integer([:positive])
    project_id = "p-#{n}"
    run_id = "run-#{n}"

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

  defp pause!(run_id, reason \\ "awaiting_answer") do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.pause",
        command_id: "test-pause:#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{run_id: run_id, reason: reason}
      })

    await("RunPaused", run_id)
  end

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
          text: "answered",
          steered_by: "question",
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

  defp resumed_by_answer(run_id),
    do:
      for(
        data <- run_events(run_id, "RunResumed"),
        field(data, :reason) == "question_answered",
        do: data
      )

  defp open_question!(run_id, project_id, agent_id \\ "agent-qd") do
    question_id = "q-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "question.open",
        command_id: "open:" <> question_id,
        aggregate_id: OperatorQuestion.stream_id(run_id, question_id),
        payload: %{
          run_id: run_id,
          question_id: question_id,
          agent_id: agent_id,
          project_id: project_id,
          text: "which database?",
          timeout_ms: 300_000
        }
      })

    question_id
  end

  defp answer_command(run_id, question_id, text, extra \\ %{}) do
    %{
      type: "question.answer",
      command_id: "answer:" <> question_id,
      aggregate_id: OperatorQuestion.stream_id(run_id, question_id),
      payload: Map.merge(%{run_id: run_id, question_id: question_id, text: text}, extra)
    }
  end

  defp answer!(run_id, question_id, text, extra \\ %{}) do
    {:ok, _} =
      CommandGateway.dispatch_operator(answer_command(run_id, question_id, text, extra))
  end

  defp stream_events(stream) do
    {:ok, events} = Store.read_stream_forward(stream, 0, 1_000)
    events
  end

  defp run_events(run_id, type) do
    {:ok, events} = Store.read_stream_forward("run:" <> run_id, 0, 1_000)
    for %{event_type: ^type, data: data} <- events, do: data
  end

  defp field(data, key) do
    data = if is_struct(data), do: Map.from_struct(data), else: data
    Map.get(data, key, Map.get(data, to_string(key)))
  end

  # The data of the first `type` event of `run_id` (matching `match`) the projection broadcasts.
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
