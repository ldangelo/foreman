defmodule ForemanServerWeb.ThreadStopControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.Jobsite.Control
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "thread-stop-controller-test-token"

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

    :ok
  end

  defp post_stop(id, body \\ %{}) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> post("/api/threads/#{id}/stop", body)
  end

  test "unknown thread is 404" do
    assert %{"error" => "thread_not_found", "thread_id" => "run:nope"} =
             json_response(post_stop("run:nope"), 404)
  end

  test "terminal thread is 409 naming its status" do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: %{run_id: "done", project_id: "p"}},
        %{event_type: "RunCompleted", payload: %{run_id: "done", project_id: "p"}}
      ])

    assert %{"error" => "not_stoppable", "status" => "completed", "thread_id" => "run:done"} =
             json_response(post_stop("run:done"), 409)
  end

  test "stoppable jobsite with an executor is 200 and records the cancel intent" do
    id = "js-http-stop-#{System.unique_integer([:positive])}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "JobsiteStarted",
          payload: %{jobsite_id: id, repo_path: "/r", strategy: "head", project_id: "p"}
        }
      ])

    {:ok, _} = Registry.register(ForemanServer.Jobsite.Registry, id, nil)
    on_exit(fn -> Control.clear(id) end)

    assert %{"thread_id" => thread_id, "requested" => "stopping"} =
             json_response(post_stop("jobsite:#{id}", %{"reason" => "http"}), 200)

    assert thread_id == "jobsite:#{id}"
    assert Control.intent(id) == {:cancel, "http"}
  end

  test "starting jobsite with no executor is 409 no_executor" do
    id = "js-http-orphan-#{System.unique_integer([:positive])}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "JobsiteStarted",
          payload: %{jobsite_id: id, repo_path: "/r", strategy: "head", project_id: "p"}
        }
      ])

    assert %{"error" => "no_executor", "status" => "starting"} =
             json_response(post_stop("jobsite:#{id}"), 409)
  end
end
