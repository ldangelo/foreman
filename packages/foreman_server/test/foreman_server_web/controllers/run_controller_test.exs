defmodule ForemanServerWeb.RunControllerTest do
  @moduledoc """
  `GET /api/runs` and `GET /api/runs/:id` for a run that recorded usage.

  The run projection holds a `%ForemanServer.Usage{}` struct (`usage`, and one per
  worker). The controller used to enumerate it while stringifying keys, so every real
  run - they all report usage - answered 500 and `foreman run get` could not read it
  (found by the E12-S12 live e2e).
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "run-controller-token"
  @run_id "run-usage-controller"

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: "proj", path: "/tmp/proj"}},
        %{
          event_type: "RunStarted",
          payload: %{
            run_id: @run_id,
            project_id: "proj",
            task_id: "task-usage",
            workflow_snapshot: %{}
          }
        },
        %{
          event_type: "UsageRecorded",
          payload: %{
            run_id: @run_id,
            worker_id: "w1",
            provider: "pi",
            project_id: "proj",
            model: "m1",
            input_tokens: 10,
            output_tokens: 5,
            total_tokens: 15,
            cost_usd: 0.01,
            at: "2026-01-01T10:00:00Z"
          }
        }
      ])

    :ok
  end

  defp get_json(path) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> get(path)
    |> json_response(200)
  end

  test "GET /api/runs/:id renders the run's usage struct" do
    assert %{"run" => %{"run_id" => @run_id, "usage" => usage, "workers" => workers}} =
             get_json("/api/runs/#{@run_id}")

    assert %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15} = usage
    assert usage["cost_usd"] == 0.01
    assert %{"w1" => %{"usage" => ^usage}} = workers
  end

  test "GET /api/runs lists a run that recorded usage" do
    assert %{"runs" => [%{"run_id" => @run_id, "usage" => %{"total_tokens" => 15}}]} =
             get_json("/api/runs?project_id=proj")
  end

  describe "a run id that admission has not turned into a run yet (foreman-s19h6)" do
    setup do
      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "TaskCreated",
            payload: %{
              task_id: "task-wait",
              project_id: "proj",
              title: "waiting",
              status: "open",
              task_type: "implement"
            }
          },
          %{
            event_type: "TaskApproved",
            payload: %{
              task_id: "task-wait",
              approval_id: "a-wait",
              approved_by: "t",
              approved_at: "2026-03-04T10:00:00Z",
              run_id: "run-wait",
              workflow_snapshot: %{}
            }
          },
          %{
            event_type: "TaskDispatched",
            payload: %{task_id: "task-wait", run_id: "run-wait", approval_id: "a-wait"}
          }
        ])

      :ok
    end

    test "is queued before any refusal is recorded, deferred with its reason after" do
      assert %{"run" => %{"run_id" => "run-wait", "status" => "queued", "reason" => nil}} =
               get_json("/api/runs/run-wait")

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "ProjectAdmissionDeferred",
            payload: %{
              project_id: "proj",
              task_id: "task-wait",
              reason: "run_limit_exceeded",
              day: "2026-03-04"
            }
          }
        ])

      assert %{
               "run" => %{
                 "run_id" => "run-wait",
                 "task_id" => "task-wait",
                 "status" => "deferred",
                 "reason" => "run_limit_exceeded"
               }
             } = get_json("/api/runs/run-wait")
    end

    test "an unknown run id is still a 404" do
      assert %{"error" => "run_not_found"} =
               build_conn()
               |> put_req_header("authorization", "Bearer #{@token}")
               |> get("/api/runs/run-nobody")
               |> json_response(404)
    end
  end
end
