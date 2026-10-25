defmodule ForemanServer.NotifierTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.{CommandGateway, EventStore, Notifier, ProjectionStore}
  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.ProjectionStoreReset

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
  end

  test "disabled messaging enqueues nothing and writes no suppression noise",
       %{project_id: project_id} do
    Application.put_env(:foreman_server, :messaging, enabled: false)
    H.subscribe!()

    assert {_, {:skipped, :messaging_disabled}} = run(failed(project_id), Notifier.new_state())

    refute_receive {:projection_event, %{event_type: "NotificationSuppressed"}}, 200
    refute_receive {:projection_event, %{event_type: "NotificationEnqueued"}}, 50
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
