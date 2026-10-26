defmodule ForemanServer.NotifierTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Aggregates.{OperatorQuestion, ToolCall}
  alias ForemanServer.{CommandGateway, EventStore, Notifier, ProjectionStore}
  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.{PrWatchSupport, ProjectionStoreReset}

  @secret_url "https://hooks.slack.com/services/T000/B000/SECRETSECRETSECRET"

  setup %{tmp_dir: dir} do
    ProjectionStoreReset.reset!()
    original = Application.get_env(:foreman_server, :messaging)

    Application.put_env(:foreman_server, :messaging,
      enabled: true,
      provider: :slack,
      slack: [webhook_url: @secret_url],
      run_update_rate_limit_ms: 60_000
    )

    on_exit(fn ->
      if original,
        do: Application.put_env(:foreman_server, :messaging, original),
        else: Application.delete_env(:foreman_server, :messaging)

      ProjectionStoreReset.reset!()
    end)

    {:ok, project_id: H.register_project(dir)}
  end

  defp uid(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp set_preference(project_id, pref) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        command_id: uid("pref"),
        aggregate_id: "project:#{project_id}",
        type: "project.update",
        payload: %{project_id: project_id, notification_preference: pref}
      })
  end

  # "slack:notifier:<digest>" -> events of stream "notification:notifier:<digest>"
  defp stream_events("slack:" <> correlation_id) do
    case EventStore.read_stream_forward("notification:" <> correlation_id, 0, 100) do
      {:ok, events} -> events
      {:error, :stream_not_found} -> []
    end
  end

  defp types(events), do: Enum.map(events, & &1.event_type)

  defp failed(project_id, run_id \\ uid("run")),
    do: {"RunFailed", %{run_id: run_id, project_id: project_id, reason: "phase exploded"}}

  defp completed(project_id, run_id),
    do: {"RunCompleted", %{run_id: run_id, project_id: project_id, status: "completed"}}

  defp run({type, payload}, state), do: Notifier.process(state, type, payload)

  test "a failure is enqueued once with class, severity and a recipient label, not the URL",
       %{project_id: project_id} do
    state = Notifier.new_state()

    assert {_, {:notified, id}} = run(failed(project_id), state)
    assert [%{event_type: "NotificationEnqueued", data: data}] = stream_events(id)

    assert data.event_class == :failure or data.event_class == "failure"
    assert data.recipient == "default"
    assert data.body =~ "phase exploded"

    # The Slack webhook URL is the destination secret: nowhere in the event log.
    refute inspect(stream_events(id)) =~ "SECRETSECRET"
    refute inspect(stream_events(id)) =~ "hooks.slack.com"
  end

  test "the same event processed twice yields one enqueue and one suppression, same id",
       %{project_id: project_id} do
    state = Notifier.new_state()
    event = failed(project_id)

    {state, {:notified, id}} = run(event, state)
    assert {_, {:notified, ^id}} = run(event, state)

    assert types(stream_events(id)) == ["NotificationEnqueued", "NotificationSuppressed"]
  end

  test "different occurrences get different ids", %{project_id: project_id} do
    state = Notifier.new_state()
    {state, {:notified, a}} = run(failed(project_id), state)
    assert {_, {:notified, b}} = run(failed(project_id), state)
    refute a == b
  end

  describe "project preference" do
    test "blocked_only is the default: failures notify, completions do not",
         %{project_id: project_id} do
      state = Notifier.new_state()

      assert {_, {:notified, _}} = run(failed(project_id), state)
      assert {_, {:skipped, :preference}} = run(completed(project_id, uid("run")), state)
    end

    test "off silences everything, including failures", %{project_id: project_id} do
      set_preference(project_id, "off")
      state = Notifier.new_state()

      assert {_, {:skipped, :preference}} = run(failed(project_id), state)
    end

    test "every_turn also delivers run updates even when the config omits that class",
         %{project_id: project_id} do
      set_preference(project_id, "every_turn")
      state = Notifier.new_state()

      assert {_, {:notified, id}} = run(completed(project_id, uid("run")), state)
      assert ["NotificationEnqueued"] = types(stream_events(id))
    end

    test "every_turn does not enable classes the config could not otherwise resolve",
         %{project_id: project_id} do
      set_preference(project_id, "every_turn")
      Application.put_env(:foreman_server, :messaging, enabled: false)
      state = Notifier.new_state()

      assert {_, {:skipped, :messaging_disabled}} = run(failed(project_id), state)
    end

    test "clearing the setting returns to the default", %{project_id: project_id} do
      set_preference(project_id, "off")

      {:ok, _} =
        CommandGateway.dispatch_system(%{
          command_id: uid("clear"),
          aggregate_id: "project:#{project_id}",
          type: "project.update",
          payload: %{project_id: project_id, cleared_settings: ["notification_preference"]}
        })

      assert {_, {:notified, _}} = run(failed(project_id), Notifier.new_state())
    end

    # A project the projection does not know cannot have opted out and cannot be asked, so its
    # event is skipped, counted and logged: the default belongs to a project with no preference
    # SET, not to a dangling reference (AGENTS.md 5.3, absent is not malformed).
    test "an event naming a project the projection does not know is skipped, loudly" do
      payload = %{run_id: uid("run"), project_id: uid("ghost-project"), reason: "phase exploded"}

      {{state, outcome}, log} =
        ExUnit.CaptureLog.with_log(fn ->
          Notifier.process(Notifier.new_state(), "RunFailed", payload)
        end)

      assert outcome == {:skipped, :project_unresolved}
      assert log =~ "[warning]"
      assert log =~ payload.project_id
      assert state.stats.skipped == %{project_unresolved: 1}
      assert state.stats.notified == 0
    end

    # The other nil: a standalone jobsite really has no project (`JobsiteStarted.project_id` is
    # nullable), so there is nothing to resolve and the default applies. Skipping it as
    # "unresolved" would silently drop the failure of every project-less jobsite.
    test "an event that names no project at all (a standalone jobsite) uses the default" do
      jobsite_id = start_jobsite(nil)

      assert {_, {:notified, id}} =
               Notifier.process(Notifier.new_state(), "JobsiteFailed", %{
                 jobsite_id: jobsite_id,
                 code: "agent_failed",
                 message: "the agent exited 1"
               })

      assert [%{data: data}] = stream_events(id)
      assert to_string(data.event_class) == "failure"
    end
  end

  test "disabled messaging enqueues nothing and writes no suppression noise",
       %{project_id: project_id} do
    Application.put_env(:foreman_server, :messaging, enabled: false)
    H.subscribe!()

    assert {_, {:skipped, :messaging_disabled}} = run(failed(project_id), Notifier.new_state())

    refute_receive {:projection_event, %{event_type: "NotificationSuppressed"}}, 200
    refute_receive {:projection_event, %{event_type: "NotificationEnqueued"}}, 50
  end

  # The `data` of a freshly appended typed event is a struct, not a map (the live Notifier crashed
  # on the first one when every payload was normalised as a plain map).
  test "a typed event struct of a mapped type is notified like its map form",
       %{project_id: project_id} do
    event = %ForemanServer.Events.RunBlocked{
      run_id: uid("run"),
      project_id: project_id,
      reason: "max_attempts_exceeded"
    }

    assert {_, {:notified, id}} = Notifier.process(Notifier.new_state(), "RunBlocked", event)
    assert [%{event_type: "NotificationEnqueued", data: data}] = stream_events(id)
    assert to_string(data.event_class) == "action_needed"
    assert data.body =~ "max_attempts_exceeded"
  end

  test "an unmapped event is skipped", %{project_id: project_id} do
    assert {_, {:skipped, :unmapped}} =
             Notifier.process(Notifier.new_state(), "RunStarted", %{
               run_id: uid("run"),
               project_id: project_id
             })
  end

  describe "run_update rate limit" do
    setup %{project_id: project_id} do
      set_preference(project_id, "every_turn")
      Process.put(:now, 1_000_000)
      {:ok, state: Notifier.new_state(clock: fn -> Process.get(:now) end)}
    end

    test "a second update for the same run inside the window is dropped", %{
      project_id: project_id,
      state: state
    } do
      run_id = uid("run")

      {state, {:notified, _}} = run(completed(project_id, run_id), state)

      Process.put(:now, 1_000_000 + 59_999)

      assert {_, {:skipped, :rate_limited}} =
               run({"ReviewRecorded", review(project_id, run_id, "met")}, state)
    end

    test "it is allowed again once the window has passed", %{project_id: project_id, state: state} do
      run_id = uid("run")

      {state, {:notified, _}} = run(completed(project_id, run_id), state)
      Process.put(:now, 1_000_000 + 60_000)

      assert {_, {:notified, _}} =
               run({"ReviewRecorded", review(project_id, run_id, "met")}, state)
    end

    test "the window is per run", %{project_id: project_id, state: state} do
      {state, {:notified, _}} = run(completed(project_id, uid("run")), state)
      assert {_, {:notified, _}} = run(completed(project_id, uid("run")), state)
    end

    test "blocked notifications are never rate limited", %{project_id: project_id, state: state} do
      run_id = uid("run")
      {state, {:notified, _}} = run(completed(project_id, run_id), state)

      assert {_, {:notified, _}} =
               run(
                 {"RunFailed", %{run_id: run_id, project_id: project_id, reason: "later"}},
                 state
               )
    end

    test "expired window entries are pruned so the table stays bounded", %{
      project_id: project_id,
      state: state
    } do
      {state, {:notified, _}} = run(completed(project_id, uid("run")), state)
      Process.put(:now, 1_000_000 + 120_000)
      {state, {:notified, _}} = run(completed(project_id, uid("run")), state)

      assert map_size(state.last_run_update) == 1
    end
  end

  defp review(project_id, run_id, verdict) do
    %{
      subject_kind: "run",
      subject_id: run_id,
      project_id: project_id,
      verdict: verdict,
      summary: "ok",
      at: "2026-01-01T00:00:00Z"
    }
  end

  test "approval and needs-input events notify as action_needed (guarded mapping)",
       %{project_id: project_id} do
    state = Notifier.new_state()

    for {type, payload} <- [
          {"QuestionOpened", %{question_id: uid("q"), run_id: uid("run"), text: "Which DB?"}},
          {"ToolCallRequested",
           %{
             tool_call_id: uid("tc"),
             run_id: uid("run"),
             tool_name: "Bash",
             project_id: project_id
           }}
        ] do
      payload = Map.put_new(payload, :project_id, project_id)
      assert {_, {:notified, id}} = Notifier.process(state, type, payload)
      assert [%{data: data}] = stream_events(id)
      assert to_string(data.event_class) == "action_needed"
    end
  end

  test "a secret-looking value in an event is redacted before it reaches the event log",
       %{project_id: project_id} do
    payload = %{
      run_id: uid("run"),
      project_id: project_id,
      reason: "push failed: https://hooks.slack.com/services/T1/B2/LEAKLEAKLEAK"
    }

    assert {_, {:notified, id}} = Notifier.process(Notifier.new_state(), "RunFailed", payload)
    refute inspect(stream_events(id)) =~ "LEAKLEAKLEAK"
  end

  describe "the rows for a blocked, stuck or finished thread (foreman-ireii)" do
    test "a run blocked by the crash-loop detector produces one action_needed notification",
         %{project_id: project_id} do
      run_id = uid("run")

      # What `run.block` stores when the CrashLoopDetector dispatches it: its string-keyed
      # payload plus the atom-keyed ids the Run aggregate adds (equal values, mixed key forms).
      payload = %{
        "run_id" => run_id,
        "reason" => "max_attempts_exceeded",
        "worker_id" => "worker-1",
        run_id: run_id,
        project_id: project_id
      }

      assert {_, {:notified, id}} = Notifier.process(Notifier.new_state(), "RunBlocked", payload)
      assert [%{event_type: "NotificationEnqueued", data: data}] = stream_events(id)

      assert to_string(data.event_class) == "action_needed"
      assert to_string(data.severity) == "critical"
      assert data.subject == "Run blocked"
      assert data.body =~ "max_attempts_exceeded"
      assert data.run_id == run_id
    end

    test "a run flagged stuck produces one stall notification", %{project_id: project_id} do
      run_id = uid("run")
      payload = %{run_id: run_id, project_id: project_id, flagged_at: 1_700_000_000_000}
      state = Notifier.new_state()

      assert {state, {:notified, id}} = Notifier.process(state, "RunFlaggedStuck", payload)
      assert [%{event_type: "NotificationEnqueued", data: data}] = stream_events(id)
      assert to_string(data.event_class) == "stall"
      assert data.subject == "Run flagged stuck"
      assert data.run_id == run_id

      # The same flag again is the same occurrence; a later flag of the run is a new one.
      assert {state, {:notified, ^id}} = Notifier.process(state, "RunFlaggedStuck", payload)

      assert {_, {:notified, other}} =
               Notifier.process(state, "RunFlaggedStuck", %{
                 payload
                 | flagged_at: 1_700_000_900_000
               })

      refute other == id
    end

    test "a blocked or stuck run is announced under the default preference too",
         %{project_id: project_id} do
      state = Notifier.new_state()

      for type <- ["RunBlocked", "RunFlaggedStuck"] do
        payload = %{run_id: uid("run"), project_id: project_id, flagged_at: 1}
        assert {_, {:notified, _}} = Notifier.process(state, type, payload)
      end
    end

    test "a finished jobsite is a run update that finds its project through the jobsite",
         %{project_id: project_id} do
      jobsite_id = start_jobsite(project_id)
      # `jobsite.complete` stores no project id; the Notifier reads it from the jobsite.
      payload = %{jobsite_id: jobsite_id, iterations_run: 2, branch: "foreman/jb"}

      assert {_, {:skipped, :preference}} =
               Notifier.process(Notifier.new_state(), "JobsiteCompleted", payload)

      set_preference(project_id, "every_turn")

      assert {_, {:notified, id}} =
               Notifier.process(Notifier.new_state(), "JobsiteCompleted", payload)

      assert [%{data: data}] = stream_events(id)
      assert to_string(data.event_class) == "run_update"
      assert data.subject == "Jobsite completed"
      assert data.body =~ jobsite_id
      assert data.body =~ "iterations_run: 2"
    end

    test "a PR fix thread's jobsite finishing is not announced, its failing still is",
         %{project_id: project_id} do
      set_preference(project_id, "every_turn")
      jobsite_id = start_jobsite(project_id)
      state = Notifier.new_state()
      completed = %{jobsite_id: jobsite_id, iterations_run: 1}

      # Not yet a fix thread's jobsite: announced.
      assert {_, {:notified, _}} = Notifier.process(state, "JobsiteCompleted", completed)

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "PrFixStarted",
            payload: %{
              run_id: uid("run"),
              project_id: project_id,
              pr_url: "https://github.com/acme/repo/pull/7",
              kind: "ci",
              attempt: 1,
              jobsite_id: jobsite_id
            }
          }
        ])

      assert {state, {:skipped, :pr_fix_jobsite}} =
               Notifier.process(state, "JobsiteCompleted", completed)

      assert {_, {:notified, _}} =
               Notifier.process(state, "JobsiteFailed", %{
                 jobsite_id: jobsite_id,
                 code: "agent_failed",
                 message: "the fix agent exited 1"
               })
    end

    test "an explicit cancel is skipped as unmapped", %{project_id: project_id} do
      state = Notifier.new_state()

      assert {_, {:skipped, :unmapped}} =
               Notifier.process(state, "RunCancelled", %{
                 run_id: uid("run"),
                 project_id: project_id
               })

      assert {_, {:skipped, :unmapped}} =
               Notifier.process(state, "JobsiteCancelled", %{
                 jobsite_id: uid("jobsite"),
                 reason: "operator"
               })
    end
  end

  # foreman-q9zzo C12: the rows for an expired question, an expired approval and an exhausted PR
  # fix had no test. Their events are the ones the aggregates really append (the commands the
  # approvals sweeper and the PR auto-fix policy dispatch), read back from the projection, so a
  # field the table reads cannot drift from the field the aggregate writes. None of the three
  # payloads names a project: the Notifier finds it through the run, which is what lets the
  # project's preference apply.
  describe "the expiry and exhaustion rows (QuestionExpired, ToolCallExpired, PrFixExhausted)" do
    @pr_url "https://github.com/acme/repo/pull/9"

    setup %{project_id: project_id} do
      H.subscribe!()
      %{run_id: run_id} = PrWatchSupport.start_run!(project_id: project_id)
      {:ok, run_id: run_id}
    end

    defp dispatch!(command) do
      assert {:ok, _} = CommandGateway.dispatch_system(command)
    end

    defp expired_question(run_id, project_id) do
      qid = uid("q")
      stream = OperatorQuestion.stream_id(run_id, qid)

      dispatch!(%{
        type: "question.open",
        command_id: "question-open:#{qid}",
        aggregate_id: stream,
        payload: %{run_id: run_id, question_id: qid, project_id: project_id, text: "Which DB?"}
      })

      dispatch!(%{
        type: "question.expire",
        command_id: "question-expire:#{qid}",
        aggregate_id: stream,
        payload: %{run_id: run_id, question_id: qid, reason: "timeout"}
      })

      {"QuestionExpired", H.await_event("QuestionExpired", &(&1.question_id == qid))}
    end

    defp expired_tool_call(run_id) do
      tool_call_id = uid("tc")
      stream = ToolCall.stream_id(run_id, tool_call_id)

      dispatch!(%{
        type: "tool.request",
        command_id: "tool-request:#{tool_call_id}",
        aggregate_id: stream,
        payload: %{run_id: run_id, tool_call_id: tool_call_id, tool_name: "Bash"}
      })

      dispatch!(%{
        type: "tool.expire",
        command_id: "tool-expire:#{tool_call_id}",
        aggregate_id: stream,
        payload: %{run_id: run_id, tool_call_id: tool_call_id, reason: "timeout"}
      })

      {"ToolCallExpired", H.await_event("ToolCallExpired", &(&1.tool_call_id == tool_call_id))}
    end

    defp exhausted_fix(run_id, head_sha, kind \\ "ci") do
      dispatch!(%{
        type: "run.pr.fix_exhausted",
        command_id: "fix-exhausted:#{run_id}:#{kind}:#{head_sha}",
        aggregate_id: "run:#{run_id}",
        payload: %{
          run_id: run_id,
          pr_url: @pr_url,
          kind: kind,
          reason: "max_attempts",
          head_sha: head_sha
        }
      })

      {"PrFixExhausted",
       H.await_event("PrFixExhausted", &(&1.head_sha == head_sha and &1.kind == kind))}
    end

    test "each is an action_needed notification with its subject, body and link, under the default preference",
         %{project_id: project_id, run_id: run_id} do
      state = Notifier.new_state()

      for {{type, payload}, subject, body, url} <- [
            {expired_question(run_id, project_id), "Question expired unanswered",
             "run_id: #{run_id}\nreason: timeout", nil},
            {expired_tool_call(run_id), "Approval request expired",
             "run_id: #{run_id}\nreason: timeout", nil},
            {exhausted_fix(run_id, "sha-1"), "PR fix attempts exhausted",
             "run_id: #{run_id}\npr_url: #{@pr_url}\nkind: ci\nreason: max_attempts\nattempts: 0",
             @pr_url}
          ] do
        assert {_, {:notified, id}} = Notifier.process(state, type, payload)
        assert [%{event_type: "NotificationEnqueued", data: data}] = stream_events(id)

        assert to_string(data.event_class) == "action_needed"
        assert to_string(data.severity) == "warning"
        assert data.subject == subject
        assert data.body == body
        assert data.url == url
        assert data.run_id == run_id
        assert data.recipient == "default"
      end
    end

    test "a replay is the same notification, another occurrence is another one",
         %{project_id: project_id, run_id: run_id} do
      occurrences = [
        {"a question", expired_question(run_id, project_id),
         expired_question(run_id, project_id)},
        {"an approval", expired_tool_call(run_id), expired_tool_call(run_id)},
        # The PR fix is keyed by PR, head and kind: a new head, or another kind, is a new give-up.
        {"a PR fix on a new head", exhausted_fix(run_id, "sha-a1"),
         exhausted_fix(run_id, "sha-a2")},
        {"a PR fix of another kind", exhausted_fix(run_id, "sha-b1"),
         exhausted_fix(run_id, "sha-b1", "comments")}
      ]

      for {name, {type, payload}, {other_type, other_payload}} <- occurrences do
        assert {state, {:notified, id}} = Notifier.process(Notifier.new_state(), type, payload)
        assert {state, {:notified, ^id}} = Notifier.process(state, type, payload)

        assert types(stream_events(id)) == ["NotificationEnqueued", "NotificationSuppressed"],
               "#{name}: a replay must be suppressed"

        assert {_, {:notified, other}} = Notifier.process(state, other_type, other_payload)
        refute other == id, "#{name}: another occurrence must be another notification"
      end
    end

    test "blocked_only and every_turn deliver them, off drops them",
         %{project_id: project_id, run_id: run_id} do
      # Fresh events each time: a replay of one would be suppressed, not decided again.
      events = fn ->
        [
          expired_question(run_id, project_id),
          expired_tool_call(run_id),
          exhausted_fix(run_id, "sha-#{uid("h")}")
        ]
      end

      for preference <- ["blocked_only", "every_turn"] do
        set_preference(project_id, preference)

        for {type, payload} <- events.() do
          assert {_, {:notified, _id}} = Notifier.process(Notifier.new_state(), type, payload),
                 "#{type} under #{preference}"
        end
      end

      set_preference(project_id, "off")

      for {type, payload} <- events.() do
        assert {_, {:skipped, :preference}} =
                 Notifier.process(Notifier.new_state(), type, payload),
               "#{type} under off"
      end
    end
  end

  describe "stats and status (foreman-ireii)" do
    test "counters tell notified, refused and skipped events apart; unmapped events are not counted",
         %{project_id: project_id} do
      state = Notifier.new_state()
      assert state.stats == %{notified: 0, errors: 0, skipped: %{}, last_error: nil}

      {state, {:notified, _}} = run(failed(project_id), state)
      {state, {:skipped, :preference}} = run(completed(project_id, uid("run")), state)
      {state, {:skipped, :preference}} = run(completed(project_id, uid("run")), state)
      {state, {:skipped, :unmapped}} = Notifier.process(state, "RunStarted", %{})

      assert state.stats == %{notified: 1, errors: 0, skipped: %{preference: 2}, last_error: nil}

      Application.put_env(:foreman_server, :messaging, enabled: true, provider: :webhook)

      {state, {:error, {:messaging_config, reason}}} = run(failed(project_id), state)
      assert state.stats.errors == 1
      assert state.stats.last_error == {:messaging_config, reason}
    end

    test "stats/1 reads a running notifier's counters", %{project_id: project_id} do
      name = :"notifier_stats_#{System.unique_integer([:positive])}"
      start_supervised!({Notifier, name: name, subscribe?: false})

      assert %{notified: 0, errors: 0, skipped: %{}, last_error: nil} = Notifier.stats(name)

      {type, payload} = failed(project_id)
      send(name, {:projection_event, %{event_type: type, data: payload}})

      assert %{notified: 1} = Notifier.stats(name)
    end

    test "status/0 says whether messaging is off, on, or enabled but misconfigured" do
      assert %{messaging: {:enabled, :slack}} = Notifier.status()

      Application.put_env(:foreman_server, :messaging, enabled: false)
      assert %{messaging: :disabled} = Notifier.status()

      # Enabled with no destination: the reason is reported, redacted, and names no URL.
      Application.put_env(:foreman_server, :messaging, enabled: true, provider: :webhook)

      assert %{messaging: {:invalid, {:missing_field, :webhook_destination, :url}}} =
               Notifier.status()
    end

    test "status/0 reports the notifier and dispatcher processes and the notifier's counters" do
      assert %{notifier: :stopped, dispatcher: :stopped, stats: nil} = Notifier.status()

      start_supervised!({ForemanServer.Messaging.Dispatcher, catch_up?: false, subscribe?: false})
      start_supervised!({Notifier, subscribe?: false})

      assert %{notifier: :running, dispatcher: :running, stats: %{notified: 0}} =
               Notifier.status()
    end
  end

  defp start_jobsite(project_id) do
    jobsite_id = uid("jobsite")

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "JobsiteStarted",
          payload: %{
            jobsite_id: jobsite_id,
            repo_path: "/tmp/notifier-test",
            strategy: "worktree",
            project_id: project_id
          }
        }
      ])

    jobsite_id
  end
end
