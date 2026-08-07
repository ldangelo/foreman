defmodule ForemanServer.ProjectionStoreTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore

  setup do
    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      %{state | projects: %{}, runs: %{}}
    end)

    on_exit(fn ->
      :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
        %{state | projects: %{}, runs: %{}}
      end)
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
end
