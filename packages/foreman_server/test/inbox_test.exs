defmodule ForemanServer.InboxTest do
  use ExUnit.Case

  alias ForemanServer.{EventStore, Inbox, ProjectionStore}

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-inbox-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    {:ok, fixture: fixture()}
  end

  test "phase mail hooks append durable messages and project to inbox", %{fixture: fixture} do
    assert {:ok, [%{result: message}]} =
             Inbox.append_phase_mail(
               "PhaseStarted",
               %{run_id: fixture["run_id"], phase_id: fixture["phase_id"]},
               fixture["hooks"]
             )

    assert message.body == "Build phase started"
    assert message.delivery_status == "appended"

    inbox = Inbox.list(fixture["run_id"])
    assert [%{body: "Build phase started", hook: "phase_started"}] = inbox

    assert {:ok, rebuilt} = EventStore.rebuild_projections()
    assert rebuilt.inbox_messages[message.message_id].body == "Build phase started"
  end

  test "operator messages to active runs track delivery status" do
    assert {:ok, _event} =
             EventStore.append(%{
               stream_id: "run:run-inbox-2",
               event_type: "RunStarted",
               payload: %{
                 run_id: "run-inbox-2",
                 phase_order: ["phase-1"],
                 current_phase: "phase-1"
               },
               metadata: %{
                 correlation_id: "run-inbox-2",
                 idempotency_key: "run-started:run-inbox-2"
               }
             })

    assert {:ok, %{result: queued}} =
             Inbox.send_operator_message(%{
               message_id: "msg-operator-1",
               run_id: "run-inbox-2",
               phase_id: "phase-1",
               body: "please retry with more context",
               worker_supports_receiving: true
             })

    assert queued.delivery_status == "queued"
    assert ProjectionStore.snapshot().inbox_messages["msg-operator-1"].delivery_status == "queued"

    assert {:ok, %{result: delivered}} =
             Inbox.update_delivery(%{message_id: "msg-operator-1", delivery_status: "delivered"})

    assert delivered.delivery_status == "delivered"

    assert ProjectionStore.snapshot().inbox_messages["msg-operator-1"].delivery_status ==
             "delivered"
  end

  test "inbox watch streams new messages without polling full history" do
    assert {:ok, _event} =
             EventStore.append(%{
               stream_id: "run:run-watch-1",
               event_type: "RunStarted",
               payload: %{
                 run_id: "run-watch-1",
                 phase_order: ["phase-1"],
                 current_phase: "phase-1"
               },
               metadata: %{
                 correlation_id: "run-watch-1",
                 idempotency_key: "run-started:run-watch-1"
               }
             })

    assert {:ok, 0} = Inbox.subscribe("run-watch-1")

    assert {:ok, %{result: message}} =
             Inbox.send_operator_message(%{
               message_id: "msg-watch-1",
               run_id: "run-watch-1",
               body: "watch me",
               worker_supports_receiving: false
             })

    assert_receive {:inbox_update, "run-watch-1", update}, 250
    assert update.message_id == message.message_id
    assert update.delivery_status == "unsupported"
    assert Inbox.list("run-watch-1") |> Enum.map(& &1.message_id) == ["msg-watch-1"]
  end

  test "operator message rejects inactive or missing runs before side effects" do
    assert {:error, {:run_not_found, "missing-run"}} =
             Inbox.send_operator_message(%{run_id: "missing-run", body: "hello"})

    assert Inbox.list("missing-run") == []
  end

  defp fixture do
    "test/fixtures/inbox-mail-hooks.json"
    |> File.read!()
    |> Jason.decode!()
  end
end
