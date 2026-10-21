defmodule ForemanServerWeb.ThreadControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "thread-controller-test-token"

  @dto_keys ~w(branch created_at door id last_report pr_url project_id provider_session_id
               repo_path resolved run_ids status steering task_id title updated_at)

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

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "TaskCreated",
          payload: %{
            task_id: "t1",
            project_id: "p",
            title: "A task",
            status: "open",
            task_type: "implement"
          }
        },
        %{
          event_type: "RunStarted",
          payload: %{run_id: "r1", task_id: "t1", project_id: "p"}
        },
        %{
          event_type: "JobsiteStarted",
          payload: %{jobsite_id: "j1", repo_path: "/r", strategy: "worktree", project_id: "p"}
        },
        %{
          event_type: "ReviewRecorded",
          payload: %{
            subject_kind: "run",
            subject_id: "r1",
            verdict: "met",
            summary: "fine",
            at: "2026-01-01T00:00:00Z"
          }
        }
      ])

    :ok
  end

  defp api_get(path) do
    build_conn() |> put_req_header("authorization", "Bearer #{@token}") |> get(path)
  end

  test "list returns string-keyed whitelisted DTOs for both doors" do
    body = json_response(api_get("/api/projects/p/threads"), 200)

    assert body |> Map.fetch!("threads") |> Enum.map(& &1["id"]) |> Enum.sort() ==
             ["jobsite:j1", "run:r1"]

    for thread <- body["threads"] do
      assert thread |> Map.keys() |> Enum.sort() == @dto_keys
      assert thread["steering"] == "pause_resume"
      assert thread["resolved"] == false
    end

    run = Enum.find(body["threads"], &(&1["id"] == "run:r1"))
    assert run["door"] == "workflow"

    assert run["last_report"] == %{
             "verdict" => "met",
             "summary" => "fine",
             "at" => "2026-01-01T00:00:00Z"
           }
  end

  test "door filter and limit are honoured" do
    body = json_response(api_get("/api/projects/p/threads?door=jobsite"), 200)
    assert [%{"id" => "jobsite:j1"}] = body["threads"]

    body = json_response(api_get("/api/projects/p/threads?limit=1"), 200)
    assert [_one] = body["threads"]

    body = json_response(api_get("/api/projects/nope/threads"), 200)
    assert body["threads"] == []
  end

  test "bad limit or door is 400, not a crash" do
    for query <- ["limit=0", "limit=abc", "limit=501", "limit=-1", "door=bogus"] do
      assert %{"error" => "invalid_params"} =
               json_response(api_get("/api/projects/p/threads?#{query}"), 400)
    end
  end

  test "show returns one thread, unknown id is 404" do
    body = json_response(api_get("/api/threads/run:r1"), 200)
    assert body["thread"]["id"] == "run:r1"
    assert body["thread"] |> Map.keys() |> Enum.sort() == @dto_keys

    assert %{"error" => "thread_not_found", "thread_id" => "run:zzz"} =
             json_response(api_get("/api/threads/run:zzz"), 404)
  end

  test "requires the bearer token" do
    conn = get(build_conn(), "/api/projects/p/threads")
    assert conn.status in [401, 403]
  end
end
