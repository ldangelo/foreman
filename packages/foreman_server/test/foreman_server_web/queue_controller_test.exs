defmodule ForemanServerWeb.QueueControllerTest do
  use ExUnit.Case, async: false

  use Phoenix.ConnTest

  alias EventStore.EventData
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.ProjectionStore

  @endpoint ForemanServerWeb.Endpoint
  @token "queue-controller-test-token"
  @run_slots_stream "run_slots:global"

  setup do
    previous_token = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    cleanup_run_slots_stream()
    reset_projection_store()

    on_exit(fn ->
      cleanup_run_slots_stream()
      reset_projection_store()

      if previous_token == nil do
        Application.delete_env(:foreman_server, :api_bearer_token)
      else
        Application.put_env(:foreman_server, :api_bearer_token, previous_token)
      end
    end)
    {:ok, conn: build_conn()}
  end

  describe "GET /api/queue" do
    test "returns 200 with empty queue status", %{conn: _conn} do
      conn = authorized_conn() |> get("/api/queue")

      assert json_response(conn, 200) == %{
               "capacity" => 3,
               "running" => [],
               "waiting" => []
             }
    end

    test "returns waiting runs in FIFO order while queued" do
      run_1 = unique_id("run")
      run_2 = unique_id("run")

      set_projection_capacity(3)

      append_and_apply(@run_slots_stream, 0, "RunSlotQueued", %{
        run_id: run_1,
        position: 1,
        enqueued_at_ms: 100
      })

      append_and_apply(@run_slots_stream, 1, "RunSlotQueued", %{
        run_id: run_2,
        position: 2,
        enqueued_at_ms: 101
      })

      conn = authorized_conn() |> get("/api/queue")

      assert json_response(conn, 200) == %{
               "capacity" => 3,
               "running" => [],
               "waiting" => [run_1, run_2]
             }
    end

    test "transitions a run from waiting to running" do
      run_1 = unique_id("holder")
      run_2 = unique_id("waiter")

      append_and_apply(@run_slots_stream, 0, "RunSlotAcquired", %{
        run_id: run_1,
        capacity: 1,
        acquired_at_ms: 100
      })

      append_and_apply(@run_slots_stream, 1, "RunSlotQueued", %{
        run_id: run_2,
        position: 1,
        enqueued_at_ms: 101
      })

      append_and_apply(@run_slots_stream, 2, "RunSlotTransferred", %{
        released_run_id: run_1,
        acquired_run_id: run_2,
        capacity: 1,
        acquired_at_ms: 200
      })

      conn = authorized_conn() |> get("/api/queue")
      body = json_response(conn, 200)

      assert body["capacity"] == 1
      assert body["running"] == [run_2]
      assert body["waiting"] == []
    end
  end

  defp authorized_conn do
    build_conn() |> put_req_header("authorization", "Bearer #{@token}")
  end

  defp set_projection_capacity(capacity) do
    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      put_in(state, [:run_slots, :capacity], capacity)
    end)
  end

  defp cleanup_run_slots_stream do
    _ = Store.delete_stream(@run_slots_stream, :any_version, :hard)
    :ok
  end

  defp reset_projection_store do
    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      %{
        state
        | projects: %{},
          runs: %{},
          tasks: %{},
          phases: %{},
          pr_associations: %{},
          scheduler_intents: %{},
          worktrees: %{},
          worktree_create_orphans: %{},
          project_active_runs: %{},
          run_slots: %{capacity: 3, holders: %{}, waiters: []},
          works: %{}
      }
    end)
  end

  defp append_and_apply(stream_uuid, expected_version, event_type, payload) do
    :ok =
      Store.append_to_stream(stream_uuid, expected_version, [
        %EventData{event_type: event_type, data: payload, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: event_type, payload: payload}])
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end
end
