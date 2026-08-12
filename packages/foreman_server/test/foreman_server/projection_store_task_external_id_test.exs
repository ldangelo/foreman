defmodule ForemanServer.ProjectionStoreTaskExternalIdTest do
  @moduledoc """
  Verifies AC-025-1: the `external_id` field round-trips from the typed
  `TaskCreated` event through `ProjectionStore` to the read-side
  `GET /api/tasks/:id` endpoint.

  See TRD-010 in
  docs/TRD/TRD-2026-81315f37-atomic-beads-task-create-and-watcher.md.
  """

  use ExUnit.Case, async: false

  use Phoenix.ConnTest

  alias ForemanServer.ProjectionStore

  @endpoint ForemanServerWeb.Endpoint
  @token "projection-store-task-external-id-test-token"

  setup do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      %{state | projects: %{}, tasks: %{}, runs: %{}, phases: %{}, project_active_runs: %{}}
    end)

    on_exit(fn ->
      :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
        %{state | projects: %{}, tasks: %{}, runs: %{}, phases: %{}, project_active_runs: %{}}
      end)

      if previous == nil do
        Application.delete_env(:foreman_server, :api_bearer_token)
      else
        Application.put_env(:foreman_server, :api_bearer_token, previous)
      end
    end)

    :ok
  end

  test "TaskCreated with external_id surfaces external_id on the projected task map" do
    task_id = unique_task_id()

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "TaskCreated",
                 payload: %{
                   task_id: task_id,
                   project_id: "p-1",
                   title: "with bead",
                   status: "open",
                   task_type: "implement",
                   external_id: "foreman-abc"
                 }
               }
             ])

    task = ProjectionStore.task_projection(task_id)
    assert task, "expected task to be projected"
    assert Map.has_key?(task, :external_id), "task map must always carry :external_id"
    assert task.external_id == "foreman-abc"
    assert task.task_id == task_id
    assert task.project_id == "p-1"
  end

  test "TaskCreated without external_id (legacy) defaults external_id to nil" do
    task_id = unique_task_id()

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "TaskCreated",
                 payload: %{
                   task_id: task_id,
                   project_id: "p-1",
                   title: "legacy",
                   status: "open",
                   task_type: "implement"
                 }
               }
             ])

    task = ProjectionStore.task_projection(task_id)
    assert task, "expected task to be projected"
    assert Map.has_key?(task, :external_id), "task map must always carry :external_id"
    assert task.external_id == nil
  end

  test "ProjectionStore.task_projection/1 returns the task map including external_id" do
    task_id = unique_task_id()

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "TaskCreated",
                 payload: %{
                   task_id: task_id,
                   project_id: "p-1",
                   title: "read roundtrip",
                   status: "open",
                   task_type: "implement",
                   external_id: "foreman-xyz"
                 }
               }
             ])

    assert %{external_id: "foreman-xyz", task_id: ^task_id} =
             ProjectionStore.task_projection(task_id)

    assert is_map_key(ProjectionStore.task_projection(task_id), :external_id)
  end

  test "GET /api/tasks/:id returns the bead ID (external_id) in the response body" do
    task_id = unique_task_id()
    bead_id = "foreman-bead-#{System.unique_integer([:positive])}"

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "TaskCreated",
                 payload: %{
                   task_id: task_id,
                   project_id: "p-1",
                   title: "web roundtrip",
                   status: "open",
                   task_type: "implement",
                   external_id: bead_id
                 }
               }
             ])

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get("/api/tasks/#{task_id}")

    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert is_map(body), "response body must be a JSON object, got #{inspect(body)}"
    assert is_map(body["task"]), "response must wrap projection under :task"
    assert body["task"]["task_id"] == task_id
    assert body["task"]["external_id"] == bead_id
  end

  defp unique_task_id do
    "task-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end
end
