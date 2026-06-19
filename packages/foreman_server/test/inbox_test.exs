defmodule ForemanServer.InboxTest do
  use ExUnit.Case

  alias ForemanServer.{EventStore, Inbox, ProjectionStore, RunActor, WorkflowInterpreter}

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
    messages = Inbox.list(fixture["run_id"])
    assert Enum.any?(messages, &(&1.body == "Build phase started" and &1.hook == "phase_started"))

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

    default_messages = Inbox.list("run-default-mail")

    assert Enum.any?(
             default_messages,
             &(Map.get(&1, :hook) == "phase_started" and
                 &1.body == "PhaseStarted run-default-mail/build")
           )

    assert {:ok, _state} = RunActor.pass("run-default-mail", %{ok: true})

    messages = Inbox.list("run-default-mail")

    assert Enum.any?(
             messages,
             &(Map.get(&1, :hook) == "phase_completed" and &1.phase_id == "build")
           )

    assert {:ok, _pid} = WorkflowInterpreter.start_run("run-default-mail-fail", workflow)
    assert {:ok, _state} = RunActor.fail("run-default-mail-fail", %{reason: "boom"})

    failed_messages = Inbox.list("run-default-mail-fail")

    assert Enum.any?(
             failed_messages,
             &(Map.get(&1, :hook) == "phase_failed" and &1.phase_id == "build")
           )

    assert Enum.any?(
             failed_messages,
             &(Map.get(&1, :hook) == "phase_failed" and &1.to == "developer")
           )
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

    terminal_messages = Inbox.list("run-terminal-1")
    assert Enum.any?(terminal_messages, &(&1.activity_type == "run_completed"))
    refute Enum.any?(terminal_messages, &(&1.body == "hello"))
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

  describe "unified activity feed" do
    test "append_activity_event creates activity entry in inbox" do
      start_run_event("run-activity-1")

      assert {:ok, %{result: activity}} =
               Inbox.append_activity_event("worker_started", %{
                 run_id: "run-activity-1",
                 phase: "explorer",
                 severity: "info",
                 summary: "Worker started for explorer phase"
               })

      assert activity.body == "Worker started for explorer phase"
      assert activity.direction == "system"
      assert activity.activity_type == "worker_started"

      inbox = Inbox.list("run-activity-1")
      assert length(inbox) == 1
      assert hd(inbox).activity_type == "worker_started"
    end

    test "activity feed includes RunCompleted terminal event" do
      start_workflow_run("run-complete-activity")

      # Complete the run
      assert {:ok, _state} = RunActor.pass("run-complete-activity", %{ok: true})

      inbox = Inbox.list("run-complete-activity")
      assert Enum.any?(inbox, &(&1.activity_type == "run_completed"))
      completed = Enum.find(inbox, &(&1.activity_type == "run_completed"))
      assert completed.severity == "info"
    end

    test "activity feed includes RunFailed terminal event" do
      start_workflow_run("run-fail-activity")

      # Fail the run
      assert {:ok, _state} = RunActor.fail("run-fail-activity", %{reason: "test failure"})

      inbox = Inbox.list("run-fail-activity")
      assert Enum.any?(inbox, &(&1.activity_type == "run_failed"))
      failed = Enum.find(inbox, &(&1.activity_type == "run_failed"))
      assert failed.severity == "error"
      assert failed.body =~ "Run failed"
    end

    test "activity feed captures lifecycle events when visible messages stop before merge" do
      # Simulates foreman-93180/foreman-29707 style history where agent messages stop
      # but lifecycle events should still appear in activity feed
      start_run_event("run-no-messages-before-fail")

      # Directly append RunFailed event (simulating scenario where agent messages stopped)
      EventStore.append(%{
        stream_id: "run:run-no-messages-before-fail",
        event_type: "RunFailed",
        payload: %{
          run_id: "run-no-messages-before-fail",
          phase_id: "developer",
          reason: "agent stopped responding"
        },
        metadata: %{correlation_id: "run-no-messages-before-fail"}
      })

      inbox = Inbox.list("run-no-messages-before-fail")
      # Activity feed should capture the failure even without agent messages
      assert Enum.any?(inbox, &(&1.activity_type == "run_failed"))
    end

    test "PhaseRetried creates activity entry in inbox" do
      start_run_event("run-retry-activity")

      # Append PhaseRetried event directly
      EventStore.append(%{
        stream_id: "run:run-retry-activity",
        event_type: "PhaseRetried",
        payload: %{
          run_id: "run-retry-activity",
          phase_id: "developer",
          attempt: 2,
          reason: "PhaseFailed"
        },
        metadata: %{correlation_id: "run-retry-activity"}
      })

      inbox = Inbox.list("run-retry-activity")
      assert Enum.any?(inbox, &(&1.activity_type == "phase_retried"))
      retried = Enum.find(inbox, &(&1.activity_type == "phase_retried"))
      assert retried.severity == "warning"
    end

    test "RetryLoop creates activity entry in inbox" do
      start_run_event("run-retry-loop-activity")

      # Append RetryLoop event directly
      EventStore.append(%{
        stream_id: "run:run-retry-loop-activity",
        event_type: "RetryLoop",
        payload: %{
          run_id: "run-retry-loop-activity",
          phase_id: "developer",
          attempt: 3,
          reason: "PhaseFailed"
        },
        metadata: %{correlation_id: "run-retry-loop-activity"}
      })

      inbox = Inbox.list("run-retry-loop-activity")
      assert Enum.any?(inbox, &(&1.activity_type == "retry_loop"))
      retried = Enum.find(inbox, &(&1.activity_type == "retry_loop"))
      assert retried.severity == "warning"
      assert retried.body =~ "developer"
      assert retried.body =~ "attempt 3"
    end

    test "PrMerged creates activity entry in inbox" do
      start_workflow_run("run-pr-merge-activity")

      # Append PrMerged event directly
      EventStore.append(%{
        stream_id: "run:run-pr-merge-activity",
        event_type: "PrMerged",
        payload: %{
          run_id: "run-pr-merge-activity",
          pr_id: "PR-123"
        },
        metadata: %{correlation_id: "run-pr-merge-activity"}
      })

      inbox = Inbox.list("run-pr-merge-activity")
      assert Enum.any?(inbox, &(&1.activity_type == "pr_merged"))
      merged = Enum.find(inbox, &(&1.activity_type == "pr_merged"))
      assert merged.body == "PR PR-123 merged"
    end

    test "activity feed includes WorkerStarted lifecycle event" do
      start_run_event("run-worker-activity")

      # Append WorkerStarted event
      EventStore.append(%{
        stream_id: "run:run-worker-activity",
        event_type: "WorkerStarted",
        payload: %{
          run_id: "run-worker-activity",
          worker_id: "worker-1",
          phase_id: "explorer",
          adapter: "pi-sdk"
        },
        metadata: %{correlation_id: "run-worker-activity"}
      })

      inbox = Inbox.list("run-worker-activity")
      assert Enum.any?(inbox, &(&1.activity_type == "worker_started"))
      started = Enum.find(inbox, &(&1.activity_type == "worker_started"))
      assert started.actor == "pi-sdk"
    end

    test "invalid activity event type fails cleanly" do
      start_run_event("run-invalid-activity")

      assert {:error, {:invalid_activity_event_type, "invalid_type"}} =
               Inbox.append_activity_event("invalid_type", %{run_id: "run-invalid-activity"})

      assert Inbox.list("run-invalid-activity") == []
    end

    test "WorkerExited creates activity entry in inbox" do
      start_run_event("run-worker-exit-activity")

      EventStore.append(%{
        stream_id: "run:run-worker-exit-activity",
        event_type: "WorkerExited",
        payload: %{
          run_id: "run-worker-exit-activity",
          worker_id: "worker-1",
          adapter: "pi-sdk",
          exit_code: 0
        },
        metadata: %{correlation_id: "run-worker-exit-activity"}
      })

      inbox = Inbox.list("run-worker-exit-activity")
      assert Enum.any?(inbox, &(&1.activity_type == "worker_exit"))
      exited = Enum.find(inbox, &(&1.activity_type == "worker_exit"))
      assert exited.actor == "pi-sdk"
      assert exited.severity == "info"
    end

    test "QaVerdict creates activity entry with correct severity" do
      start_run_event("run-qa-verdict-activity")

      EventStore.append(%{
        stream_id: "run:run-qa-verdict-activity",
        event_type: "QaVerdict",
        payload: %{
          run_id: "run-qa-verdict-activity",
          verdict: "fail",
          phase: "qa",
          failure_reasons: ["test timeout"]
        },
        metadata: %{correlation_id: "run-qa-verdict-activity"}
      })

      inbox = Inbox.list("run-qa-verdict-activity")
      assert Enum.any?(inbox, &(&1.activity_type == "qa_verdict"))
      verdict = Enum.find(inbox, &(&1.activity_type == "qa_verdict"))
      assert verdict.actor == "qa"
      assert verdict.severity == "error"
      assert verdict.body =~ "fail"
    end

    test "ReviewFinding creates activity entry with blocking severity" do
      start_run_event("run-review-finding-activity")

      EventStore.append(%{
        stream_id: "run:run-review-finding-activity",
        event_type: "ReviewFinding",
        payload: %{
          run_id: "run-review-finding-activity",
          finding: "missing test coverage",
          severity: "blocking",
          phase: "review"
        },
        metadata: %{correlation_id: "run-review-finding-activity"}
      })

      inbox = Inbox.list("run-review-finding-activity")
      assert Enum.any?(inbox, &(&1.activity_type == "review_finding"))
      finding = Enum.find(inbox, &(&1.activity_type == "review_finding"))
      assert finding.actor == "reviewer"
      assert finding.severity == "error"
      assert finding.body =~ "missing test coverage"
    end

    test "PrCreated creates activity entry in inbox" do
      start_run_event("run-pr-created-activity")

      EventStore.append(%{
        stream_id: "run:run-pr-created-activity",
        event_type: "PrCreated",
        payload: %{
          run_id: "run-pr-created-activity",
          pr_id: "PR-456",
          source_link: "https://github.com/org/repo/pull/456"
        },
        metadata: %{correlation_id: "run-pr-created-activity"}
      })

      inbox = Inbox.list("run-pr-created-activity")
      assert Enum.any?(inbox, &(&1.activity_type == "pr_created"))
      created = Enum.find(inbox, &(&1.activity_type == "pr_created"))
      assert created.actor == "vcs"
      assert created.severity == "info"
      assert created.body == "PR PR-456 created"
    end

    test "SchedulerClaim creates activity entry in inbox" do
      start_run_event("run-scheduler-claim-activity")

      EventStore.append(%{
        stream_id: "run:run-scheduler-claim-activity",
        event_type: "SchedulerClaim",
        payload: %{
          run_id: "run-scheduler-claim-activity"
        },
        metadata: %{correlation_id: "run-scheduler-claim-activity"}
      })

      inbox = Inbox.list("run-scheduler-claim-activity")
      assert Enum.any?(inbox, &(&1.activity_type == "scheduler_claim"))
      claimed = Enum.find(inbox, &(&1.activity_type == "scheduler_claim"))
      assert claimed.actor == "scheduler"
      assert claimed.severity == "info"
    end

    test "manual TaskUpdated creates activity entry in inbox" do
      start_run_event("run-task-update-activity")

      # Append a TaskUpdated event with run_id (manual update)
      EventStore.append(%{
        stream_id: "task:foreman-task-update",
        event_type: "TaskUpdated",
        payload: %{
          task_id: "foreman-task-update",
          run_id: "run-task-update-activity",
          status: "in_progress",
          updated_by: "operator"
        },
        metadata: %{correlation_id: "run-task-update-activity"}
      })

      inbox = Inbox.list("run-task-update-activity")
      assert Enum.any?(inbox, &(&1.activity_type == "task_updated"))
      updated = Enum.find(inbox, &(&1.activity_type == "task_updated"))
      assert updated.actor == "operator"
    end

    test "TaskUpdated without run_id does not create activity entry" do
      start_run_event("run-task-update-no-run-id")

      # Append a TaskUpdated event WITHOUT run_id field (event not linked to a run)
      EventStore.append(%{
        stream_id: "task:foreman-task-orphan",
        event_type: "TaskUpdated",
        payload: %{
          task_id: "foreman-task-orphan",
          status: "in_progress",
          updated_by: "operator"
        },
        metadata: %{correlation_id: "run-task-update-no-run-id"}
      })

      inbox = Inbox.list("run-task-update-no-run-id")
      refute Enum.any?(inbox, &(&1.activity_type == "task_updated"))
    end
  end

  defp start_workflow_run(run_id) do
    assert {:ok, _pid} =
             WorkflowInterpreter.start_run(run_id, %{
               phase_order: ["phase-1"],
               retry_rules: %{},
               mail_hooks: %{}
             })
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
