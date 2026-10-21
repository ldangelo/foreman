defmodule ForemanServerWeb.ThreadSteerControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.CommandRouter
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "thread-steer-controller-test-token"

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

  defp post_steer(id, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> post("/api/threads/#{id}/steer", body)
  end

  test "unknown thread is 404" do
    assert %{"error" => "thread_not_found", "thread_id" => "run:nope"} =
             json_response(post_steer("run:nope", %{"text" => "hi"}), 404)
  end

  test "terminal thread is 409 not_steerable naming its status" do
    run_id = start_run!()
    assert {:ok, :stopping} = ForemanServer.Threads.Actions.stop("run:#{run_id}")

    assert %{"error" => "not_steerable", "status" => "cancelled", "thread_id" => thread_id} =
             json_response(post_steer("run:#{run_id}", %{"text" => "hi"}), 409)

    assert thread_id == "run:#{run_id}"
    assert ProjectionStore.pending_steering(run_id) == []
  end

  test "blank, missing, oversize text and a non-boolean resume are 400" do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: %{run_id: "live", project_id: "p"}}
      ])

    for body <- [
          %{"text" => "   "},
          %{},
          %{"text" => String.duplicate("x", 8001)},
          %{"text" => "ok", "resume" => "yes"}
        ] do
      assert %{"error" => "invalid_params"} = json_response(post_steer("run:live", body), 400)
    end
  end

  test "a live run is 202 with message_id and mode, and the message is queued" do
    run_id = start_run!()

    assert %{"thread_id" => thread_id, "message_id" => "http-m", "mode" => "pause_resume"} =
             json_response(
               post_steer("run:#{run_id}", %{
                 "text" => "use the cache",
                 "message_id" => "http-m",
                 "resume" => false
               }),
               202
             )

    assert thread_id == "run:#{run_id}"
    assert [%{message_id: "http-m"}] = ProjectionStore.pending_steering(run_id)

    assert %{"message_id" => generated} =
             json_response(post_steer("run:#{run_id}", %{"text" => "again"}), 202)

    assert generated != "http-m"
  end

  defp start_run! do
    n = System.unique_integer([:positive])
    project_id = "steer-http-project-#{n}"
    run_id = "steer-http-run-#{n}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        aggregate_id: "project:#{project_id}",
        command_id: "register:#{project_id}",
        type: "project.register",
        payload: %{project_id: project_id, name: project_id, path: System.tmp_dir!()}
      })

    {:ok, _} =
      CommandRouter.dispatch_run_start(project_id, %{
        run_id: run_id,
        task_id: "task-#{n}",
        workflow_snapshot: %{phases: [%{id: "phase-1", kind: "command"}]},
        phase_specs: [%{phase_id: "phase-1", kind: "command"}],
        approval_id: "approval-#{n}"
      })

    run_id
  end
end
