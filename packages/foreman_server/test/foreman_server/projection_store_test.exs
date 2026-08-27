defmodule ForemanServer.ProjectionStoreTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore

  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    # Use the canonical reset helper so a partial-shape state left by a
    # prior failing test (e.g. missing `:project_active_runs`) cannot
    # crash this setup with a badkey.
    ProjectionStoreReset.reset!()

    on_exit(fn ->
      ProjectionStoreReset.reset!()
      :ok
    end)

    :ok
  end

  test "projects are registered and updated from state.projects" do
    project_id = "project-1"

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "ProjectRegistered",
                 payload: %{project_id: project_id, path: "/tmp/project-1", name: "Project One"}
               }
             ])

    assert ProjectionStore.project(project_id) == %{
             project_id: project_id,
             path: "/tmp/project-1",
             status: "active",
             archived?: false,
             default_branch: "main",
             config: %{},
             task_provider: nil,
             health: %{ok: true},
             name: "Project One"
           }

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "ProjectUpdated",
                 payload: %{
                   project_id: project_id,
                   status: "degraded",
                   default_branch: "develop",
                   config: %{region: "iad"},
                   health: %{ok: false},
                   name: "Project Uno"
                 }
               }
             ])

    assert ProjectionStore.project(project_id) == %{
             project_id: project_id,
             path: "/tmp/project-1",
             status: "degraded",
             archived?: false,
             default_branch: "develop",
             config: %{region: "iad"},
             task_provider: nil,
             health: %{ok: false},
             name: "Project Uno"
           }
  end

  test "projects can be archived and reactivated" do
    project_id = "project-2"

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "ProjectRegistered",
                 payload: %{project_id: project_id, path: "/tmp/project-2"}
               },
               %{event_type: "ProjectArchived", payload: %{project_id: project_id}}
             ])

    assert ProjectionStore.project(project_id).status == "archived"
    assert ProjectionStore.project(project_id).archived? == true

    assert :ok =
             ProjectionStore.apply_events([
               %{event_type: "ProjectReactivated", payload: %{project_id: project_id}}
             ])

    assert ProjectionStore.project(project_id).status == "active"
    assert ProjectionStore.project(project_id).archived? == false
  end

  test "task_provider projects onto the read model for ProjectRegistered and ProjectUpdated" do
    project_id = "project-task-provider"

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "ProjectRegistered",
                 payload: %{
                   project_id: project_id,
                   path: "/tmp/project",
                   task_provider: %{
                     provider: :beads,
                     config: %{"database_path" => "/tmp/project.db"}
                   }
                 }
               }
             ])

    assert %{task_provider: %{provider: :beads}} = ProjectionStore.project(project_id)

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "ProjectUpdated",
                 payload: %{
                   project_id: project_id,
                   task_provider: %{
                     provider: :custom,
                     config: %{"database_path" => "/tmp/project.db"}
                   }
                 }
               }
             ])

    assert %{task_provider: %{provider: :custom}} = ProjectionStore.project(project_id)

    # ProjectUpdated without task_provider preserves the existing field.
    assert :ok =
             ProjectionStore.apply_events([
               %{event_type: "ProjectUpdated", payload: %{project_id: project_id, status: "ok"}}
             ])

    assert %{task_provider: %{provider: :custom}} = ProjectionStore.project(project_id)
  end

  test "enumerates reserved runs by project and removes released reservations" do
    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "ProjectRunReserved",
                 payload: %{project_id: "project-a", run_id: "run-2"}
               },
               %{
                 event_type: "ProjectRunReserved",
                 payload: %{project_id: "project-a", run_id: "run-1"}
               },
               %{
                 event_type: "ProjectRunReserved",
                 payload: %{project_id: "project-b", run_id: "run-9"}
               },
               %{
                 event_type: "ProjectRunReserved",
                 payload: %{project_id: "project-a", run_id: "run-1"}
               }
             ])

    assert ProjectionStore.list_projects_with_active_runs() == [
             {"project-a", ["run-1", "run-2"]},
             {"project-b", ["run-9"]}
           ]

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "ProjectRunReservationReleased",
                 payload: %{project_id: "project-a", run_id: "run-2"}
               },
               %{
                 event_type: "ProjectRunReservationReleased",
                 payload: %{project_id: "project-b", run_id: "run-9"}
               }
             ])

    assert ProjectionStore.list_projects_with_active_runs() == [{"project-a", ["run-1"]}]
  end

  test "lists no active runs when the projection store is empty" do
    assert ProjectionStore.list_projects_with_active_runs() == []
  end

  test "legacy run_projection/1 is removed" do
    refute function_exported?(ProjectionStore, :run_projection, 1)
  end

  describe "task queries for orphan-run recovery" do
    test "list_tasks/0 returns every projected task sorted by task_id" do
      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "TaskCreated",
                   payload: %{
                     task_id: "task-z",
                     project_id: "p",
                     title: "z",
                     status: "open",
                     task_type: "ops"
                   }
                 },
                 %{
                   event_type: "TaskCreated",
                   payload: %{
                     task_id: "task-a",
                     project_id: "p",
                     title: "a",
                     status: "open",
                     task_type: "ops"
                   }
                 }
               ])

      assert [%{task_id: "task-a"}, %{task_id: "task-z"}] = ProjectionStore.list_tasks()
    end

    test "tasks_by_run_id/1 returns in-progress tasks bound to the given run, filtering already-acknowledged" do
      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "TaskCreated",
                   payload: %{
                     task_id: "task-1",
                     project_id: "p",
                     title: "1",
                     status: "open",
                     task_type: "ops"
                   }
                 },
                 %{
                   event_type: "TaskCreated",
                   payload: %{
                     task_id: "task-2",
                     project_id: "p",
                     title: "2",
                     status: "open",
                     task_type: "ops"
                   }
                 }
               ])

      run_id = "run-orphan-1"

      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "TaskApproved",
                   payload: %{
                     task_id: "task-1",
                     run_id: run_id,
                     approval_id: "approval-1",
                     approved_by: "tester",
                     approved_at: "2026-08-10T00:00:00Z",
                     workflow_snapshot: nil
                   }
                 },
                 %{
                   event_type: "TaskApproved",
                   payload: %{
                     task_id: "task-2",
                     run_id: run_id,
                     approval_id: "approval-1",
                     approved_by: "tester",
                     approved_at: "2026-08-10T00:00:00Z",
                     workflow_snapshot: nil
                   }
                 },
                 %{
                   event_type: "TaskRunTerminated",
                   payload: %{
                     task_id: "task-1",
                     run_id: run_id,
                     acknowledged_at: "2026-08-10T00:00:00Z"
                   }
                 }
               ])

      assert [%{task_id: "task-2"}] = ProjectionStore.tasks_by_run_id(run_id)
    end

    test "tasks_by_run_id/1 returns empty list when no tasks are bound to the run" do
      assert [] = ProjectionStore.tasks_by_run_id("run-nothing")
    end
  end

  describe "run_logs/1" do
    test "returns not_found for unknown run and empty success for known run without output" do
      assert {:error, :run_not_found} = ProjectionStore.run_logs("missing-run")

      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "RunStarted",
                   payload: %{run_id: "run-empty", project_id: "project-1"}
                 }
               ])

      assert {:ok,
              %{
                run_id: "run-empty",
                entries: [],
                count: 0,
                limit: 500,
                truncated: false,
                omitted_entries: 0,
                omitted_bytes: 0
              }} = ProjectionStore.run_logs("run-empty")
    end

    test "projects WorkerStdout and WorkerStderr as ordered durable log entries" do
      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "RunStarted",
                   payload: %{run_id: "run-logs", project_id: "project-1"}
                 },
                 %{
                   event_type: "WorkerStdout",
                   payload: %{
                     run_id: "run-logs",
                     worker_id: "worker-b",
                     sequence: 2,
                     line: "out two",
                     timestamp: "2026-08-27T00:00:02Z"
                   }
                 },
                 %{
                   event_type: "WorkerStderr",
                   payload: %{
                     run_id: "run-logs",
                     worker_id: "worker-a",
                     sequence: 1,
                     line: "err one",
                     timestamp: "2026-08-27T00:00:01Z"
                   }
                 }
               ])

      assert {:ok, result} = ProjectionStore.run_logs("run-logs")
      assert result.count == 2
      assert result.truncated == false

      assert [first, second] = result.entries
      assert first.channel == "stderr"
      assert first.content == "err one"
      assert first.worker_id == "worker-a"
      assert first.stream_id == "worker:run-logs:worker-a"
      assert first.sequence == 1

      assert second.channel == "stdout"
      assert second.content == "out two"
      assert second.worker_id == "worker-b"
    end

    test "keeps the latest 500 log entries with truncation metadata" do
      events =
        [%{event_type: "RunStarted", payload: %{run_id: "run-tail", project_id: "project-1"}}] ++
          for n <- 1..505 do
            %{
              event_type: "WorkerStdout",
              payload: %{
                run_id: "run-tail",
                worker_id: "worker-1",
                sequence: n,
                line: "line-#{n}",
                timestamp: "2026-08-27T00:00:00Z"
              }
            }
          end

      assert :ok = ProjectionStore.apply_events(events)
      assert {:ok, result} = ProjectionStore.run_logs("run-tail")
      assert result.count == 500
      assert result.truncated == true
      assert result.omitted_entries == 5
      assert hd(result.entries).content == "line-6"
      assert List.last(result.entries).content == "line-505"
    end
  end
end
