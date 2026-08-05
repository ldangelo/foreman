defmodule ForemanServer.ProjectionStoreTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore

  setup do
    :sys.replace_state(ForemanServer.ProjectionStore, fn _ -> %{projects: %{}, runs: %{}} end)

    on_exit(fn ->
      :sys.replace_state(ForemanServer.ProjectionStore, fn _ -> %{projects: %{}, runs: %{}} end)
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
end
