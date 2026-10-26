defmodule ForemanServer.NotifierDeliveryTest do
  @moduledoc """
  Delivery proof: a projected event travels the whole production path
  (Notifier -> Messaging.notify -> event store -> projection broadcast ->
  Dispatcher -> provider -> HTTP) and the secret destination appears in the HTTP
  request only, never in any event. The events are real where a run can produce
  them (a PR opened by a run's AutoPR, a run blocked or flagged stuck), and a
  retryable failure is shown redelivered after a dispatcher restart.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias ForemanServer.Aggregates.{OperatorQuestion, ToolCall}
  alias ForemanServer.{CommandGateway, EventStore, Notifier}
  alias ForemanServer.Messaging.{Dispatcher, HttpResponse}
  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.{PrWatchSupport, ProjectionStoreReset, StaticHostResolver}
  alias ForemanServer.Workflow.{MergeGate, RunExecutor}

  @slack_url "https://hooks.slack.com/services/T000/B000/DELIVERYSECRET"
  @hook_url "https://example.test/hooks/DELIVERYSECRET"

  defmodule RecordingHttpClient do
    @moduledoc false
    def post_json(url, body, headers, _timeout) do
      send(Application.fetch_env!(:foreman_server, :e10_test_pid), {:http, url, body, headers})
      status = Application.get_env(:foreman_server, :e10_http_status, 200)
      answer = Application.get_env(:foreman_server, :e10_http_body, "ok")
      {:ok, %HttpResponse{status: status, body: answer}}
    end
  end

  defmodule OneStreamStore do
    @moduledoc false
    # The event store as a RESTARTED dispatcher reads it on catch-up, narrowed to the one
    # notification stream under test, so its catch-up cannot redeliver another test's notifications.
    def read_all_streams_forward(_start_version, _count) do
      stream = Application.fetch_env!(:foreman_server, :e10_test_stream)
      ForemanServer.EventStore.read_stream_forward(stream, 0, 1_000)
    end
  end

  setup %{tmp_dir: dir} do
    ProjectionStoreReset.reset!()
    original = Application.get_env(:foreman_server, :messaging)
    Application.put_env(:foreman_server, :e10_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:foreman_server, :e10_test_pid)
      Application.delete_env(:foreman_server, :e10_http_status)
      Application.delete_env(:foreman_server, :e10_http_body)
      Application.delete_env(:foreman_server, :e10_test_stream)

      if original,
        do: Application.put_env(:foreman_server, :messaging, original),
        else: Application.delete_env(:foreman_server, :messaging)

      MergeGate.clear()
      ProjectionStoreReset.reset!()
    end)

    H.subscribe!()
    project_id = H.register_project(dir)
    {:ok, project_id: project_id}
  end

  defp configure(provider_config),
    do:
      Application.put_env(
        :foreman_server,
        :messaging,
        [enabled: true, http_client: RecordingHttpClient, host_resolver: StaticHostResolver] ++
          provider_config
      )

  defp start_pipeline do
    start_supervised!({Dispatcher, catch_up?: false})
    start_supervised!(Notifier)
  end

  defp emit(type, payload),
    do: send(Notifier, {:projection_event, %{event_type: type, data: payload}})

  defp notification_events(%{notification_id: id}) do
    stream = "notification:" <> (id |> String.split(":", parts: 2) |> List.last())
    {:ok, events} = EventStore.read_stream_forward(stream, 0, 100)
    events
  end

  test "a run failure reaches Slack; the webhook URL is used for the POST and recorded nowhere",
       %{project_id: project_id} do
    configure(provider: :slack, slack: [webhook_url: @slack_url])
    start_pipeline()
    run_id = "run-slack-#{System.unique_integer([:positive])}"

    emit("RunFailed", %{run_id: run_id, project_id: project_id, reason: "phase exploded"})

    assert_receive {:http, @slack_url, %{text: text}, []}, 5_000
    assert text =~ "Run failed"
    assert text =~ "phase exploded"

    enqueued = H.await_event("NotificationEnqueued", &(&1.run_id == run_id))
    H.await_event("NotificationDeliverySucceeded", &(&1.run_id == run_id))

    events = notification_events(enqueued)
    assert Enum.map(events, & &1.event_type) |> Enum.member?("NotificationDeliverySucceeded")
    refute inspect(events) =~ "DELIVERYSECRET"
    refute inspect(events) =~ "hooks.slack.com"
    assert enqueued.recipient == "default"
  end

  test "an approval request reaches the generic webhook, signed, with the same secrecy",
       %{project_id: project_id} do
    configure(provider: :webhook, webhook: [url: @hook_url, secret: "signing-key"])
    start_pipeline()
    run_id = "run-hook-#{System.unique_integer([:positive])}"

    emit("ToolCallRequested", %{
      run_id: run_id,
      project_id: project_id,
      tool_call_id: "tc-#{System.unique_integer([:positive])}",
      tool_name: "Bash",
      input_summary: "rm -rf build"
    })

    assert_receive {:http, @hook_url, body,
                    [{"x-foreman-delivery", delivery}, {"x-foreman-signature", "sha256=" <> _}]},
                   5_000

    assert delivery == body.notification_id
    assert body.schema == "foreman.notification.v1"
    assert body.event_class == :action_needed
    assert body.subject == "Approval requested"
    assert body.body =~ "Bash"
    assert body.run_id == run_id

    enqueued = H.await_event("NotificationEnqueued", &(&1.run_id == run_id))
    H.await_event("NotificationDeliverySucceeded", &(&1.run_id == run_id))

    events = notification_events(enqueued)
    refute inspect(events) =~ "DELIVERYSECRET"
    refute inspect(events) =~ "signing-key"
  end

  test "preference off delivers nothing even for a failure", %{project_id: project_id} do
    configure(provider: :webhook, webhook: [url: @hook_url])

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        command_id: "pref-off-#{System.unique_integer([:positive])}",
        aggregate_id: "project:#{project_id}",
        type: "project.update",
        payload: %{project_id: project_id, notification_preference: "off"}
      })

    start_pipeline()
    emit("RunFailed", %{run_id: "run-off", project_id: project_id, reason: "x"})

    refute_receive {:http, _, _, _}, 300
    refute_receive {:projection_event, %{event_type: "NotificationEnqueued"}}, 50
  end

  # foreman-ehz7l: the combined live run's three threads each opened a PR through AutoPR and
  # reached Ready for review, and the sink never got "PR ready for review": the table mapped
  # `PrCreated`, which only the Create PR button records, while AutoPR records `PrReady`.
  describe "a run that opens its own PR" do
    @pr_url "https://github.com/acme/repo/pull/42"

    setup %{project_id: project_id, tmp_dir: dir} do
      MergeGate.clear()
      set_preference(project_id, "every_turn")
      {:ok, run_id: run_with_branch(project_id, dir)}
    end

    test "its PR ready for review notification reaches the webhook sink, and only once",
         %{project_id: project_id, run_id: run_id, tmp_dir: dir} do
      configure(provider: :webhook, webhook: [url: @hook_url])
      start_pipeline()

      # The command AutoPR's run dispatches once its PR is open: a real `PrReady` on the run's
      # stream, and no `PrCreated`.
      assert :ok =
               RunExecutor.__signal_pr_ready_for_test__(
                 executor_state(run_id, project_id, dir),
                 @pr_url
               )

      assert ["PrReady"] =
               Enum.filter(
                 PrWatchSupport.run_event_types(run_id),
                 &(&1 =~ ~r/^Pr(Ready|Created)$/)
               )

      assert_receive {:http, @hook_url, %{run_id: ^run_id} = body, _headers}, 5_000
      assert body.subject == "PR ready for review"
      assert body.event_class == :run_update
      assert body.url == @pr_url
      assert body.body =~ "pr_url: #{@pr_url}"
      assert body.body =~ "branch_name: foreman/run-branch"
      assert body.body =~ "base_branch: main"

      # The Create PR button records `PrCreated` after the `PrReady` it also records: the same PR
      # must not be announced twice.
      emit("PrCreated", %{
        run_id: run_id,
        project_id: project_id,
        pr_url: @pr_url,
        head_branch: "foreman/run-branch",
        base_branch: "main"
      })

      refute_receive {:http, _, %{run_id: ^run_id}, _}, 300
    end

    test "under the default preference it stays quiet: a ready PR is progress, not a blocker",
         %{project_id: project_id, run_id: run_id, tmp_dir: dir} do
      configure(provider: :webhook, webhook: [url: @hook_url])
      set_preference(project_id, "blocked_only")
      start_pipeline()

      assert :ok =
               RunExecutor.__signal_pr_ready_for_test__(
                 executor_state(run_id, project_id, dir),
                 @pr_url
               )

      H.await_event("PrReady", &(&1.run_id == run_id))
      refute_receive {:http, _, %{run_id: ^run_id}, _}, 300
    end
  end

  # foreman-ireii: the E10 epic's "a blocked run produces one provider delivery". The commands
  # are the ones CrashLoopDetector.emit_run_blocked/2 and StuckDetector.scan/1 dispatch.
  test "a run the crash-loop detector blocked and a run the stuck detector flagged each reach the sink",
       %{project_id: project_id} do
    configure(provider: :webhook, webhook: [url: @hook_url])
    start_pipeline()
    %{run_id: blocked} = PrWatchSupport.start_run!(project_id: project_id)
    %{run_id: stuck} = PrWatchSupport.start_run!(project_id: project_id)

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        command_id: "crash-loop-blocked:#{blocked}:worker-1",
        aggregate_id: "run:#{blocked}",
        type: "run.block",
        payload: %{
          "run_id" => blocked,
          "reason" => "max_attempts_exceeded",
          "worker_id" => "worker-1"
        }
      })

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        aggregate_id: "run:#{stuck}",
        type: "run.flag_stuck",
        payload: %{run_id: stuck, flagged_at: System.system_time(:millisecond)}
      })

    assert_receive {:http, @hook_url, %{run_id: ^blocked} = blocked_body, _}, 5_000
    assert blocked_body.subject == "Run blocked"
    assert blocked_body.event_class == :action_needed
    assert blocked_body.severity == :critical
    assert blocked_body.body =~ "max_attempts_exceeded"

    assert_receive {:http, @hook_url, %{run_id: ^stuck} = stuck_body, _}, 5_000
    assert stuck_body.subject == "Run flagged stuck"
    assert stuck_body.event_class == :stall
  end

  # foreman-ireii (E10-S5): "Retry path is proven via recorded delivery events."
  test "a retryable failure is redelivered after a dispatcher restart: failed, then succeeded",
       %{project_id: project_id} do
    configure(provider: :webhook, webhook: [url: @hook_url])
    Application.put_env(:foreman_server, :e10_http_status, 503)
    start_pipeline()
    run_id = "run-retry-#{System.unique_integer([:positive])}"

    emit("RunFailed", %{run_id: run_id, project_id: project_id, reason: "phase exploded"})

    enqueued = H.await_event("NotificationEnqueued", &(&1.run_id == run_id))
    failed = H.await_event("NotificationDeliveryFailed", &(&1.run_id == run_id))
    assert failed.retryable? == true
    assert failed.reason == "webhook_http_503"
    assert_receive {:http, @hook_url, %{run_id: ^run_id}, _}, 1_000

    # A dispatcher delivers a notification once in its lifetime; the retry is the restart's
    # catch-up, which finds no durable terminal outcome and delivers again.
    stop_supervised!(Dispatcher)
    Application.put_env(:foreman_server, :e10_http_status, 200)

    Application.put_env(
      :foreman_server,
      :e10_test_stream,
      "notification:" <> enqueued.correlation_id
    )

    start_supervised!({Dispatcher, event_store: OneStreamStore})

    H.await_event("NotificationDeliverySucceeded", &(&1.run_id == run_id))
    assert_receive {:http, @hook_url, %{run_id: ^run_id}, _}, 1_000

    assert Enum.map(notification_events(enqueued), & &1.event_type) == [
             "NotificationEnqueued",
             "NotificationDeliveryAttempted",
             "NotificationDeliveryFailed",
             "NotificationDeliveryAttempted",
             "NotificationDeliverySucceeded"
           ]
  end

  # The Bot API leg of the pipeline (Slack and the webhook are above). The token rides in the URL
  # path, a secret in the request line instead of a header, so it is the one most likely to leak
  # into an event or a log line.
  describe "Telegram" do
    @tg_token "123456789:AAEhBP0av28TGSECRETTOKENabcdefghijk"
    @tg_chat "-1001234567890"
    @tg_url "https://api.telegram.org/bot#{@tg_token}/sendMessage"

    setup do
      configure(provider: :telegram, telegram: [token: @tg_token, chat_id: @tg_chat])
    end

    test "a run failure is posted to the bot's sendMessage; the token is in that request line and nowhere else",
         %{project_id: project_id} do
      run_id = "run-tg-#{System.unique_integer([:positive])}"

      Application.put_env(
        :foreman_server,
        :e10_http_body,
        ~s({"ok":true,"result":{"message_id":7}})
      )

      log =
        capture_log(fn ->
          start_pipeline()
          emit("RunFailed", %{run_id: run_id, project_id: project_id, reason: "phase exploded"})

          assert_receive {:http, @tg_url, body, []}, 5_000

          # The text is the three lines of the notification, then the ids it carries (their order
          # is `inspect/1`'s, not a contract).
          assert %{chat_id: @tg_chat, disable_web_page_preview: true, text: text} = body
          assert [title, run_line, reason_line, metadata] = String.split(text, "\n")
          assert title == "[critical] Run failed"
          assert run_line == "run_id: #{run_id}"
          assert reason_line == "reason: phase exploded"
          assert metadata =~ "run_id: #{inspect(run_id)}"
          assert metadata =~ "project_id: #{inspect(project_id)}"

          H.await_event("NotificationDeliverySucceeded", &(&1.run_id == run_id))
        end)

      enqueued = H.await_event("NotificationEnqueued", &(&1.run_id == run_id))
      assert to_string(enqueued.provider) == "telegram"
      assert enqueued.recipient == "default"
      events = notification_events(enqueued)

      assert Enum.map(events, & &1.event_type) == [
               "NotificationEnqueued",
               "NotificationDeliveryAttempted",
               "NotificationDeliverySucceeded"
             ]

      refute inspect(events) =~ "TGSECRETTOKEN"
      refute log =~ "TGSECRETTOKEN"
    end

    test "a non-2xx answer is a recorded failure: terminal for a bad request or token, retryable for a rate limit or an outage",
         %{project_id: project_id} do
      start_pipeline()

      for {status, retryable?} <- [{400, false}, {401, false}, {429, true}, {500, true}] do
        run_id = "run-tg-#{status}-#{System.unique_integer([:positive])}"

        # What an error page in front of the API does: it names the request it refused. The token
        # is in that line, so the recorded reason must not repeat it.
        refused = fn name ->
          ~s({"ok":false,"error_code":#{status},"description":"refused #{name}"})
        end

        Application.put_env(:foreman_server, :e10_http_status, status)

        Application.put_env(
          :foreman_server,
          :e10_http_body,
          refused.("/bot#{@tg_token}/sendMessage")
        )

        emit("RunFailed", %{run_id: run_id, project_id: project_id, reason: "phase exploded"})

        assert_receive {:http, @tg_url, %{chat_id: @tg_chat}, []}, 5_000
        failed = H.await_event("NotificationDeliveryFailed", &(&1.run_id == run_id))

        assert failed.retryable? == retryable?

        assert failed.reason ==
                 "telegram_http_#{status}: " <> refused.("/bot[REDACTED]/sendMessage")

        events = notification_events(failed)

        assert Enum.map(events, & &1.event_type) == [
                 "NotificationEnqueued",
                 "NotificationDeliveryAttempted",
                 "NotificationDeliveryFailed"
               ]

        refute inspect(events) =~ "TGSECRETTOKEN"
      end
    end
  end

  # foreman-q9zzo C12: an expired question, an expired approval and an exhausted PR fix, each
  # produced by the aggregate that owns it (the commands the approvals sweeper and the auto-fix
  # policy dispatch), reach the sink under the DEFAULT preference: they are action_needed, which
  # `blocked_only` delivers.
  test "an expired question, an expired approval and an exhausted PR fix reach the sink",
       %{project_id: project_id} do
    configure(provider: :webhook, webhook: [url: @hook_url])
    start_pipeline()
    %{run_id: run_id} = PrWatchSupport.start_run!(project_id: project_id)
    pr_url = "https://github.com/acme/repo/pull/12"
    question_id = "q-#{System.unique_integer([:positive])}"
    tool_call_id = "tc-#{System.unique_integer([:positive])}"
    question = OperatorQuestion.stream_id(run_id, question_id)
    tool_call = ToolCall.stream_id(run_id, tool_call_id)

    for {type, aggregate_id, payload} <- [
          {"question.open", question,
           %{run_id: run_id, question_id: question_id, project_id: project_id, text: "Which DB?"}},
          {"question.expire", question,
           %{run_id: run_id, question_id: question_id, reason: "timeout"}},
          {"tool.request", tool_call,
           %{run_id: run_id, tool_call_id: tool_call_id, tool_name: "Bash"}},
          {"tool.expire", tool_call,
           %{run_id: run_id, tool_call_id: tool_call_id, reason: "timeout"}},
          {"run.pr.fix_exhausted", "run:#{run_id}",
           %{
             run_id: run_id,
             pr_url: pr_url,
             kind: "ci",
             reason: "max_attempts",
             head_sha: "sha-1"
           }}
        ] do
      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 type: type,
                 command_id: "#{type}:#{aggregate_id}",
                 aggregate_id: aggregate_id,
                 payload: payload
               })
    end

    for {subject, text, url} <- [
          {"Question expired unanswered", "run_id: #{run_id}\nreason: timeout", nil},
          {"Approval request expired", "run_id: #{run_id}\nreason: timeout", nil},
          {"PR fix attempts exhausted",
           "run_id: #{run_id}\npr_url: #{pr_url}\nkind: ci\nreason: max_attempts\nattempts: 0",
           pr_url}
        ] do
      assert_receive {:http, @hook_url, %{subject: ^subject} = body, _headers}, 5_000

      assert %{event_class: :action_needed, severity: :warning, run_id: ^run_id} = body
      assert body.body == text
      assert body.url == url
    end
  end

  defp set_preference(project_id, preference) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        command_id: "pref-#{System.unique_integer([:positive])}",
        aggregate_id: "project:#{project_id}",
        type: "project.update",
        payload: %{project_id: project_id, notification_preference: preference}
      })
  end

  # A started run of the project, and a repository holding the branch it pushed: what the executor
  # resolves the PR's head from before it signals `run.pr.ready`.
  defp run_with_branch(project_id, dir) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "--initial-branch=main", "--quiet"])
    git!(repo, ["config", "user.email", "t@x"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "seed")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-m", "seed", "--quiet"])
    git!(repo, ["branch", "foreman/run-branch"])

    %{run_id: run_id} = PrWatchSupport.start_run!(project_id: project_id)
    run_id
  end

  defp executor_state(run_id, project_id, dir) do
    %{
      run_id: run_id,
      task: %{task_id: "task-#{run_id}", project_id: project_id},
      plan_context: %{"project_root" => Path.join(dir, "repo")},
      run_base_branch: {:ok, "main"},
      last_worktree: %{branch: "foreman/run-branch"},
      current_phase: nil,
      phase_specs: []
    }
  end

  defp git!(root, args) do
    {out, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    out
  end
end
