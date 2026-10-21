defmodule ForemanServerWeb.ProjectArchiveSemanticsTest do
  # Archive is the ONLY delete: reversible and non-destructive. There is no
  # operator-reachable hard delete (docs/decisions/project-delete.md).
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.{CommandGateway, EventStore, ProjectStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "project-archive-semantics-token"

  setup do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    ProjectionStoreReset.reset!()

    on_exit(fn ->
      ProjectionStoreReset.reset!()

      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    id = "archive-sem-#{System.unique_integer([:positive])}"
    assert {:ok, _} = ProjectStore.save(%{project_id: id, path: "/tmp/#{id}"})
    {:ok, id: id}
  end

  defp dispatch(id, type) do
    CommandGateway.dispatch_operator(%{
      command_id: "#{type}-#{id}-#{System.unique_integer([:positive])}",
      aggregate_id: "project:#{id}",
      type: type,
      payload: %{project_id: id}
    })
  end

  defp api(path) do
    build_conn() |> put_req_header("authorization", "Bearer #{@token}") |> get(path)
  end

  test "project.delete and project.purge are not operator commands", %{id: id} do
    assert {:error, {:command_not_allowed, "project.delete"}} = dispatch(id, "project.delete")
    assert {:error, {:command_not_allowed, "project.purge"}} = dispatch(id, "project.purge")
  end

  test "archive is reversible, keeps the event history, and archived projects stay readable", %{
    id: id
  } do
    assert {:ok, _} = dispatch(id, "project.archive")

    assert %{"project" => %{"status" => "archived"}} =
             json_response(api("/api/projects/#{id}"), 200)

    hidden = json_response(api("/api/projects"), 200)["projects"]
    refute Enum.any?(hidden, &(&1["project_id"] == id))

    shown = json_response(api("/api/projects?include_archived=true"), 200)["projects"]
    assert Enum.any?(shown, &(&1["project_id"] == id))

    assert {:ok, _} = dispatch(id, "project.reactivate")

    assert %{"project" => %{"status" => "active"}} =
             json_response(api("/api/projects/#{id}"), 200)

    {:ok, events} = EventStore.read_stream_forward("project:#{id}", 0, 100)

    assert Enum.map(events, & &1.event_type) == [
             "ProjectRegistered",
             "ProjectArchived",
             "ProjectReactivated"
           ]
  end
end
