defmodule ForemanServer.IngestionTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  @opts ForemanServer.Http.Router.init([])

  alias ForemanServer.EventStore
  alias ForemanServer.ProjectionStore

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    tmp_dir = Path.join(System.tmp_dir!(), "foreman-ingestion-test-#{suffix}")

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    Application.put_env(:foreman_server, :auth_token, "secret")
    :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      File.rm_rf!(tmp_dir)
      Application.delete_env(:foreman_server, :event_log_path)
      Application.delete_env(:foreman_server, :auth_token)
      :ok = Application.start(:foreman_server)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  # TRD-033-TEST: integration ingestion webhook → routed through SharedInbox/Poller
  test "POST /webhooks/external_trigger ingests item and records delivery_status in projection" do
    payload = %{"run_id" => "run-ingestion-001", "trigger_id" => "test-trigger-001", "source" => "test"}

    conn =
      :post
      |> conn("/webhooks/external_trigger", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 202
    body = Jason.decode!(conn.resp_body)
    assert body["event_type"] == "InboxItemStarted"

    events = EventStore.stream("inbox:run-ingestion-001")
    started = Enum.find(events, &(&1.event_type == "InboxItemStarted"))
    assert started != nil
    # ExternalTriggerCorrelationId returns the raw dedupe field value, no prefix
    assert started.payload.correlation_id == "test-trigger-001"
    assert started.payload.run_id == "run-ingestion-001"
    assert started.payload.source == "test"

    # delivery_status tracked in projection store under the correlation_id key
    assert ProjectionStore.snapshot().inbox_messages["test-trigger-001"].delivery_status ==
             "started"
  end
end
