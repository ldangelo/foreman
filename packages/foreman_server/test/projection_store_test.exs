defmodule ForemanServer.ProjectionStoreTest do
  use ExUnit.Case

  alias ForemanServer.{EventStore, ProjectionStore}

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-projection-test-#{System.unique_integer([:positive])}"
      )

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

  test "task projections render task show/list state from events" do
    append!("task:task-1", "TaskCreated", %{
      task_id: "task-1",
      title: "Implement server",
      status: "open"
    })

    append!("task:task-1", "TaskUpdated", %{task_id: "task-1", status: "in_progress"})

    append!("task:task-2", "TaskCreated", %{
      task_id: "task-2",
      title: "Verify server",
      status: "open"
    })

    assert ProjectionStore.task("task-1") == %{
             task_id: "task-1",
             title: "Implement server",
             status: "in_progress",
             updated_at: nil,
             failure_reason: nil,
             failure_output: nil
           }

    assert Enum.map(ProjectionStore.task_list(), & &1.task_id) == ["task-1", "task-2"]
  end

  test "active task updates clear stale failure metadata" do
    append!("task:task-1", "TaskCreated", %{
      task_id: "task-1",
      title: "Implement server",
      status: "failed"
    })

    append!("task:task-1", "TaskUpdated", %{
      task_id: "task-1",
      status: "failed",
      failure_reason: "worker_failed",
      failure_output: "boom"
    })

    append!("task:task-1", "TaskUpdated", %{task_id: "task-1", status: "in_progress"})

    assert ProjectionStore.task("task-1").status == "in_progress"
    assert ProjectionStore.task("task-1").failure_reason == nil
    assert ProjectionStore.task("task-1").failure_output == nil
  end

  test "task progress updates keep status separate from phase" do
    append!("task:task-1", "TaskCreated", %{
      task_id: "task-1",
      title: "Implement server",
      status: "open"
    })

    append!("task:task-1", "TaskUpdated", %{task_id: "task-1", status: "in_progress"})

    append!("worker:run-1:worker-1", "TaskUpdated", %{
      task_id: "task-1",
      run_id: "run-1",
      phase_id: "documentation",
      worker_id: "worker-1",
      sequence: 12,
      status: nil,
      details: %{body: "documentation started"}
    })

    append!("task:task-1", "TaskUpdated", %{task_id: "task-1", status: "documentation"})

    task = ProjectionStore.task("task-1")
    assert task.status == "in_progress"
    assert task.phase_id == "documentation"
    assert task.details == %{body: "documentation started"}
  end

  test "run terminal events update task projection when task_id is present" do
    append!("task:task-1", "TaskCreated", %{
      task_id: "task-1",
      title: "Implement server",
      status: "in_progress",
      run_id: "run-1"
    })

    append!("run:run-1", "RunStarted", %{run_id: "run-1", task_id: "task-1"})

    append!("run:run-1", "RunFailed", %{
      run_id: "run-1",
      task_id: "task-1",
      phase_id: "explorer",
      reason: "Phase exceeded maxTurns (30)",
      failed_at: "2026-07-01T20:10:23Z"
    })

    task = ProjectionStore.task("task-1")
    assert task.status == "failed"
    assert task.run_id == "run-1"
    assert task.failure_reason == "Phase exceeded maxTurns (30)"
    assert task.updated_at == "2026-07-01T20:10:23Z"
  end

  test "failed run terminal events use event time and stored task id fallback" do
    append!("task:task-1", "TaskCreated", %{
      task_id: "task-1",
      title: "Implement server",
      status: "in_progress",
      run_id: "run-1"
    })

    append!("run:run-1", "RunStarted", %{run_id: "run-1", task_id: "task-1"})

    event =
      append!("run:run-1", "RunFailed", %{
        run_id: "run-1",
        reason: "Phase exceeded maxTurns (30)"
      })

    task = ProjectionStore.task("task-1")
    assert task.status == "failed"
    assert task.run_id == "run-1"
    assert task.updated_at == event.occurred_at
  end

  test "blocked run terminal events update task projection when task_id is present" do
    append!("task:task-1", "TaskCreated", %{
      task_id: "task-1",
      title: "Blocked server",
      status: "in_progress",
      run_id: "run-1"
    })

    append!("run:run-1", "RunStarted", %{run_id: "run-1", task_id: "task-1"})

    append!("run:run-1", "RunBlocked", %{
      run_id: "run-1",
      task_id: "task-1",
      reason: "operator review required",
      failed_at: "2026-07-01T20:10:23Z"
    })

    task = ProjectionStore.task("task-1")
    assert task.status == "blocked"
    assert task.run_id == "run-1"
    assert task.failure_reason == "operator review required"
    assert task.updated_at == "2026-07-01T20:10:23Z"
  end

  test "blocked run terminal events use event time when payload has no timestamp" do
    append!("task:task-1", "TaskCreated", %{
      task_id: "task-1",
      title: "Blocked server",
      status: "in_progress",
      run_id: "run-1"
    })

    append!("run:run-1", "RunStarted", %{run_id: "run-1", task_id: "task-1"})

    event =
      append!("run:run-1", "RunBlocked", %{
        run_id: "run-1",
        reason: "operator review required"
      })

    task = ProjectionStore.task("task-1")
    assert task.status == "blocked"
    assert task.updated_at == event.occurred_at
  end

  test "blocked task status overrides stale failed run status in board output" do
    append!("task:task-1", "TaskCreated", %{
      project_id: "project-1",
      task_id: "task-1",
      title: "Blocked server",
      status: "in_progress",
      run_id: "run-1"
    })

    append!("run:run-1", "RunStarted", %{
      project_id: "project-1",
      run_id: "run-1",
      task_id: "task-1"
    })

    append!("run:run-1", "RunFailed", %{
      project_id: "project-1",
      run_id: "run-1",
      task_id: "task-1",
      reason: "nothing_to_commit",
      failed_at: "2026-07-01T20:10:23Z"
    })

    append!("task:task-1", "TaskUpdated", %{
      project_id: "project-1",
      task_id: "task-1",
      status: "blocked"
    })

    assert [blocked] = ProjectionStore.board("project-1").blocked
    assert blocked.status == "blocked"
    assert blocked.run_id == "run-1"
    assert blocked.type == "attention"
  end

  test "done task status overrides stale failed run status in board output" do
    append!("task:task-1", "TaskCreated", %{
      project_id: "project-1",
      task_id: "task-1",
      title: "Closed task",
      status: "in_progress",
      run_id: "run-1"
    })

    append!("run:run-1", "RunStarted", %{
      project_id: "project-1",
      run_id: "run-1",
      task_id: "task-1"
    })

    append!("run:run-1", "RunFailed", %{
      project_id: "project-1",
      run_id: "run-1",
      task_id: "task-1",
      reason: "nothing_to_commit"
    })

    append!("task:task-1", "TaskUpdated", %{
      project_id: "project-1",
      task_id: "task-1",
      status: "closed"
    })

    assert [done] = ProjectionStore.board("project-1").done
    # `closed` is now normalized to the lifecycle `done` by the
    # state machine (user-directed vocabulary: backlog/ready/in-progress/
    # blocked/done). The task projection keeps the raw `"closed"`;
    # the board-visible status is the lifecycle form.
    assert done.status == "done"
    assert done.run_id == "run-1"
    assert done.type == "run"
  end

  test "runless terminal task status is normalized in board output" do
    append!("task:task-1", "TaskCreated", %{
      project_id: "project-1",
      task_id: "task-1",
      title: "Closed task",
      status: " CLOSED "
    })

    assert [done] = ProjectionStore.board("project-1").done
    # `closed` (case/whitespace-insensitive) is now normalized to the
    # lifecycle `done` by the state machine.
    assert done.status == "done"
    assert done.type == "task"
  end

  test "blocked task status is normalized before overriding stale run status" do
    append!("task:task-1", "TaskCreated", %{
      project_id: "project-1",
      task_id: "task-1",
      status: "in_progress",
      run_id: "run-1"
    })

    append!("run:run-1", "RunStarted", %{
      project_id: "project-1",
      run_id: "run-1",
      task_id: "task-1"
    })

    append!("run:run-1", "RunFailed", %{
      project_id: "project-1",
      run_id: "run-1",
      task_id: "task-1",
      reason: "nothing_to_commit"
    })

    append!("task:task-1", "TaskCreated", %{
      project_id: "project-1",
      task_id: "task-1",
      title: "Blocked server",
      status: " BLOCKED ",
      run_id: "run-1"
    })

    assert [blocked] = ProjectionStore.board("project-1").blocked
    assert blocked.status == "blocked"
    assert blocked.run_id == "run-1"
    assert blocked.type == "attention"
  end

  test "terminal task updates also terminalize the associated active run projection" do
    append!("task:task-1", "TaskCreated", %{
      task_id: "task-1",
      title: "Implement server",
      status: "in_progress",
      run_id: "run-1"
    })

    append!("run:run-1", "RunStarted", %{run_id: "run-1", task_id: "task-1"})

    append!("task:task-1", "TaskUpdated", %{
      task_id: "task-1",
      status: "in_progress",
      run_id: "run-1"
    })

    append!("worker:run-1:worker-1", "WorkerStarted", %{
      run_id: "run-1",
      task_id: "task-1",
      worker_id: "worker-1",
      phase_id: "developer"
    })

    append!("task:task-1", "TaskUpdated", %{
      task_id: "task-1",
      status: "failed",
      updated_at: "2026-07-01T20:10:23Z"
    })

    run = ProjectionStore.snapshot().runs["run-1"]
    assert run.status == "failed"
    assert run.current_phase == "developer"
    assert run.phase_status["developer"] == "failed"
    assert run.worker_status["worker-1"] == "failed"
  end

  test "terminal run projection is not made active by late worker events" do
    append!("run:late-worker", "RunStarted", %{run_id: "late-worker", task_id: "task-1"})

    append!("worker:late-worker:worker-1", "WorkerStarted", %{
      run_id: "late-worker",
      worker_id: "worker-1",
      phase_id: "explorer"
    })

    append!("worker:late-worker:worker-1", "RunFailed", %{
      run_id: "late-worker",
      task_id: "task-1",
      worker_id: "worker-1",
      phase_id: "explorer",
      reason: "worker_exited_without_terminal_event"
    })

    append!("worker:late-worker:worker-1", "PhaseStarted", %{
      run_id: "late-worker",
      worker_id: "worker-1",
      phase_id: "explorer"
    })

    append!("worker:late-worker:worker-1", "ToolCallFinished", %{
      run_id: "late-worker",
      worker_id: "worker-1",
      phase_id: "explorer",
      status: "finished"
    })

    run = ProjectionStore.snapshot().runs["late-worker"]
    assert run.status == "failed"
    assert run.phase_status["explorer"] == "failed"
    assert run.worker_status["worker-1"] == "failed"
  end

  test "worker-sequenced events without specific projections still advance sequence" do
    append!("worker:run-1:worker-1", "PhaseNudged", %{
      run_id: "run-1",
      worker_id: "worker-1",
      phase_id: "explorer",
      sequence: 7,
      message: "nudge"
    })

    assert ProjectionStore.snapshot().worker_sequences["run-1:worker-1"] == 7
  end

  test "run projection exposes status counts without log inference" do
    append!("run:active", "RunStarted", %{run_id: "active", task_id: "task-1"})
    append!("run:active", "PhaseStarted", %{run_id: "active", phase_id: "developer"})

    append!("run:active", "WorkerStatusChanged", %{
      run_id: "active",
      worker_id: "worker-1",
      status: "running"
    })

    append!("run:done", "RunStarted", %{run_id: "done", task_id: "task-2"})
    append!("run:done", "RunCompleted", %{run_id: "done"})

    append!("run:failed", "RunStarted", %{run_id: "failed", task_id: "task-3"})
    append!("run:failed", "RunFailed", %{run_id: "failed"})

    assert ProjectionStore.status_counts() == %{
             active: 1,
             in_progress: 1,
             failed: 1,
             blocked: 0,
             completed: 1
           }

    snapshot = ProjectionStore.snapshot()
    assert snapshot.runs["active"].phase_status["developer"] == "in_progress"
    assert snapshot.runs["active"].worker_status["worker-1"] == "running"
  end

  test "run PR lifecycle events project current PR metadata" do
    append!("run:run-pr", "RunStarted", %{
      run_id: "run-pr",
      task_id: "task-pr",
      base_branch: "foreman/parent"
    })

    append!("run:run-pr", "PrUpdated", %{
      run_id: "run-pr",
      project_id: "project-1",
      task_id: "task-pr",
      pr_url: "https://github.com/acme/foreman/pull/42",
      branch_name: "foreman/task-pr",
      head_sha: "sha-update",
      base_branch: "foreman/parent",
      phase: "developer"
    })

    run = ProjectionStore.snapshot().runs["run-pr"]
    assert run.pr_url == "https://github.com/acme/foreman/pull/42"
    assert run.pr_state == "draft"
    assert run.pr_head_sha == "sha-update"
    assert run.commit_sha == "sha-update"
    assert run.base_branch == "foreman/parent"

    append!("run:run-pr", "PrReady", %{
      run_id: "run-pr",
      project_id: "project-1",
      task_id: "task-pr",
      pr_url: "https://github.com/acme/foreman/pull/42",
      branch_name: "foreman/task-pr",
      head_sha: "sha-ready",
      base_branch: "foreman/parent"
    })

    run = ProjectionStore.snapshot().runs["run-pr"]
    assert run.pr_state == "open"
    assert run.pr_head_sha == "sha-ready"
    assert run.commit_sha == "sha-ready"
    assert run.base_branch == "foreman/parent"

    append!("run:run-pr", "PrRetargeted", %{
      run_id: "run-pr",
      project_id: "project-1",
      task_id: "task-pr",
      pr_url: "https://github.com/acme/foreman/pull/42",
      branch_name: "foreman/task-pr",
      old_base_branch: "foreman/parent",
      new_base_branch: "main",
      head_sha: "sha-retarget"
    })

    run = ProjectionStore.snapshot().runs["run-pr"]
    assert run.pr_url == "https://github.com/acme/foreman/pull/42"
    assert run.pr_state == "open"
    assert run.pr_head_sha == "sha-retarget"
    assert run.commit_sha == "sha-retarget"
    assert run.base_branch == "main"

    merged_at = "2026-07-09T12:34:56Z"

    append!("run:run-pr", "PrMerged", %{
      run_id: "run-pr",
      project_id: "project-1",
      task_id: "task-pr",
      pr_url: "https://github.com/acme/foreman/pull/42",
      branch_name: "foreman/task-pr",
      merged_at: merged_at,
      merge_commit_sha: "merge-sha"
    })

    run = ProjectionStore.snapshot().runs["run-pr"]
    assert run.pr_url == "https://github.com/acme/foreman/pull/42"
    assert run.pr_state == "merged"
    assert run.status == "merged"
    assert run.completed_at == merged_at
    assert run.merge_commit_sha == "merge-sha"
    assert run.pr_head_sha == "sha-retarget"
    assert run.commit_sha == "sha-retarget"
    assert run.base_branch == "main"
    assert run.branch_name == "foreman/task-pr"

    append!("run:run-pr", "PrRetargeted", %{
      run_id: "run-pr",
      project_id: "project-1",
      task_id: "task-pr",
      pr_url: "https://github.com/acme/foreman/pull/42",
      branch_name: "foreman/task-pr",
      old_base_branch: "main",
      head_sha: "sha-default-target"
    })

    run = ProjectionStore.snapshot().runs["run-pr"]
    assert run.pr_head_sha == "sha-default-target"
    assert run.commit_sha == "sha-default-target"
    assert run.base_branch == nil

    append!("run:run-pr", "PrReset", %{
      run_id: "run-pr",
      project_id: "project-1",
      task_id: "task-pr",
      pr_url: "https://github.com/acme/foreman/pull/42",
      branch_name: "foreman/task-pr",
      action: "closed",
      reason: "reset superseded the PR"
    })

    run = ProjectionStore.snapshot().runs["run-pr"]
    assert run.pr_url == "https://github.com/acme/foreman/pull/42"
    assert run.pr_state == "closed"
    assert run.pr_head_sha == "sha-default-target"
    assert run.commit_sha == "sha-default-target"
    assert run.base_branch == nil
  end

  test "projection rebuild drops corrupted state and replays from events" do
    append!("task:task-1", "TaskCreated", %{
      task_id: "task-1",
      title: "From events",
      status: "open"
    })

    append!("run:blocked", "RunStarted", %{run_id: "blocked", task_id: "task-1"})
    append!("run:blocked", "RunBlocked", %{run_id: "blocked"})

    assert {:ok, corrupted} = ProjectionStore.rebuild([])
    assert corrupted.tasks == %{}
    assert corrupted.status_counts.blocked == 0

    assert {:ok, rebuilt} = EventStore.rebuild_projections()
    assert rebuilt.tasks["task-1"].title == "From events"
    assert rebuilt.status_counts.blocked == 1
    assert ProjectionStore.snapshot().tasks["task-1"].title == "From events"
  end

  test "term projection mode keeps reads in memory" do
    assert ForemanServer.RuntimeInfo.projection_store_adapter() == :memory

    append!("project:project-1", "ProjectRegistered", %{
      project_id: "project-1",
      path: "/tmp/project-1",
      status: "active",
      config: %{name: "Project 1"}
    })

    assert ProjectionStore.project("project-1").path == "/tmp/project-1"
    assert Enum.map(ProjectionStore.project_list(), & &1.project_id) == ["project-1"]
  end

  # Regression tests for the user-reported bug: the board was leaking
  # phase names (developer/qa/reviewer) as task statuses, and stale
  # task.status of "in_progress" was being honored even when the PR
  # was already merged or closed. The PR-override path in
  # `build_board/2` and `build_board_from_maps/3` lets run.pr_state
  # win over a stale task.status.

  test "PR merged wins over stale in_progress task status" do
    append!("task:task-1", "TaskCreated", %{
      project_id: "project-1",
      task_id: "task-1",
      title: "Real merge queue",
      status: "in_progress"
    })

    append!("run:run-1", "RunStarted", %{
      project_id: "project-1",
      run_id: "run-1",
      task_id: "task-1"
    })

    append!("run:run-1", "PrMerged", %{
      project_id: "project-1",
      run_id: "run-1",
      task_id: "task-1",
      pr_url: "https://example.com/pr/1",
      merged_at: "2026-07-22T12:00:00Z"
    })

    assert [done] = ProjectionStore.board("project-1").done
    assert done.task_id == "task-1"
    # Lifecycle form, not the raw `merged` value.
    assert done.status == "done"
    assert done.run_id == "run-1"
  end

  # Precedence precedence precedence: the new authoritative-done
  # override only fires for `merged`/`completed`/`done` task.status.
  # `closed` alone does NOT preempt PR state — a `closed` task with a
  # closed-without-merge PR must still land in `blocked` (otherwise
  # the 12 genuinely closed-PR tasks would all flip to done).

  test "task.status=merged wins over latest pr_state=closed (task-beff3caa case)" do
    # Operator has explicitly marked the task merged (e.g. via
    # `foreman task update --status merged <id>` after confirming
    # the PR landed). A later re-target emitted `PrReset` so the
    # latest run's pr_state is "closed". The operator's intent
    # wins: task lands in `done`, not `blocked`.
    append!("task:task-1", "TaskCreated", %{
      project_id: "project-1",
      task_id: "task-1",
      title: "Multi-run landed task",
      status: "in_progress"
    })

    append!("run:run-merged", "RunStarted", %{
      project_id: "project-1",
      run_id: "run-merged",
      task_id: "task-1"
    })

    append!("run:run-merged", "PrMerged", %{
      project_id: "project-1",
      run_id: "run-merged",
      task_id: "task-1",
      pr_url: "https://github.com/acme/foreman/pull/335",
      merged_at: "2026-07-15T13:29:13Z"
    })

    append!("run:run-retarget", "RunStarted", %{
      project_id: "project-1",
      run_id: "run-retarget",
      task_id: "task-1"
    })

    append!("run:run-retarget", "PrReset", %{
      project_id: "project-1",
      run_id: "run-retarget",
      task_id: "task-1",
      pr_url: "https://github.com/acme/foreman/pull/326",
      action: "closed"
    })

    # Operator closes the task with --force, marking it merged
    # after confirming the original PR landed.
    append!("task:task-1", "TaskUpdated", %{
      project_id: "project-1",
      task_id: "task-1",
      status: "merged"
    })

    assert [done] = ProjectionStore.board("project-1").done
    assert done.task_id == "task-1"
    assert done.status == "done"
  end

  test "task.status=closed + latest pr_state=closed stays blocked" do
    # The narrower authoritative-done set protects this case:
    # `closed` alone does not preempt PR state. A closed task with
    # a closed-without-merge PR must remain blocked.
    append!("task:task-1", "TaskCreated", %{
      project_id: "project-1",
      task_id: "task-1",
      title: "Closed without merge",
      status: "in_progress"
    })

    append!("run:run-1", "RunStarted", %{
      project_id: "project-1",
      run_id: "run-1",
      task_id: "task-1"
    })

    append!("run:run-1", "PrReset", %{
      project_id: "project-1",
      run_id: "run-1",
      task_id: "task-1",
      pr_url: "https://github.com/acme/foreman/pull/322",
      action: "closed"
    })

    append!("task:task-1", "TaskUpdated", %{
      project_id: "project-1",
      task_id: "task-1",
      status: "closed"
    })

    assert [blocked] = ProjectionStore.board("project-1").blocked
    assert blocked.task_id == "task-1"
    assert blocked.status == "blocked"
  end

  test "task.status=closed + no PR override falls back to done (post-PR)" do
    # Without a PR (or with an empty pr_url), the pr_override is nil
    # and both pr_override branches are skipped. The broader
    # `@done_task_statuses` post-PR fallback then routes the closed
    # task to `done`, preserving pre-fix behavior.
    append!("task:task-1", "TaskCreated", %{
      project_id: "project-1",
      task_id: "task-1",
      title: "Closed with no PR",
      status: "in_progress"
    })

    append!("run:run-1", "RunStarted", %{
      project_id: "project-1",
      run_id: "run-1",
      task_id: "task-1"
    })

    append!("task:task-1", "TaskUpdated", %{
      project_id: "project-1",
      task_id: "task-1",
      status: "closed"
    })

    assert [done] = ProjectionStore.board("project-1").done
    assert done.task_id == "task-1"
    assert done.status == "done"
  end

  test "PR closed wins over stale in_progress task status" do
    append!("task:task-1", "TaskCreated", %{
      project_id: "project-1",
      task_id: "task-1",
      title: "Reviewer closed without merge",
      status: "in_progress"
    })

    append!("run:run-1", "RunStarted", %{
      project_id: "project-1",
      run_id: "run-1",
      task_id: "task-1"
    })

    append!("run:run-1", "PrReset", %{
      project_id: "project-1",
      run_id: "run-1",
      task_id: "task-1",
      pr_url: "https://example.com/pr/1"
    })

    assert [blocked] = ProjectionStore.board("project-1").blocked
    assert blocked.task_id == "task-1"
    assert blocked.status == "blocked"
    assert blocked.run_id == "run-1"
  end

  defp append!(stream_id, event_type, payload) do
    {:ok, event} =
      EventStore.append(%{
        stream_id: stream_id,
        event_type: event_type,
        payload: payload,
        metadata: %{}
      })

    event
  end
end
