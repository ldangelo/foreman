defmodule ForemanServer.NotifierTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.{CommandGateway, EventStore, Notifier}
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
end
