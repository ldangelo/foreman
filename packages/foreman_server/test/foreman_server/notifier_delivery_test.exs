defmodule ForemanServer.NotifierDeliveryTest do
  @moduledoc """
  Delivery proof: a projected event travels the whole production path
  (Notifier -> Messaging.notify -> event store -> projection broadcast ->
  Dispatcher -> provider -> HTTP) and the secret destination appears in the HTTP
  request only, never in any event.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.{CommandGateway, EventStore, Notifier}
  alias ForemanServer.Messaging.{Dispatcher, HttpResponse}
  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @slack_url "https://hooks.slack.com/services/T000/B000/DELIVERYSECRET"
  @hook_url "https://example.test/hooks/DELIVERYSECRET"

  defmodule RecordingHttpClient do
    @moduledoc false
    def post_json(url, body, headers, _timeout) do
      send(Application.fetch_env!(:foreman_server, :e10_test_pid), {:http, url, body, headers})
      {:ok, %HttpResponse{status: 200, body: "ok"}}
    end
  end

  setup %{tmp_dir: dir} do
    ProjectionStoreReset.reset!()
    original = Application.get_env(:foreman_server, :messaging)
    Application.put_env(:foreman_server, :e10_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:foreman_server, :e10_test_pid)

      if original,
        do: Application.put_env(:foreman_server, :messaging, original),
        else: Application.delete_env(:foreman_server, :messaging)

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
        [enabled: true, http_client: RecordingHttpClient] ++ provider_config
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

    assert_receive {:http, @hook_url, body, [{"x-foreman-signature", "sha256=" <> _}]}, 5_000
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
end
