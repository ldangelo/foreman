defmodule ForemanServerWeb.QueueControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

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
      %{
        state
        | run_slots: %{
            capacity: expected.capacity,
            holders: Map.new(expected.running, &{&1, %{}}),
            waiters: Enum.map(expected.waiting, &%{run_id: &1})
          }
      }
    end)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get("/api/queue")

    assert json_response(conn, 200) == %{
             "capacity" => 3,
             "running" => ["run-1"],
             "waiting" => ["run-2", "run-3"],
             "orphan_recovery" => []
           }
  end

  test "GET /api/queue lists orphan_recovery entries" do
    entry = %{
      attempt: 6,
      outcome: "exhausted",
      kind: "slot_release",
      reason: "exit :killed",
      elapsed_since_boot_ms: 1234
    }

    :sys.replace_state(ProjectionStore, fn state ->
      %{
        state
        | run_slots: %{
            capacity: 1,
            holders: %{"run-1" => %{}},
            waiters: [],
            recovery: %{"run-1" => entry}
          }
      }
    end)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get("/api/queue")

    assert %{"orphan_recovery" => [listed]} = json_response(conn, 200)

    assert listed == %{
             "run_id" => "run-1",
             "attempt" => 6,
             "outcome" => "exhausted",
             "kind" => "slot_release",
             "reason" => "exit :killed",
             "elapsed_since_boot_ms" => 1234
           }
  end

  test "GET /api/queue returns 401 when the bearer token is missing" do
    conn = build_conn() |> get("/api/queue")

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end
end
