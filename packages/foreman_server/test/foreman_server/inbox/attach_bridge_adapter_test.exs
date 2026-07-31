defmodule ForemanServer.Inbox.AttachBridgeAdapterTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias ForemanServer.EventStore
  alias ForemanServer.Inbox.AttachBridgeAdapter

  @router_opts ForemanServer.Http.Router.init([])

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-attach-bridge-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    previous_auth_token = Application.get_env(:foreman_server, :auth_token, :__unset__)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    Application.put_env(:foreman_server, :auth_token, "secret")
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)

      if previous_auth_token == :__unset__ do
        Application.delete_env(:foreman_server, :auth_token)
      else
        Application.put_env(:foreman_server, :auth_token, previous_auth_token)
      end

      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    :ok
  end

  test "normalize/1 preserves streaming metadata and connection lifecycle before inbox normalization" do
    payload = attach_bridge_payload("run-attach-normalize", "attach-normalize-1")

    assert {:ok, normalized} = AttachBridgeAdapter.normalize(payload)

    assert normalized.correlation_id == "attach-bridge:attach-normalize-1"
    assert normalized.source == "attach-bridge"
    assert normalized.run_id == "run-attach-normalize"
    assert normalized.event_type == "connection.connected"
    assert normalized.timestamp == ~U[2026-07-31T10:00:05Z]
    assert normalized.session_id == "session-1"
    assert normalized.worker_id == "worker-1"
    assert normalized.phase_id == "developer"

    assert normalized.attach_bridge.streaming_metadata == %{
             stream_url: "wss://stream.example/attach",
             session_path: "/sessions/session-1",
             session_id: "session-1",
             pty: true,
             protocol: "jsonl"
           }

    assert normalized.attach_bridge.connection == %{
             connection_id: "conn-1",
             state: "connected",
             lifecycle: "connected",
             connected_at: "2026-07-31T10:00:00Z",
             reason: "worker-attached"
           }

    assert normalized.attach_bridge.raw == payload
  end

  test "POST /webhooks/attach_bridge ingests normalized items and dedupes retries" do
    payload = attach_bridge_payload("run-attach-webhook", "attach-webhook-1")

    first_conn =
      :post
      |> conn("/webhooks/attach_bridge", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@router_opts)

    assert first_conn.status == 202
    assert Jason.decode!(first_conn.resp_body)["event_type"] == "InboxItemStarted"

    second_conn =
      :post
      |> conn("/webhooks/attach_bridge", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@router_opts)

    assert second_conn.status == 202
    assert Jason.decode!(second_conn.resp_body)["event_type"] == "InboxItemDeduped"

    events = EventStore.stream("inbox:run-attach-webhook")
    assert Enum.count(events, &(&1.event_type == "InboxItemStarted")) == 1
    assert Enum.count(events, &(&1.event_type == "InboxItemDeduped")) == 1

    started_event = Enum.find(events, &(&1.event_type == "InboxItemStarted"))
    assert started_event.payload.correlation_id == "attach-bridge:attach-webhook-1"
    assert started_event.payload.run_id == "run-attach-webhook"
    assert started_event.payload.source == "attach-bridge"
    assert started_event.payload.payload.attach_bridge.streaming_metadata.stream_url == "wss://stream.example/attach"
    assert started_event.payload.payload.attach_bridge.connection.lifecycle == "connected"
    assert started_event.payload.payload.attach_bridge.connection.connected_at == "2026-07-31T10:00:00Z"
    assert started_event.payload.payload.session_id == "session-1"

    deduped_event = Enum.find(events, &(&1.event_type == "InboxItemDeduped"))
    assert deduped_event.payload.correlation_id == "attach-bridge:attach-webhook-1"
    assert deduped_event.payload.run_id == "run-attach-webhook"
    assert deduped_event.payload.source == "attach-bridge"
  end

  defp attach_bridge_payload(run_id, event_id) do
    %{
      "run_id" => run_id,
      "worker_id" => "worker-1",
      "phase_id" => "developer",
      "event_id" => event_id,
      "event_type" => "connection.connected",
      "timestamp" => "2026-07-31T10:00:05Z",
      "status" => "connected",
      "session_id" => "session-1",
      "streaming_metadata" => %{
        "stream_url" => "wss://stream.example/attach",
        "session_path" => "/sessions/session-1",
        "protocol" => "jsonl",
        "pty" => true
      },
      "connection" => %{
        "connection_id" => "conn-1",
        "state" => "connected",
        "lifecycle" => "connected",
        "opened_at" => "2026-07-31T10:00:00Z",
        "reason" => "worker-attached"
      }
    }
  end
end
