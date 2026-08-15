defmodule ForemanServerWeb.QueueControllerTest do
  use ExUnit.Case, async: false

  use Phoenix.ConnTest

  alias ForemanServer.ProjectionStore

  @endpoint ForemanServerWeb.Endpoint
  @token "queue-controller-test-token"

  setup do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    original_state = :sys.get_state(ProjectionStore)

    on_exit(fn ->
      :sys.replace_state(ProjectionStore, fn _ -> original_state end)

      if previous == nil do
        Application.delete_env(:foreman_server, :api_bearer_token)
      else
        Application.put_env(:foreman_server, :api_bearer_token, previous)
      end
    end)

    :ok
  end

  test "GET /api/queue returns queue status" do
    expected = %{capacity: 3, running: ["run-1"], waiting: ["run-2", "run-3"]}

    :sys.replace_state(ProjectionStore, fn state ->
      Map.merge(state, %{
        run_slots_capacity: expected.capacity,
        run_slots_allocations: MapSet.new(expected.running),
        run_slots_waiting: :queue.from_list(expected.waiting)
      })
    end)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get("/api/queue")

    assert json_response(conn, 200) == %{
             "capacity" => 3,
             "running" => ["run-1"],
             "waiting" => ["run-2", "run-3"]
           }
  end

  test "GET /api/queue returns 401 when the bearer token is missing" do
    conn = build_conn() |> get("/api/queue")

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end
end
