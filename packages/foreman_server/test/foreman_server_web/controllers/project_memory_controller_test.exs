defmodule ForemanServerWeb.ProjectMemoryControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.CommandRouter

  @moduletag :tmp_dir
  @endpoint ForemanServerWeb.Endpoint
  @token "project-memory-controller-test-token"

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    project_id = "http-pm-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        aggregate_id: "project:#{project_id}",
        payload: %{project_id: project_id, path: dir}
      })

    {:ok, project_id: project_id, dir: dir}
  end

  defp authed, do: build_conn() |> put_req_header("authorization", "Bearer #{@token}")
  defp base(p), do: "/api/projects/#{p}/memory"

  defp put_topic(p, name, body, conn \\ nil) do
    (conn || authed())
    |> put_req_header("content-type", "application/json")
    |> put(base(p) <> "/" <> name, body)
  end

  test "PUT creates, GET lists and reads, DELETE removes, then GET is 404", %{project_id: p} do
    conn =
      put_topic(p, "conventions", %{
        "description" => "How we work",
        "content" => "Use mix format. TOKEN=abc123secret"
      })

    assert %{
             "entry" => %{
               "name" => "conventions",
               "sha256" => sha,
               "author_kind" => "operator",
               "author_ref" => "api",
               "version" => 1
             }
           } = json_response(conn, 200)

    assert byte_size(sha) == 64

    assert %{
             "index" => index,
             "entries" => [
               %{"name" => "conventions", "author_kind" => "operator", "author_ref" => "api"}
             ]
           } =
             authed() |> get(base(p)) |> json_response(200)

    assert index =~ "[conventions](conventions.md) - How we work"

    body = authed() |> get(base(p) <> "/conventions") |> json_response(200)
    assert body["content"] =~ "Use mix format."
    refute body["content"] =~ "abc123secret"

    assert %{"status" => "forgotten"} =
             authed() |> delete(base(p) <> "/conventions") |> json_response(200)

    assert %{"error" => "not_found"} =
             authed() |> get(base(p) <> "/conventions") |> json_response(404)

    assert %{"error" => "not_found"} =
             authed() |> delete(base(p) <> "/conventions") |> json_response(404)
  end

  test "the operator header becomes the author ref", %{project_id: p} do
    conn = authed() |> put_req_header("x-foreman-operator", "alice")
    assert json_response(put_topic(p, "a", %{"content" => "x"}, conn), 200)

    assert %{"entries" => [%{"author_ref" => "alice"}]} =
             authed() |> get(base(p)) |> json_response(200)
  end

  test "validation: non-string content/description 422, over-cap 422 with code, bad name 422", %{
    project_id: p
  } do
    assert %{"error" => "invalid_body"} =
             put_topic(p, "a", %{"content" => 5}) |> json_response(422)

    assert %{"error" => "invalid_body"} =
             put_topic(p, "a", %{"content" => "x", "description" => 5}) |> json_response(422)

    assert %{"error" => "invalid_body"} = put_topic(p, "a", %{}) |> json_response(422)

    assert %{"error" => "content_too_large"} =
             put_topic(p, "big", %{"content" => String.duplicate("a", 65_537)})
             |> json_response(422)

    assert %{"error" => "name_invalid"} =
             put_topic(p, "Bad_Name", %{"content" => "x"}) |> json_response(422)
  end

  test "the description cap is the configured :max_description_chars", %{project_id: p} do
    original = Application.fetch_env!(:foreman_server, :project_memory)
    on_exit(fn -> Application.put_env(:foreman_server, :project_memory, original) end)

    Application.put_env(
      :foreman_server,
      :project_memory,
      Keyword.put(original, :max_description_chars, 10)
    )

    assert %{"error" => "invalid_body", "message" => message} =
             put_topic(p, "a", %{"content" => "x", "description" => String.duplicate("d", 11)})
             |> json_response(422)

    assert message =~ "at most 10 characters"

    assert %{"entry" => %{"description" => description}} =
             put_topic(p, "a", %{"content" => "x", "description" => String.duplicate("d", 10)})
             |> json_response(200)

    assert description == String.duplicate("d", 10)
  end

  test "unknown project is 404 and archived project is 409", %{project_id: p} do
    assert %{"error" => "project_not_found"} =
             put_topic("ghost-project", "a", %{"content" => "x"}) |> json_response(404)

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.archive",
        aggregate_id: "project:#{p}",
        payload: %{project_id: p}
      })

    assert %{"error" => "project_archived"} =
             put_topic(p, "a", %{"content" => "x"}) |> json_response(409)
  end

  test "POST sync records a hand edit", %{project_id: p, dir: dir} do
    File.mkdir_p!(Path.join(dir, ".foreman/memory"))
    File.write!(Path.join(dir, ".foreman/memory/hand.md"), "added in an editor")

    assert %{"recorded" => ["hand"], "forgotten" => [], "failed" => []} =
             authed() |> post(base(p) <> "/sync") |> json_response(200)

    assert %{"recorded" => []} = authed() |> post(base(p) <> "/sync") |> json_response(200)
  end

  test "project.memory.write is not available through POST /api/commands", %{
    project_id: p,
    dir: dir
  } do
    conn =
      authed()
      |> put_req_header("content-type", "application/json")
      |> post("/api/commands", %{
        "type" => "project.memory.write",
        "command_id" => "x-1",
        "aggregate_id" => "project_memory:#{p}",
        "payload" => %{
          "project_id" => p,
          "name" => "a",
          "sha256" => String.duplicate("a", 64),
          "bytes" => 1,
          "author_kind" => "operator"
        }
      })

    assert conn.status in [400, 403, 422]
    assert %{"error" => _} = json_response(conn, conn.status)
    refute File.exists?(Path.join(dir, ".foreman/memory/a.md"))
  end
end
