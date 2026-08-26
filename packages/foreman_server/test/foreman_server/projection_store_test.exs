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
end
