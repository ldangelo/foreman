defmodule ForemanServerWeb.WorkControllerTest do
  use ExUnit.Case, async: false

  use Phoenix.ConnTest

  alias ForemanServer.ProjectionStore

  @endpoint ForemanServerWeb.Endpoint
  @token "work-controller-test-token"

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

  test "GET /api/work/:id returns work when found" do
    work = %{"work_id" => "work-1", "status" => "submitted"}

    :sys.replace_state(ProjectionStore, fn state ->
      Map.put(state, :works, %{"work-1" => work})
    end)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get("/api/work/work-1")

    assert json_response(conn, 200) == work
  end

  test "GET /api/work/:id returns 404 when work is missing" do
    :sys.replace_state(ProjectionStore, fn state ->
      Map.put(state, :works, %{})
    end)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get("/api/work/missing")

    assert json_response(conn, 404) == %{"error" => "work_not_found"}
  end

  test "GET /api/work/:id returns 401 when the bearer token is missing" do
    conn = build_conn() |> get("/api/work/work-1")

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end
end
