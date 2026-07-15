defmodule ForemanServer.InboxTest do
  use ExUnit.Case

  alias ForemanServer.{CommandRouter, EventStore, Inbox, ProjectionStore, RunActor, WorkflowInterpreter}

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-inbox-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    event_log_path = Path.join(tmp_dir, "events.term.log")

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, event_log_path)
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    {:ok, fixture: fixture(), event_log_path: event_log_path}
  end

  test "configured phase mail hooks append from real phase lifecycle", %{fixture: fixture} do
    workflow = %{
      phase_order: [fixture["phase_id"], "phase-done"],
      retry_rules: %{},
      mail_hooks: %{fixture["phase_id"] => fixture["hooks"], "phase-done" => %{}}
    }

    assert {:ok, _pid} = WorkflowInterpreter.start_run(fixture["run_id"], workflow)
    assert [%{body: "Build phase started", hook: "phase_started"}] = Inbox.list(fixture["run_id"])

    assert {:ok, _state} = RunActor.pass(fixture["run_id"], %{ok: true})

    bodies = Inbox.list(fixture["run_id"]) |> Enum.map(& &1.body)
    assert "Build phase completed" in bodies
  end

  test "default workflow-shaped mail hooks map to phase lifecycle inbox messages" do
    assert {:ok, workflow} =
             WorkflowInterpreter.load_yaml("""
             name: inbox-default-shape
             phases:
               - name: build
                 prompt: build.md
                 mail:
                   onStart: true
                   onComplete: true
                   onFail: developer
               - name: done
                 prompt: done.md
             """)

    assert {:ok, _pid} = WorkflowInterpreter.start_run("run-default-mail", workflow)

    assert [%{hook: "phase_started", body: "PhaseStarted run-default-mail/build"}] =
             Inbox.list("run-default-mail")

    assert {:ok, _state} = RunActor.pass("run-default-mail", %{ok: true})

    messages = Inbox.list("run-default-mail")
    assert Enum.any?(messages, &(&1.hook == "phase_completed" and &1.phase_id == "build"))

    assert {:ok, _pid} = WorkflowInterpreter.start_run("run-default-mail-fail", workflow)
    assert {:ok, _state} = RunActor.fail("run-default-mail-fail", %{reason: "boom"})

    failed_messages = Inbox.list("run-default-mail-fail")
    assert Enum.any?(failed_messages, &(&1.hook == "phase_failed" and &1.phase_id == "build"))
    assert Enum.any?(failed_messages, &(&1.hook == "phase_failed" and &1.to == "developer"))
  end

  test "configured failure mail hook appends from real phase failure", %{fixture: fixture} do
    run_id = "#{fixture["run_id"]}-failed"

    workflow = %{
      phase_order: [fixture["phase_id"]],
      retry_rules: %{},
      mail_hooks: %{fixture["phase_id"] => fixture["hooks"]}
    }

    assert {:ok, _pid} = WorkflowInterpreter.start_run(run_id, workflow)
    assert {:ok, _state} = RunActor.fail(run_id, %{reason: "boom"})

    messages = Inbox.list(run_id)
    assert Enum.any?(messages, &(&1.body == "Build phase started" and &1.hook == "phase_started"))
    assert Enum.any?(messages, &(&1.body == "Build phase failed" and &1.hook == "phase_failed"))
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
    start_run_event("run-inbox-2")

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

  test "inbox.send command appends event-backed message with agent fields" do
    start_run_event("run-command-inbox")

    assert {:ok, %{event: event, inbox: message}} =
             CommandRouter.handle(%{
               command_id: "msg-command-1",
               command_type: "inbox.send",
               payload: %{
                 run_id: "run-command-inbox",
                 sender_agent_type: "developer",
                 recipient_agent_type: "qa",
                 subject: "handoff",
                 body: ~s({"message":"please review"}),
                 worker_supports_receiving: true
               }
             })

    assert event.event_type == "InboxMessageAppended"
    assert message.message_id == "msg-command-1"
    assert message.sender_agent_type == "developer"
    assert message.recipient_agent_type == "qa"
    assert message.subject == "handoff"

    assert [%{body: ~s({"message":"please review"}), subject: "handoff"}] =
             Inbox.list("run-command-inbox")
  end

  test "inbox messages are returned in chronological order (oldest first)" do
    start_run_event("run-order-test")

    # Send messages sequentially - each should have a slightly later timestamp
    assert {:ok, %{result: _msg1}} =
             Inbox.send_operator_message(%{
               message_id: "msg-order-1",
               run_id: "run-order-test",
               body: "first message"
             })

    # Small delay to ensure different timestamps
    :timer.sleep(10)

    assert {:ok, %{result: _msg2}} =
             Inbox.send_operator_message(%{
               message_id: "msg-order-2",
               run_id: "run-order-test",
               body: "second message"
             })

    :timer.sleep(10)

    assert {:ok, %{result: _msg3}} =
             Inbox.send_operator_message(%{
               message_id: "msg-order-3",
               run_id: "run-order-test",
               body: "third message"
             })

    messages = Inbox.list("run-order-test")

    # Verify messages are returned in chronological order (oldest first)
    assert Enum.map(messages, & &1.message_id) == ["msg-order-1", "msg-order-2", "msg-order-3"]
    assert Enum.map(messages, & &1.body) == ["first message", "second message", "third message"]
  end

  test "inbox watch streams new messages without polling full history" do
    start_run_event("run-watch-1")

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

  test "projection rebuild does not replay historical inbox updates to active watchers" do
    start_run_event("run-watch-rebuild")

    assert {:ok, 0} = Inbox.subscribe("run-watch-rebuild")

    assert {:ok, _result} =
             Inbox.send_operator_message(%{
               message_id: "msg-watch-rebuild-1",
               run_id: "run-watch-rebuild",
               body: "live only"
             })

    assert_receive {:inbox_update, "run-watch-rebuild", _update}, 250
    refute_receive {:inbox_update, "run-watch-rebuild", _update}, 50

    assert {:ok, _rebuilt} = EventStore.rebuild_projections()
    refute_receive {:inbox_update, "run-watch-rebuild", _update}, 100
  end

  test "restart replay preserves inbox messages and delivery status", %{
    event_log_path: event_log_path
  } do
    start_run_event("run-restart-1")

    assert {:ok, _message} =
             Inbox.send_operator_message(%{
               message_id: "msg-restart-1",
               run_id: "run-restart-1",
               body: "persist me",
               worker_supports_receiving: true
             })

    assert {:ok, _delivery} =
             Inbox.update_delivery(%{message_id: "msg-restart-1", delivery_status: "delivered"})

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, event_log_path)
    assert :ok = Application.start(:foreman_server)

    assert [%{message_id: "msg-restart-1", body: "persist me", delivery_status: "delivered"}] =
             Inbox.list("run-restart-1")
  end

  test "operator message rejects inactive or missing runs before side effects" do
    assert {:error, {:run_not_found, "missing-run"}} =
             Inbox.send_operator_message(%{run_id: "missing-run", body: "hello"})

    assert Inbox.list("missing-run") == []

    start_run_event("run-terminal-1")
    complete_run_event("run-terminal-1")

    assert {:error, {:run_not_active, "run-terminal-1"}} =
             Inbox.send_operator_message(%{run_id: "run-terminal-1", body: "hello"})

    assert Inbox.list("run-terminal-1") == []
  end

  test "invalid inputs fail cleanly without partial phase hook append", %{fixture: fixture} do
    assert {:error, {:missing_or_invalid, :body}} =
             Inbox.send_operator_message(%{"run_id" => "run-input-1"})

    assert {:error, {:missing_or_invalid, :message_id}} =
             Inbox.update_delivery(%{"delivery_status" => "delivered"})

    duplicate_hooks = %{
      "phase_started" => [
        %{"message_id" => "dup-hook", "body" => "one"},
        %{"message_id" => "dup-hook", "body" => "two"}
      ]
    }

    assert {:error, :duplicate_message_id} =
             Inbox.append_phase_mail(
               "PhaseStarted",
               %{"run_id" => fixture["run_id"], "phase_id" => fixture["phase_id"]},
               duplicate_hooks
             )

    assert Inbox.list(fixture["run_id"]) == []
  end

  defp start_run_event(run_id) do
    EventStore.append(%{
      stream_id: "run:#{run_id}",
      event_type: "RunStarted",
      payload: %{
        run_id: run_id,
        phase_order: ["phase-1"],
        current_phase: "phase-1"
      },
      metadata: %{
        correlation_id: run_id,
        idempotency_key: "run-started:#{run_id}"
      }
    })
  end

  defp complete_run_event(run_id) do
    EventStore.append(%{
      stream_id: "run:#{run_id}",
      event_type: "RunCompleted",
      payload: %{run_id: run_id},
      metadata: %{
        correlation_id: run_id,
        idempotency_key: "run-completed:#{run_id}"
      }
    })
  end

  defp fixture do
    "test/fixtures/inbox-mail-hooks.json"
    |> File.read!()
    |> Jason.decode!()
  end
end
