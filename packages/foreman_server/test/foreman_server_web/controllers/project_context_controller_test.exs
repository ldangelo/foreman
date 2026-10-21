defmodule ForemanServerWeb.ProjectContextControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.{CommandRouter, Identity, ProjectContext}

  @moduletag :tmp_dir
  @endpoint ForemanServerWeb.Endpoint
  @token "project-context-controller-test-token"

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    id = "http-ctx-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        aggregate_id: "project:#{id}",
        payload: %{project_id: id, path: dir, config: %{instructions: "Never touch vendor/"}}
      })

    {:ok, id: id}
  end

  defp authed, do: build_conn() |> put_req_header("authorization", "Bearer #{@token}")

  test "returns exactly the text a launch would inject, with its sha256", %{id: id} do
    body = authed() |> get("/api/projects/#{id}/context") |> json_response(200)

    {:ok, bundle} = ProjectContext.build(id)
    assert body["system_text"] == bundle.system_text
    assert body["system_text"] =~ "Never touch vendor/"
    assert body["sha256"] == Identity.sha256(body["system_text"])
    assert body["bytes"] == byte_size(body["system_text"])
    assert body["truncated"] == []
    assert Enum.map(body["sections"], & &1["id"]) == ["instructions", "repositories"]
  end

  test "unknown project is 404" do
    assert %{"error" => "not_found"} =
             authed() |> get("/api/projects/nope-ctx/context") |> json_response(404)
  end
end
