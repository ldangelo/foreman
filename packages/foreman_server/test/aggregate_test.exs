defmodule ForemanServer.AggregateTest do
  use ExUnit.Case

  alias ForemanServer.{Aggregate, AggregateRouter, CommandRouter, EventStore}

  alias ForemanServer.Aggregates.{
    InboxThread,
    Integration,
    Phase,
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
               payload: %{task_id: "task-agg", title: "Aggregate task"}
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
    assert {:ok, spec} = AggregateRouter.route("task.create", %{task_id: "task-versioned"})
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
end
