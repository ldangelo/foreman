defmodule ForemanServerWeb.ProjectWorkspaceQuestionsLiveTest do
  # The workspace's answer form for an agent's operator question (bead foreman-exofh).
  # A question is opened through the real `question.open` command, the pane lists it, and
  # the submit is the operator's `question.answer` through `CommandGateway.dispatch_operator/1`:
  # the path `foreman questions answer` and `POST /api/commands` take. The aggregate, the
  # projection and (where a test says so) `Questions.Deliverer` are real; the dispatch is only
  # counted.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias ForemanServer.Aggregates.OperatorQuestion
  alias ForemanServer.Approvals.Dispatch
  alias ForemanServer.Questions.Deliverer
  alias ForemanServer.TelemetryTest.Handler
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.{CommandGateway, EventStore, ProjectionStore, ProjectStore}
  alias ForemanServerWeb.Workspace.Actions

  @endpoint ForemanServerWeb.Endpoint
  @token "project-workspace-questions-token"
  @xss "<script>alert('xss')</script>"

  setup do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    previous_ws = Application.get_env(:foreman_server, :workspace)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    Application.put_env(:foreman_server, :workspace, coalesce_ms: 20)
    ProjectionStoreReset.reset!()

    on_exit(fn ->
      ProjectionStoreReset.reset!()
      restore(:api_bearer_token, previous)
      restore(:workspace, previous_ws)
    end)

    :ok = ProjectionStore.subscribe(replay_existing: false)

    id = "qst-#{System.unique_integer([:positive])}"
    other = "qst-other-#{System.unique_integer([:positive])}"

    for p <- [id, other] do
      assert {:ok, _} = ProjectStore.save(%{project_id: p, path: "/tmp/#{p}", name: "Demo #{p}"})
    end

    {:ok, id: id, other: other, run: start_task_run!(id, "Pick a database")}
  end

  defp restore(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore(key, value), do: Application.put_env(:foreman_server, key, value)

  defp token, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  # A started run of `project_id` whose task is titled, so its thread card has a name.
  defp start_task_run!(project_id, title) do
    run = Support.start_run!(project_id: project_id)

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "TaskCreated",
          payload: %{
            task_id: run.task_id,
            project_id: project_id,
            title: title,
            status: "open",
            task_type: "implement"
          }
        }
      ])

    run
  end

  # What the agent side does: the system `question.open` that `OperatorQuestionDispatcher`
  # sends, so the aggregate and the projection hold a real open question.
  defp open_question!(project_id, run_id, opts \\ []) do
    question_id = Keyword.get(opts, :question_id, "q-" <> token())

    assert {:ok, _} =
             Dispatch.system(%{
               type: "question.open",
               command_id: "question-open:" <> question_id,
               aggregate_id: OperatorQuestion.stream_id(run_id, question_id),
               payload: %{
                 run_id: run_id,
                 question_id: question_id,
                 agent_id: Keyword.get(opts, :agent_id, "agent-" <> token()),
                 project_id: project_id,
                 text: Keyword.get(opts, :text, "Which database should I use?"),
                 timeout_ms: 300_000
               }
             })

    %{run_id: run_id, question_id: question_id}
  end

  defp expire_question!(q) do
    assert {:ok, _} =
             Dispatch.system(%{
               type: "question.expire",
               command_id: "question-expire:" <> q.question_id,
               aggregate_id: OperatorQuestion.stream_id(q.run_id, q.question_id),
               payload: %{run_id: q.run_id, question_id: q.question_id, reason: "timeout"}
             })
  end

  defp answer_command(q, command_id, payload) do
    %{
      type: "question.answer",
      command_id: command_id,
      aggregate_id: OperatorQuestion.stream_id(q.run_id, q.question_id),
      payload: Map.merge(%{run_id: q.run_id, question_id: q.question_id}, payload)
    }
  end

  # An answer posted from outside the view, exactly as `foreman questions answer` does it.
  defp answer_from_cli!(q, text) do
    assert {:ok, _} =
             CommandGateway.dispatch_operator(
               answer_command(q, "cli-answer-" <> q.question_id, %{text: text})
             )
  end

  # The operator dispatch of the workspace, counted and still executed: the real command
  # path, with every envelope reported to the test process as `{:dispatched, envelope}`.
  defp count_operator_dispatches! do
    test = self()
    {:ok, _} = Application.ensure_all_started(:meck)
    :meck.new(CommandGateway, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(CommandGateway) end)

    :meck.expect(CommandGateway, :dispatch_operator, fn envelope ->
      send(test, {:dispatched, envelope})
      :meck.passthrough([envelope])
    end)
  end

  defp events(q) do
    {:ok, events} =
      EventStore.read_stream_forward(OperatorQuestion.stream_id(q.run_id, q.question_id), 0, 100)

    events
  end

  defp event_types(q), do: q |> events() |> Enum.map(& &1.event_type)

  # The keys of an event's data: the shape both transports must agree on.
  defp fields(event), do: event.data |> Map.drop([:__struct__]) |> Map.keys() |> Enum.sort()

  defp card(q), do: "#question-#{q.run_id}-#{q.question_id}"
  defp answer_form(q), do: card(q) <> "-form"

  defp path(id), do: "/dashboard/projects/#{id}?token=#{@token}"

  # Attaches the refresh telemetry handler BEFORE the view mounts, so no refresh can
  # happen unobserved between a trigger and a later wait.
  defp mount_view(id) do
    {handler, ref} =
      Handler.attach_event_handlers(self(), [[:foreman_server, :workspace, :refresh]])

    Process.put(:refresh_ref, ref)
    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, view, html} = live(build_conn(), path(id))
    {view, html}
  end

  # Re-checks `fun.(html)` after every refresh of the view (and once up front) until it
  # holds; flunks after 5s. No sleeps.
  defp await_until(view, fun) do
    ref = Process.get(:refresh_ref)
    pid = view.pid
    html = render(view)

    if fun.(html) do
      html
    else
      receive do
        {[:foreman_server, :workspace, :refresh], ^ref, _m, %{pid: ^pid}} ->
          await_until(view, fun)
      after
        5_000 ->
          flunk(
            "condition not reached after a refresh; last html:\n" <> String.slice(html, 0, 600)
          )
      end
    end
  end

  defp await_element(view, selector),
    do: await_until(view, fn _ -> has_element?(view, selector) end)

  defp submit_event(view, q, text) do
    render_submit(view, "answer_question", %{
      "run_id" => q.run_id,
      "question_id" => q.question_id,
      "text" => text
    })
  end

  describe "the questions pane" do
    test "lists the project's open question with its text, asker and a labelled answer form",
         %{id: id, other: other, run: run} do
      q =
        open_question!(id, run.run_id, text: "Which database should I use?", agent_id: "agent-7")

      foreign_run = start_task_run!(other, "Elsewhere")
      foreign = open_question!(other, foreign_run.run_id, text: "Not for this project")

      {view, _html} = mount_view(id)

      assert has_element?(view, "#questions-pane h2", "Questions for you")
      assert has_element?(view, card(q), "Which database should I use?")
      assert has_element?(view, card(q), "asked by agent-7")
      assert has_element?(view, card(q), "run #{run.run_id}")

      # one form per question: a labelled, required textarea, the ids the command needs
      assert has_element?(view, "#{answer_form(q)} label", "Your answer")

      assert has_element?(
               view,
               "#{answer_form(q)} textarea[name=text][required][maxlength='8000']"
             )

      assert has_element?(view, "#{answer_form(q)} input[type=hidden][name=run_id]")
      assert has_element?(view, "#{answer_form(q)} input[type=hidden][name=question_id]")
      assert has_element?(view, "#{answer_form(q)} button[type=submit]", "Answer")

      refute has_element?(view, card(foreign))
      refute render(view) =~ "Not for this project"

      # the asking thread is waiting on the operator
      assert has_element?(view, "#group-waiting_on_you #thread-run\\:#{run.run_id}")
    end

    test "renders nothing when no question is open", %{id: id} do
      {view, _html} = mount_view(id)

      refute has_element?(view, "#questions-pane")
      refute render(view) =~ "Questions for you"
    end

    test "agent-authored text is escaped, never rendered as markup", %{id: id, run: run} do
      q =
        open_question!(id, run.run_id,
          text: @xss,
          agent_id: "<img src=x onerror=alert(1)>"
        )

      {view, html} = mount_view(id)
      html = html <> render(view)

      assert has_element?(view, card(q))
      assert html =~ "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"
      assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
      refute html =~ "<script>alert"
      refute html =~ "<img src=x"
    end

    test "a question outside any run is listed without a run and can be answered", %{id: id} do
      q = open_question!(id, OperatorQuestion.global_run(), text: "Which region?")

      {view, _html} = mount_view(id)

      assert has_element?(view, card(q), "Which region?")
      refute view |> element(card(q)) |> render() =~ "run global"

      view |> form(answer_form(q), %{"text" => "eu-west-1"}) |> render_submit()

      refute has_element?(view, card(q))
      assert event_types(q) == ["QuestionOpened", "QuestionAnswered"]
    end

    test "a question opened or answered outside the view arrives through the projection event",
         %{id: id, run: run} do
      {view, _html} = mount_view(id)
      refute has_element?(view, "#questions-pane")

      q = open_question!(id, run.run_id, text: "Opened while you watch")
      await_element(view, card(q))
      assert has_element?(view, card(q), "Opened while you watch")

      # the CLI / HTTP answer: the card disappears without any click in this view
      answer_from_cli!(q, "answered elsewhere")
      await_until(view, fn _ -> not has_element?(view, card(q)) end)

      refute has_element?(view, "#questions-pane")
    end
  end

  describe "answering" do
    test "sends question.answer once, records the typed text and removes the question",
         %{id: id, run: run} do
      # The projection event's refresh is made too slow to matter: the question is gone
      # because the handler re-read the state itself.
      Application.put_env(:foreman_server, :workspace, coalesce_ms: 60_000)
      q = open_question!(id, run.run_id, text: "Which database should I use?")
      {view, _html} = mount_view(id)
      assert has_element?(view, "#group-waiting_on_you #thread-run\\:#{run.run_id}")
      count_operator_dispatches!()

      html = view |> form(answer_form(q), %{"text" => "Use postgres."}) |> render_submit()

      # exactly one operator command, addressed to this question's stream
      stream = OperatorQuestion.stream_id(q.run_id, q.question_id)
      run_id = q.run_id
      question_id = q.question_id

      assert_received {:dispatched,
                       %{
                         type: "question.answer",
                         aggregate_id: ^stream,
                         payload: %{
                           run_id: ^run_id,
                           question_id: ^question_id,
                           text: "Use postgres.",
                           answered_by: "dashboard"
                         }
                       }}

      refute_received {:dispatched, _}

      # the state moved: notice, no question, the thread no longer waits on the operator
      assert html =~ "question.answer"
      assert has_element?(view, "#notice", "question.answer")
      refute has_element?(view, card(q))
      refute has_element?(view, "#questions-pane")
      assert has_element?(view, "#group-working #thread-run\\:#{run.run_id}")
      refute has_element?(view, "#group-waiting_on_you #thread-run\\:#{run.run_id}")

      assert %{status: "answered", answered_by: "dashboard"} =
               ProjectionStore.question(q.run_id, q.question_id)

      assert event_types(q) == ["QuestionOpened", "QuestionAnswered"]
      assert [_opened, answered] = events(q)
      assert Map.get(answered.data, :text) == "Use postgres."
    end

    test "a second submit of the same answer is refused and records nothing more",
         %{id: id, run: run} do
      q = open_question!(id, run.run_id)
      {view, _html} = mount_view(id)

      view |> form(answer_form(q), %{"text" => "Use postgres."}) |> render_submit()
      html = submit_event(view, q, "Use postgres.")

      assert html =~ "the question was already answered"
      assert Process.alive?(view.pid)
      assert event_types(q) == ["QuestionOpened", "QuestionAnswered"]
    end

    test "the UI and the HTTP command record the same event", %{id: id, run: run} do
      via_ui = open_question!(id, run.run_id, text: "Asked first")
      via_http = open_question!(id, run.run_id, text: "Asked second")
      {view, _html} = mount_view(id)

      view |> form(answer_form(via_ui), %{"text" => "Use postgres."}) |> render_submit()

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{@token}")
        |> post("/api/commands", %{
          "type" => "question.answer",
          "command_id" => "http-answer-" <> via_http.question_id,
          "payload" => %{
            "run_id" => via_http.run_id,
            "question_id" => via_http.question_id,
            "text" => "Use postgres."
          }
        })

      assert %{"status" => "accepted"} = json_response(conn, 201)

      [_, ui_event] = events(via_ui)
      [_, http_event] = events(via_http)

      assert ui_event.event_type == http_event.event_type
      assert fields(ui_event) == fields(http_event)
      assert Map.get(ui_event.data, :answered_by) == "dashboard"
      assert Map.get(http_event.data, :answered_by) == "operator"
      assert Map.get(ui_event.data, :text) == Map.get(http_event.data, :text)
    end

    test "the answer reaches the asking run as one steering message (Questions.Deliverer)",
         %{id: id, run: run} do
      start_supervised!({Deliverer, name: :"wsq_deliverer_#{System.unique_integer([:positive])}"})
      q = open_question!(id, run.run_id, text: "Which database should I use?")
      {view, _html} = mount_view(id)

      view |> form(answer_form(q), %{"text" => "Use postgres."}) |> render_submit()

      run_id = run.run_id

      assert_receive {:projection_event,
                      %{event_type: "RunSteerQueued", data: %{run_id: ^run_id}}},
                     15_000

      assert [%{message_id: message_id, text: text}] = ProjectionStore.pending_steering(run_id)
      assert message_id == "question:" <> q.question_id
      assert text =~ "Use postgres."
    end
  end

  describe "refusals" do
    test "a blank answer is refused: nothing is dispatched and the question stays open",
         %{id: id, run: run} do
      q = open_question!(id, run.run_id)
      {view, _html} = mount_view(id)
      count_operator_dispatches!()

      html = view |> form(answer_form(q), %{"text" => "   \n  "}) |> render_submit()

      assert html =~ "Write an answer first."
      assert has_element?(view, "#notice.ws-error", "Write an answer first.")
      refute_received {:dispatched, _}
      assert has_element?(view, card(q))
      assert has_element?(view, answer_form(q))
      assert %{status: "open"} = ProjectionStore.question(q.run_id, q.question_id)
      assert event_types(q) == ["QuestionOpened"]
    end

    test "a question answered elsewhere shows an error and records nothing more",
         %{id: id, run: run} do
      q = open_question!(id, run.run_id)
      {view, _html} = mount_view(id)
      answer_from_cli!(q, "the CLI was first")
      count_operator_dispatches!()

      # the stale submit: the view has not refreshed yet (or the form is still on screen)
      html = submit_event(view, q, "too late")

      assert html =~ "Could not answer: the question was already answered."
      assert has_element?(view, "#notice.ws-error")
      refute_received {:dispatched, _}
      assert Process.alive?(view.pid)
      assert event_types(q) == ["QuestionOpened", "QuestionAnswered"]
      assert [_opened, answered] = events(q)
      assert Map.get(answered.data, :text) == "the CLI was first"

      # still a working page afterwards
      refute has_element?(view, card(q))
    end

    test "an expired question shows an error and the page keeps working", %{id: id, run: run} do
      q = open_question!(id, run.run_id)
      {view, _html} = mount_view(id)
      expire_question!(q)
      count_operator_dispatches!()

      html = submit_event(view, q, "after the timeout")

      assert html =~ "Could not answer: the question expired before it was answered."
      assert has_element?(view, "#notice.ws-error")
      refute_received {:dispatched, _}
      assert Process.alive?(view.pid)
      assert event_types(q) == ["QuestionOpened", "QuestionExpired"]

      await_until(view, fn _ -> not has_element?(view, card(q)) end)
      assert has_element?(view, "#overview-pane")
    end

    test "another project's question and an unknown id are refused and nothing is dispatched",
         %{id: id, other: other} do
      foreign_run = start_task_run!(other, "Elsewhere")
      foreign = open_question!(other, foreign_run.run_id)
      {view, _html} = mount_view(id)
      count_operator_dispatches!()

      assert submit_event(view, foreign, "not mine") =~ "Question not found in this project."

      unknown = %{run_id: foreign_run.run_id, question_id: "q-unknown-" <> token()}
      assert submit_event(view, unknown, "who asked?") =~ "Question not found in this project."

      refute_received {:dispatched, _}
      assert event_types(foreign) == ["QuestionOpened"]
      assert %{status: "open"} = ProjectionStore.question(foreign.run_id, foreign.question_id)
    end

    test "the aggregate's refusal of a late answer reads as plain text" do
      assert Actions.describe({:question_not_open, "answered"}) ==
               "the question was already answered"

      assert Actions.describe({:question_not_open, "expired"}) ==
               "the question expired before it was answered"
    end
  end
end
