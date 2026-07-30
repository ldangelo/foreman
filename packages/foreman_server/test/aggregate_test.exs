defmodule ForemanServer.AggregateTest do
  use ExUnit.Case

  alias ForemanServer.{Aggregate, AggregateRouter, CommandRouter, EventStore}
  alias ForemanServer.Inbox.SharedInbox

  alias ForemanServer.Aggregates.{
    BoardItemStateMachine,
    InboxThread,
    Integration,
    Phase,
    PlanningFlow,
    Project,
    Recovery,
    Run,
    Scheduler,
    Task,
    VcsOperation,
    Worker
  }

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-aggregate-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    assert :ok = Application.start(:foreman_server)
    :ok
  end

  # Fixed impl for SharedInbox dedupe test — stable correlation_id
  defmodule SharedInboxDedupeImpl do
    @behaviour ForemanServer.Inbox.InboxItemCorrelationId
    @correlation_id "dedupe-test-correlation-#{:rand.uniform(999_999)}"

    @impl true
    def correlation_id(_payload), do: @correlation_id
  end

  test "project aggregate State struct is built by fold from ProjectRegistered and updated by ProjectUpdated" do
    events = [
      %{
        event_type: "ProjectRegistered",
        payload: %{
          project_id: "proj-struct",
          path: "/tmp/proj-struct",
          status: "active",
          default_branch: "develop",
          config: %{key: "val"},
          health: %{ok: false}
        }
      },
      %{
        event_type: "ProjectUpdated",
        payload: %{project_id: "proj-struct", status: "paused", config: %{extra: "added"}}
      },
      %{event_type: "ProjectArchived", payload: %{project_id: "proj-struct"}}
    ]

    state = Aggregate.fold(Project, events)

    assert %Project.State{} = state
    assert state.exists? == true
    assert state.project_id == "proj-struct"
    assert state.path == "/tmp/proj-struct"
    assert state.status == "archived"
    assert state.default_branch == "develop"
    assert state.config == %{key: "val", extra: "added"}
    assert state.archived? == true
  end

  test "project aggregate rejects duplicate registrations and validates updates" do
    assert {:ok, %{event: %{event_type: "ProjectRegistered"}}} =
             CommandRouter.handle(%{
               command_id: "project-register-1",
               command_type: "project.register",
               payload: %{project_id: "proj-agg", path: "/tmp/proj-agg"}
             })

    assert {:error, {:already_exists, :project, "proj-agg"}} =
             CommandRouter.handle(%{
               command_id: "project-register-duplicate",
               command_type: "project.register",
               payload: %{project_id: "proj-agg", path: "/tmp/proj-agg"}
             })

    assert {:error, {:invalid_project_status, "unknown"}} =
             AggregateRouter.route("project.update", %{project_id: "proj-agg", status: "unknown"})
  end

  test "task aggregate validates lifecycle and preserves existing event names" do
    assert {:ok, %{event: %{event_type: "TaskCreated"}}} =
             CommandRouter.handle(%{
               command_id: "task-create-1",
               command_type: "task.create",
               payload: %{task_id: "task-agg", title: "Aggregate task", project_id: "test"}
             })

    assert {:ok, %{event: %{event_type: "TaskUpdated"}, projection: projection}} =
             CommandRouter.handle(%{
               command_id: "task-approve-1",
               command_type: "task.approve",
               payload: %{task_id: "task-agg"}
             })

    assert projection.tasks["task-agg"].status == "ready"

    assert {:ok, %{event: %{event_type: "TaskUpdated"}}} =
             CommandRouter.handle(%{
               command_id: "task-close-1",
               command_type: "task.close",
               payload: %{task_id: "task-agg"}
             })

    closed_state =
      Aggregate.fold(Task, [
        %{event_type: "TaskCreated", payload: %{task_id: "closed-task", status: "open"}},
        %{event_type: "TaskUpdated", payload: %{task_id: "closed-task", status: "closed"}}
      ])

    assert {:ok,
            %{
              event_type: "TaskUpdated",
              payload: %{task_id: "closed-task", status: "ready"}
            }} =
             Task.handle_command(closed_state, %{
               type: "task.approve",
               payload: %{task_id: "closed-task"}
             })

    merged_state =
      Aggregate.fold(Task, [
        %{event_type: "TaskCreated", payload: %{task_id: "merged-task", status: "open"}},
        %{event_type: "TaskUpdated", payload: %{task_id: "merged-task", status: "merged"}}
      ])

    assert {:error, {:invalid_task_transition, "merged", "ready"}} =
             Task.handle_command(merged_state, %{
               type: "task.approve",
               payload: %{task_id: "merged-task"}
             })

    assert {:error, :self_dependency} =
             AggregateRouter.route("task.add_dependency", %{
               task_id: "task-agg",
               depends_on: "task-agg"
             })
  end

  test "aggregate decisions carry expected stream version for optimistic concurrency" do
    assert {:ok, spec} =
             AggregateRouter.route("task.create", %{task_id: "task-versioned", project_id: "test"})

    assert spec.expected_stream_version == 0

    assert {:ok, event} = EventStore.append(spec)
    assert event.stream_version == 1

    stale_spec = %{spec | payload: Map.put(spec.payload, :title, "stale")}
    assert {:error, {:conflict, [expected: 0, actual: 1]}} = EventStore.append(stale_spec)
  end

  test "run and phase aggregates reject invalid transitions" do
    assert {:ok, %{event: %{event_type: "RunStarted"}}} =
             CommandRouter.handle(%{
               command_id: "run-start-1",
               command_type: "run.start",
               payload: %{run_id: "run-agg", task_id: "task-agg"}
             })

    assert {:ok, %{event: %{event_type: "RunDeleted"}}} =
             CommandRouter.handle(%{
               command_id: "run-delete-1",
               command_type: "run.delete",
               payload: %{run_id: "run-agg"}
             })

    assert {:error, {:run_terminal, "deleted"}} =
             CommandRouter.handle(%{
               command_id: "run-update-terminal",
               command_type: "run.update",
               payload: %{run_id: "run-agg", status: "in_progress"}
             })

    assert {:error, :phase_not_started} =
             AggregateRouter.route("phase.complete", %{run_id: "run-agg", phase_id: "dev"})

    assert {:ok, start_spec} =
             AggregateRouter.route("phase.start", %{run_id: "run-agg", phase_id: "dev"})

    assert {:ok, _} = EventStore.append(start_spec)

    assert {:ok, complete_spec} =
             AggregateRouter.route("phase.complete", %{run_id: "run-agg", phase_id: "dev"})

    assert complete_spec.event_type == "PhaseCompleted"
  end

  test "run aggregate allows delete on terminal runs but rejects already-deleted" do
    # Start a run
    assert {:ok, %{event: %{event_type: "RunStarted"}}} =
             CommandRouter.handle(%{
               command_id: "run-terminal-delete-1",
               command_type: "run.start",
               payload: %{run_id: "run-terminal-delete", task_id: "task-terminal"}
             })

    # Fail the run
    assert {:ok, %{event: %{event_type: "RunFailed"}}} =
             CommandRouter.handle(%{
               command_id: "run-terminal-delete-2",
               command_type: "run.fail",
               payload: %{run_id: "run-terminal-delete"}
             })

    # Delete of failed run should succeed (cleanup/tombstoning)
    assert {:ok, %{event: %{event_type: "RunDeleted"}}} =
             CommandRouter.handle(%{
               command_id: "run-terminal-delete-3",
               command_type: "run.delete",
               payload: %{run_id: "run-terminal-delete"}
             })

    # Second delete should fail (already deleted)
    assert {:error, {:run_terminal, "deleted"}} =
             CommandRouter.handle(%{
               command_id: "run-terminal-delete-4",
               command_type: "run.delete",
               payload: %{run_id: "run-terminal-delete"}
             })

    # Update on deleted run should still fail
    assert {:error, {:run_terminal, "deleted"}} =
             CommandRouter.handle(%{
               command_id: "run-terminal-delete-5",
               command_type: "run.update",
               payload: %{run_id: "run-terminal-delete"}
             })
  end

  test "run PR lifecycle commands validate payloads and emit PR events" do
    cases = [
      {
        "run.pr.update",
        "PrUpdated",
        "run-pr-update",
        pr_payload(%{head_sha: "sha-update", base_branch: "main", phase: "developer"}),
        [:run_id, :project_id, :task_id, :pr_url, :branch_name, :head_sha, :base_branch, :phase]
      },
      {
        "run.pr.ready",
        "PrReady",
        "run-pr-ready",
        pr_payload(%{head_sha: "sha-ready", base_branch: "main"}),
        [:run_id, :project_id, :task_id, :pr_url, :branch_name, :head_sha, :base_branch]
      },
      {
        "run.pr.retarget",
        "PrRetargeted",
        "run-pr-retarget",
        pr_payload(%{
          head_sha: "sha-retarget",
          old_base_branch: "foreman/parent",
          new_base_branch: "main"
        }),
        [
          :run_id,
          :project_id,
          :task_id,
          :pr_url,
          :branch_name,
          :old_base_branch,
          :new_base_branch,
          :head_sha
        ]
      },
      {
        "run.pr.reset",
        "PrReset",
        "run-pr-reset",
        pr_payload(%{action: "closed", reason: "reset superseded the PR"}),
        [:run_id, :project_id, :task_id, :pr_url, :branch_name, :action, :reason]
      },
      {
        "run.pr.merge",
        "PrMerged",
        "run-pr-merge",
        pr_payload(%{
          merged_at: "2026-07-09T12:34:56Z",
          merge_commit_sha: "merge-sha"
        }),
        [:run_id, :project_id, :task_id, :pr_url, :branch_name]
      }
    ]

    Enum.each(cases, fn {command_type, event_type, run_id, payload, required_fields} ->
      started_run!(run_id)

      assert {:ok, %{event_type: ^event_type, stream_id: stream_id, payload: event_payload}} =
               AggregateRouter.route(command_type, Map.put(payload, :run_id, run_id))

      assert stream_id == "run:#{run_id}"
      assert event_payload.run_id == run_id
      assert event_payload.project_id == "project-1"
      assert event_payload.task_id == "task-1"
      assert event_payload.pr_url == "https://github.com/acme/foreman/pull/42"
      assert event_payload.branch_name == "foreman/task-1"
      assert Map.take(event_payload, Map.keys(payload)) == payload

      Enum.each(required_fields, fn missing_field ->
        assert {:error, {:missing_or_invalid, ^missing_field}} =
                 AggregateRouter.route(
                   command_type,
                   payload
                   |> Map.put(:run_id, run_id)
                   |> Map.delete(missing_field)
                 )
      end)
    end)

    started_run!("run-pr-merge-without-optional-metadata")

    assert {:ok, %{event_type: "PrMerged", payload: merge_payload}} =
             AggregateRouter.route(
               "run.pr.merge",
               pr_payload(%{}) |> Map.put(:run_id, "run-pr-merge-without-optional-metadata")
             )

    assert merge_payload.run_id == "run-pr-merge-without-optional-metadata"
    assert merge_payload.project_id == "project-1"

    started_run!("run-pr-reset-invalid-action")

    assert {:error, {:invalid_pr_reset_action, "kept"}} =
             AggregateRouter.route(
               "run.pr.reset",
               pr_payload(%{action: "kept", reason: "reset tried to preserve the PR"})
               |> Map.put(:run_id, "run-pr-reset-invalid-action")
             )
  end

  test "inbox aggregate validates duplicate messages and delivery targets" do
    assert {:ok, spec} =
             AggregateRouter.route("inbox.send", %{
               run_id: "run-inbox-agg",
               message_id: "msg-1",
               body: "hello"
             })

    assert {:ok, _} = EventStore.append(spec)

    assert {:error, {:already_exists, :message, "msg-1"}} =
             AggregateRouter.route("inbox.send", %{
               run_id: "run-inbox-agg",
               message_id: "msg-1",
               body: "hello again"
             })

    assert {:ok, delivery_spec} =
             AggregateRouter.route("inbox.delivery.update", %{
               run_id: "run-inbox-agg",
               message_id: "msg-1",
               delivery_status: "delivered"
             })

    assert delivery_spec.event_type == "InboxDeliveryUpdated"
  end

  test "SharedInbox.ingest/2 emits InboxItemStarted then InboxItemDeduped for same correlation_id" do
    impl = SharedInboxDedupeImpl

    payload1 = %{
      run_id: "run-shared-inbox-dedupe-#{:rand.uniform(999_999)}",
      source: "test-source",
      body: "first delivery attempt"
    }

    # First ingest — should start the item
    assert {:ok, %{event: started_event}} =
             SharedInbox.ingest(impl, payload1)

    assert started_event.event_type == "InboxItemStarted"
    assert started_event.payload.correlation_id == impl.correlation_id(payload1)

    Process.sleep(50)

    # Stream must have exactly one InboxItemStarted
    inbox_events = EventStore.stream("inbox:#{payload1.run_id}")
    started_events = Enum.filter(inbox_events, &(&1.event_type == "InboxItemStarted"))
    assert length(started_events) == 1

    # Second ingest with same correlation_id — should dedupe without re-processing
    payload2 = Map.put(payload1, :body, "retry with same correlation_id")

    assert {:ok, %{event: deduped_event, existing_item: existing}} =
             SharedInbox.ingest(impl, payload2)

    assert deduped_event.event_type == "InboxItemDeduped"
    assert deduped_event.payload.correlation_id == impl.correlation_id(payload1)

    # existing_item carries the original InboxItemStarted payload (the "existing delivery status")
    assert existing.correlation_id == impl.correlation_id(payload1)
    assert existing.payload.run_id == payload1.run_id

    # Verify dedupe hit: no second InboxItemStarted started, exactly one deduped event
    Process.sleep(50)
    final_events = EventStore.stream("inbox:#{payload1.run_id}")
    assert Enum.count(final_events, &(&1.event_type == "InboxItemStarted")) == 1
    assert Enum.count(final_events, &(&1.event_type == "InboxItemDeduped")) == 1
  end

  test "worker aggregate folds imported worker events and validates sequence" do
    events = [
      %{event_type: "WorkerStarted", payload: %{run_id: "run", worker_id: "w", sequence: 0}},
      %{event_type: "WorkerHeartbeat", payload: %{run_id: "run", worker_id: "w", sequence: 1}},
      %{event_type: "AssistantMessage", payload: %{run_id: "run", worker_id: "w", sequence: 2}}
    ]

    state = Aggregate.fold(Worker, events)
    assert state.last_sequence == 2
    assert Worker.next_sequence(state) == 3
    assert state.assistant_messages == 1
  end

  describe "legacy worker event replay" do
    # Regression: typed structs registered in EventCodec must tolerate legacy-shaped
    # payloads (no adapter, no sequence) without raising in from_payload/1, since
    # existing streams were written before the typed-struct migration.
    alias ForemanServer.Event

    defp worker_event(type, payload) do
      %Event{
        event_id: Ecto.UUID.generate(),
        stream_id: "worker-legacy:#{Ecto.UUID.generate()}",
        stream_version: 1,
        event_type: type,
        schema_version: 1,
        payload: payload,
        metadata: %{},
        occurred_at: DateTime.utc_now(),
        correlation_id: Ecto.UUID.generate()
      }
    end

    test "WorkerStarted without adapter or sequence does not raise" do
      evt = worker_event("WorkerStarted", %{"run_id" => "r", "worker_id" => "w", "phase_id" => "p"})
      state = Aggregate.fold(Worker, [evt])
      assert state.exists? == true
      assert state.run_id == "r"
      assert state.worker_id == "w"
    end

    test "WorkerStdout without sequence does not raise" do
      evt = worker_event("WorkerStdout", %{"run_id" => "r", "worker_id" => "w", "content" => "hi"})
      assert Aggregate.fold(Worker, [evt])
    end

    test "WorkerStderr without sequence does not raise" do
      evt = worker_event("WorkerStderr", %{"run_id" => "r", "worker_id" => "w", "content" => "err"})
      assert Aggregate.fold(Worker, [evt])
    end

    test "AssistantMessage without sequence does not raise" do
      evt = worker_event("AssistantMessage", %{"run_id" => "r", "worker_id" => "w", "message" => "hi"})
      assert Aggregate.fold(Worker, [evt])
    end

    test "typed WorkerStarted with adapter and sequence preserves all fields" do
      evt = worker_event("WorkerStarted", %{
        "run_id" => "r", "worker_id" => "w", "phase_id" => "p",
        "adapter" => "exec", "sequence" => 3
      })
      state = Aggregate.fold(Worker, [evt])
      assert state.exists? == true
      assert state.adapter == "exec"
      assert state.last_sequence == 3
    end
  end

  test "scheduler, vcs, recovery, and integration aggregates tolerate historical replay" do
    scheduler =
      Aggregate.fold(Scheduler, [
        %{event_type: "SchedulerTaskClaimed", payload: %{task_id: "task-1", run_id: "run-1"}},
        %{event_type: "SchedulerTaskSkipped", payload: %{task_id: "task-2", reason: "capacity"}}
      ])

    assert scheduler.claims["task-1"].run_id == "run-1"
    assert scheduler.skips["task-2"].reason == "capacity"

    vcs =
      Aggregate.fold(VcsOperation, [
        %{event_type: "WorktreeCreated", payload: %{run_id: "run-1", worktree_path: "/tmp/wt"}},
        %{event_type: "PrMerged", payload: %{operation_id: "op-1"}}
      ])

    assert vcs.status == "merged"

    recovery =
      Aggregate.fold(Recovery, [
        %{event_type: "ExternalWorkerObserved", payload: %{run_id: "run-1"}},
        %{event_type: "WorkerRestarted", payload: %{run_id: "run-1"}}
      ])

    assert recovery.status == "recovering"
    assert length(recovery.observations) == 1

    integration =
      Aggregate.fold(Integration, [
        %{event_type: "IntegrationCommandIngested", payload: %{dedupe_key: "github:event-1"}}
      ])

    assert integration.seen?
    assert integration.dedupe_key == "github:event-1"
  end

  test "project, task, run, phase, and inbox folds tolerate imported map events" do
    assert Aggregate.fold(Project, [
             %{type: "ProjectRegistered", payload: %{project_id: "p", path: "/tmp/p"}}
           ]).exists?

    assert Aggregate.fold(Task, [%{type: "TaskCreated", payload: %{task_id: "t", status: "open"}}]).exists?

    assert Aggregate.fold(Run, [%{type: "RunStarted", payload: %{run_id: "r"}}]).exists?

    assert Aggregate.fold(Phase, [
             %{type: "PhaseStarted", payload: %{run_id: "r", phase_id: "dev"}}
           ]).status == "in_progress"

    assert Aggregate.fold(InboxThread, [
             %{type: "InboxMessageAppended", payload: %{run_id: "r", message_id: "m"}}
           ]).messages["m"].message_id == "m"
  end

  defp started_run!(run_id) do
    assert {:ok, spec} =
             AggregateRouter.route("run.start", %{run_id: run_id, task_id: "task-#{run_id}"})

    assert {:ok, _event} = EventStore.append(spec)
  end

  defp pr_payload(extra) do
    Map.merge(
      %{
        project_id: "project-1",
        task_id: "task-1",
        pr_url: "https://github.com/acme/foreman/pull/42",
        branch_name: "foreman/task-1"
      },
      extra
    )
  end

  test "PlanningFlow aggregate folds PlanningFlowStarted and updates via PlanningFlowCommand" do
    events = [
      %{
        event_type: "PlanningFlowStarted",
        payload: %{flow_id: "plan-1", run_id: "run-plan-1", kind: "prd"}
      },
      %{
        event_type: "PlanningFlowCommand",
        payload: %{flow_id: "plan-1", command: "step-1"}
      },
      %{
        event_type: "PlanningFlowCommand",
        payload: %{flow_id: "plan-1", command: "step-2"}
      },
      %{
        event_type: "PlanningTraceLinked",
        payload: %{flow_id: "plan-1", traceability_key: "trace-1", phase_id: "phase-1"}
      },
      %{
        event_type: "PlanningFlowCompleted",
        payload: %{flow_id: "plan-1"}
      }
    ]

    state = Aggregate.fold(PlanningFlow, events)

    assert %PlanningFlow.State{} = state
    assert state.exists? == true
    assert state.completed? == true
    assert state.flow_id == "plan-1"
    assert length(state.commands) == 2
    assert Map.has_key?(state.traces, "trace-1")
    assert state.traces["trace-1"].phase_id == "phase-1"
  end

  test "PlanningFlow rejects planning.start when already started" do
    events = [
      %{
        event_type: "PlanningFlowStarted",
        payload: %{flow_id: "plan-dup", run_id: "run-dup"}
      }
    ]

    state = Aggregate.fold(PlanningFlow, events)

    assert {:error, :planning_flow_already_started} =
             PlanningFlow.handle_command(state, %{
               type: "planning.start",
               payload: %{flow_id: "plan-dup", run_id: "run-dup"}
             })
  end

  test "PlanningFlow rejects planning.complete when not started" do
    state = PlanningFlow.initial_state()

    assert {:error, :planning_flow_not_started} =
             PlanningFlow.handle_command(state, %{
               type: "planning.complete",
               payload: %{flow_id: "plan-none"}
             })
  end

  test "PlanningFlow rejects planning.complete when already completed" do
    events = [
      %{
        event_type: "PlanningFlowStarted",
        payload: %{flow_id: "plan-done", run_id: "run-done"}
      },
      %{
        event_type: "PlanningFlowCompleted",
        payload: %{flow_id: "plan-done"}
      }
    ]

    state = Aggregate.fold(PlanningFlow, events)

    assert {:error, :planning_flow_completed} =
             PlanningFlow.handle_command(state, %{
               type: "planning.complete",
               payload: %{flow_id: "plan-done"}
             })
  end

  test "Phase aggregate folds PhaseStarted, PhaseCompleted, and handles retry/terminal transitions" do
    events = [
      %{
        event_type: "PhaseStarted",
        payload: %{run_id: "run-1", phase_id: "phase-1"}
      },
      %{
        event_type: "PhaseRetried",
        payload: %{run_id: "run-1", phase_id: "phase-1"}
      },
      %{
        event_type: "PhaseCompleted",
        payload: %{run_id: "run-1", phase_id: "phase-1"}
      }
    ]

    state = Aggregate.fold(Phase, events)

    assert %Phase.State{} = state
    assert state.exists? == true
    assert state.run_id == "run-1"
    assert state.phase_id == "phase-1"
    assert state.status == "completed"
    assert state.terminal? == true
    assert state.attempt == 1
  end

  test "Phase exists? is true even when PhaseStarted has no run_id (partial/imported event)" do
    events = [
      %{
        event_type: "PhaseStarted",
        payload: %{phase_id: "phase-no-run"}
      }
    ]

    state = Aggregate.fold(Phase, events)

    assert %Phase.State{} = state
    assert state.exists? == true
    assert state.phase_id == "phase-no-run"
    # Subsequent phase.start must reject as already started
    assert {:error, :phase_already_started} =
             Phase.handle_command(state, %{
               type: "phase.start",
               payload: %{run_id: "run-x", phase_id: "phase-no-run"}
             })
  end

  test "Phase rejects phase.start when already started" do
    events = [
      %{
        event_type: "PhaseStarted",
        payload: %{run_id: "run-phase-dup", phase_id: "phase-dup"}
      }
    ]

    state = Aggregate.fold(Phase, events)

    assert {:error, :phase_already_started} =
             Phase.handle_command(state, %{
               type: "phase.start",
               payload: %{run_id: "run-phase-dup", phase_id: "phase-dup"}
             })
  end

  test "Phase rejects phase.complete when not started" do
    state = Phase.initial_state()

    assert {:error, :phase_not_started} =
             Phase.handle_command(state, %{
               type: "phase.complete",
               payload: %{run_id: "run-none", phase_id: "phase-none"}
             })
  end

  test "AC-005-3: two phase.complete commands race — second append fails with expected_version conflict" do
    # Seed PhaseStarted into EventStore so the stream exists with version 1
    assert {:ok, start_spec} =
             AggregateRouter.route("phase.start", %{
               run_id: "run-race",
               phase_id: "phase-race"
             })

    assert {:ok, %{stream_version: 1}} = EventStore.append(start_spec)

    # Route two phase.complete specs against the same stream — both get expected_version: 1
    assert {:ok, spec1} =
             AggregateRouter.route("phase.complete", %{
               run_id: "run-race",
               phase_id: "phase-race"
             })

    assert {:ok, spec2} =
             AggregateRouter.route("phase.complete", %{
               run_id: "run-race",
               phase_id: "phase-race"
             })

    assert spec1.expected_stream_version == 1
    assert spec2.expected_stream_version == 1

    # First append succeeds; stream version becomes 2
    assert {:ok, _} = EventStore.append(spec1)

    # Second append fails with conflict (stream version is now 2, spec still expects 1)
    assert {:error, {:conflict, [expected: 1, actual: 2]}} = EventStore.append(spec2)

    # Fresh route: router loads terminal state from store, returns phase_terminal
    assert {:error, :phase_terminal} =
             AggregateRouter.route("phase.complete", %{
               run_id: "run-race",
               phase_id: "phase-race"
             })
  end

  # ─── TRD-009: Run aggregate State struct ────────────────────────────────────────

  test "Run aggregate folds RunStarted and produces %Run.State{}" do
    events = [
      %{
        event_type: "RunStarted",
        payload: %{
          run_id: "run-struct",
          task_id: "task-struct",
          project_id: "proj-struct",
          current_phase: "build",
          phase_order: ["build", "test", "deploy"]
        }
      },
      %{
        event_type: "PhaseCompleted",
        payload: %{run_id: "run-struct", phase_id: "build", status: "completed"}
      }
    ]

    state = Aggregate.fold(Run, events)

    assert %ForemanServer.Aggregates.Run.State{} = state
    assert state.exists? == true
    assert state.run_id == "run-struct"
    assert state.task_id == "task-struct"
    assert state.project_id == "proj-struct"
    assert state.status == "in_progress"
    assert state.terminal? == false
    assert state.current_phase == "build"
    assert state.phase_order == ["build", "test", "deploy"]
    assert state.phase_status == %{"build" => "completed"}
  end

  test "Run rejects run.complete when already completed (idempotent RunAlreadyCompleted)" do
    # Start a run and complete it
    assert {:ok, spec} =
             AggregateRouter.route("run.start", %{
               run_id: "run-idempotent",
               task_id: "task-idem"
             })

    assert {:ok, _} = EventStore.append(spec)

    assert {:ok, complete_spec} =
             AggregateRouter.route("run.complete", %{
               run_id: "run-idempotent"
             })

    assert {:ok, _} = EventStore.append(complete_spec)

    # Load from store to confirm terminal state
    {state, _version} = ForemanServer.Aggregate.load(Run, "run:run-idempotent")

    assert state.status == "completed"
    assert state.terminal? == true

    # Route run.complete again — should return RunAlreadyCompleted spec
    assert {:ok, spec2} =
             AggregateRouter.route("run.complete", %{
               run_id: "run-idempotent"
             })

    assert spec2.event_type == "RunAlreadyCompleted"

    # Append spec2 and verify: version increments, state unchanged
    assert {:ok, _} = EventStore.append(spec2)

    {state2, version2} = ForemanServer.Aggregate.load(Run, "run:run-idempotent")

    assert state2.status == "completed"
    assert state2.terminal? == true
    assert version2 == 3
  end

  test "Run rejects run.fail on already-failed run" do
    assert {:ok, spec} =
             AggregateRouter.route("run.start", %{
               run_id: "run-fail-idem",
               task_id: "task-fail"
             })

    assert {:ok, _} = EventStore.append(spec)

    assert {:ok, fail_spec} =
             AggregateRouter.route("run.fail", %{
               run_id: "run-fail-idem"
             })

    assert {:ok, _} = EventStore.append(fail_spec)

    # Route run.complete on failed run — should return RunAlreadyCompleted
    assert {:ok, spec2} =
             AggregateRouter.route("run.complete", %{
               run_id: "run-fail-idem"
             })

    assert spec2.event_type == "RunAlreadyCompleted"

    # Append spec2 and verify: version increments, state unchanged
    assert {:ok, _} = EventStore.append(spec2)

    {state2, version2} = ForemanServer.Aggregate.load(Run, "run:run-fail-idem")

    assert state2.status == "failed"
    assert state2.terminal? == true
    assert version2 == 3
  end

  test "Aggregate.load/2 replays run stream and restores terminal state" do
    # Seed a completed run directly
    assert {:ok, spec} =
             AggregateRouter.route("run.start", %{
               run_id: "run-replay",
               task_id: "task-replay"
             })

    assert {:ok, _} = EventStore.append(spec)

    assert {:ok, complete_spec} =
             AggregateRouter.route("run.complete", %{
               run_id: "run-replay"
             })

    assert {:ok, _} = EventStore.append(complete_spec)

    # Simulate actor restart: load from event store
    {state, version} = ForemanServer.Aggregate.load(Run, "run:run-replay")

    assert state.exists? == true
    assert state.status == "completed"
    assert state.terminal? == true
    assert version == 2
  end

  # ─── BoardItemStateMachine ──────────────────────────────────────────────────

  describe "BoardItemStateMachine" do
    alias ForemanServer.Events.BoardItemStatusChanged

    test "State struct built by fold from BoardItemStatusChanged" do
      events = [
        %{
          event_type: "BoardItemStatusChanged",
          payload: %{board_item_id: "bi-1", from_status: nil, to_status: "backlog"}
        },
        %{
          event_type: "BoardItemStatusChanged",
          payload: %{board_item_id: "bi-1", from_status: "backlog", to_status: "in_progress"}
        }
      ]

      state = Aggregate.fold(BoardItemStateMachine, events)

      assert %BoardItemStateMachine.State{} = state
      assert state.exists? == true
      assert state.board_item_id == "bi-1"
      assert state.status == "in_progress"
      assert state.terminal? == false
    end

    test "State terminal? set when to_status is done" do
      events = [
        %{
          event_type: "BoardItemStatusChanged",
          payload: %{board_item_id: "bi-2", from_status: nil, to_status: "backlog"}
        },
        %{
          event_type: "BoardItemStatusChanged",
          payload: %{board_item_id: "bi-2", from_status: "backlog", to_status: "in_progress"}
        },
        %{
          event_type: "BoardItemStatusChanged",
          payload: %{board_item_id: "bi-2", from_status: "in_progress", to_status: "in_review"}
        },
        %{
          event_type: "BoardItemStatusChanged",
          payload: %{board_item_id: "bi-2", from_status: "in_review", to_status: "done"}
        }
      ]

      state = Aggregate.fold(BoardItemStateMachine, events)

      assert state.status == "done"
      assert state.terminal? == true
    end

    test "typed %BoardItemStatusChanged{} struct used in fold" do
      events = [
        %BoardItemStatusChanged{
          board_item_id: "bi-typed",
          from_status: nil,
          to_status: "backlog"
        },
        %BoardItemStatusChanged{
          board_item_id: "bi-typed",
          from_status: "backlog",
          to_status: "in_progress"
        }
      ]

      state = Aggregate.fold(BoardItemStateMachine, events)

      assert state.exists? == true
      assert state.board_item_id == "bi-typed"
      assert state.status == "in_progress"
      assert state.terminal? == false
    end

    test "done → in_progress returns {:error, :invalid_transition} via router" do
      # AC-006: terminal done rejects further transitions (e.g., done → in_progress)
      # Seed a board item and advance it to done via valid transitions
      assert {:ok, create_spec} =
               AggregateRouter.route("board_item.create", %{board_item_id: "bi-invalid"})

      assert {:ok, _} = EventStore.append(create_spec)

      assert {:ok, spec1} =
               AggregateRouter.route("board_item.transition", %{
                 board_item_id: "bi-invalid",
                 to_status: "in_progress"
               })

      assert {:ok, _} = EventStore.append(spec1)

      assert {:ok, spec2} =
               AggregateRouter.route("board_item.transition", %{
                 board_item_id: "bi-invalid",
                 to_status: "in_review"
               })

      assert {:ok, _} = EventStore.append(spec2)

      assert {:ok, spec3} =
               AggregateRouter.route("board_item.transition", %{
                 board_item_id: "bi-invalid",
                 to_status: "done"
               })

      assert {:ok, _} = EventStore.append(spec3)

      # done → in_progress is not a valid transition
      assert {:error, :invalid_transition} =
               AggregateRouter.route("board_item.transition", %{
                 board_item_id: "bi-invalid",
                 to_status: "in_progress"
               })
    end

    test "terminal done rejects further transitions" do
      assert {:ok, create_spec} =
               AggregateRouter.route("board_item.create", %{board_item_id: "bi-done"})

      assert {:ok, _} = EventStore.append(create_spec)

      assert {:ok, spec1} =
               AggregateRouter.route("board_item.transition", %{
                 board_item_id: "bi-done",
                 to_status: "in_progress"
               })

      assert {:ok, _} = EventStore.append(spec1)

      assert {:ok, spec2} =
               AggregateRouter.route("board_item.transition", %{
                 board_item_id: "bi-done",
                 to_status: "in_review"
               })

      assert {:ok, _} = EventStore.append(spec2)

      assert {:ok, spec3} =
               AggregateRouter.route("board_item.transition", %{
                 board_item_id: "bi-done",
                 to_status: "done"
               })

      assert {:ok, _} = EventStore.append(spec3)

      # done → in_progress is not a valid transition
      assert {:error, :invalid_transition} =
               AggregateRouter.route("board_item.transition", %{
                 board_item_id: "bi-done",
                 to_status: "in_progress"
               })
    end

    test "valid transition chain: backlog → in_progress → in_review → done" do
      assert {:ok, create_spec} =
               AggregateRouter.route("board_item.create", %{board_item_id: "bi-chain"})

      assert {:ok, _} = EventStore.append(create_spec)

      assert {:ok, spec1} =
               AggregateRouter.route("board_item.transition", %{
                 board_item_id: "bi-chain",
                 to_status: "in_progress"
               })

      assert spec1.event_type == "BoardItemStatusChanged"
      assert {:ok, _} = EventStore.append(spec1)

      assert {:ok, spec2} =
               AggregateRouter.route("board_item.transition", %{
                 board_item_id: "bi-chain",
                 to_status: "in_review"
               })

      assert {:ok, _} = EventStore.append(spec2)

      assert {:ok, spec3} =
               AggregateRouter.route("board_item.transition", %{
                 board_item_id: "bi-chain",
                 to_status: "done"
               })

      assert {:ok, _} = EventStore.append(spec3)
    end

    test "backlog → blocked → backlog transition" do
      assert {:ok, create_spec} =
               AggregateRouter.route("board_item.create", %{board_item_id: "bi-blocked"})

      assert {:ok, _} = EventStore.append(create_spec)

      assert {:ok, spec1} =
               AggregateRouter.route("board_item.transition", %{
                 board_item_id: "bi-blocked",
                 to_status: "blocked"
               })

      assert {:ok, _} = EventStore.append(spec1)

      assert {:ok, spec2} =
               AggregateRouter.route("board_item.transition", %{
                 board_item_id: "bi-blocked",
                 to_status: "backlog"
               })

      assert {:ok, _} = EventStore.append(spec2)
    end

    test "Aggregate.load/2 replays board item stream with typed struct" do
      assert {:ok, create_spec} =
               AggregateRouter.route("board_item.create", %{board_item_id: "bi-replay"})

      assert {:ok, _} = EventStore.append(create_spec)

      assert {:ok, spec1} =
               AggregateRouter.route("board_item.transition", %{
                 board_item_id: "bi-replay",
                 to_status: "in_progress"
               })

      assert {:ok, _} = EventStore.append(spec1)

      assert {:ok, spec2} =
               AggregateRouter.route("board_item.transition", %{
                 board_item_id: "bi-replay",
                 to_status: "in_review"
               })

      assert {:ok, _} = EventStore.append(spec2)

      # Simulate actor restart: load from event store
      {state, version} = Aggregate.load(BoardItemStateMachine, "board_item:bi-replay")

      assert state.exists? == true
      assert state.board_item_id == "bi-replay"
      assert state.status == "in_review"
      assert state.terminal? == false
      assert version == 3
    end

    test "board_item.create returns {:error, {:already_exists, ...}} when exists" do
      assert {:ok, create_spec} =
               AggregateRouter.route("board_item.create", %{board_item_id: "bi-dup"})

      assert {:ok, _} = EventStore.append(create_spec)

      assert {:error, {:already_exists, :board_item, "bi-dup"}} =
               AggregateRouter.route("board_item.create", %{board_item_id: "bi-dup"})
    end

    test "board_item.transition returns {:error, {:not_found, ...}} when not exists" do
      assert {:error, {:not_found, :board_item, "bi-none"}} =
               AggregateRouter.route("board_item.transition", %{
                 board_item_id: "bi-none",
                 to_status: "in_progress"
               })
    end
  end
end
