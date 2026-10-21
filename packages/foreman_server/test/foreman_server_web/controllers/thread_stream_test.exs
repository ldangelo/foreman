defmodule ForemanServerWeb.ThreadStreamTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias EventStore.EventData
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.ProjectionStore

  @endpoint ForemanServerWeb.Endpoint
  @token "thread-stream-test-token"

  setup do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    on_exit(fn ->
      Application.delete_env(:foreman_server, :thread_stream_heartbeat_ms)

      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    :ok
  end

  defp uid(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp api_get(path) do
    build_conn() |> put_req_header("authorization", "Bearer #{@token}") |> get(path)
  end

  defp append(run_id, expected_version, events) do
    stream = "run:#{run_id}"

    :ok =
      Store.append_to_stream(
        stream,
        expected_version,
        Enum.map(events, fn {type, data} ->
          %EventData{event_type: type, data: Map.put(data, :run_id, run_id), metadata: %{}}
        end)
      )

    if expected_version == 0 do
      on_exit(fn -> Store.delete_stream(stream, :any_version, :hard) end)
    end
  end

  defp apply_event(type, payload),
    do: ProjectionStore.apply_events([%{event_type: type, payload: payload}])

  # Runs the request in its own process (the chunked response blocks until the
  # stream closes) and returns the Task.
  defp open_stream(path), do: Task.async(fn -> api_get(path) end)

  # The stream subscribes to the projection before its first read, so once the
  # task is a subscriber no later event can be missed.
  defp await_subscriber(%Task{pid: pid}) do
    await(fn -> Map.has_key?(:sys.get_state(ProjectionStore).subscribers, pid) end)
  end

  defp await(fun, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition never became true")
      true -> await(fun, deadline)
    end
  end

  defp turn_payloads(body) do
    for [_, json] <- Regex.scan(~r/event: turn\ndata: (.*)\n\n/, body), do: Jason.decode!(json)
  end

  test "tail emits each new turn once and closes when the thread goes terminal" do
    run_id = uid("sse-run")
    :ok = apply_event("RunStarted", %{run_id: run_id, project_id: "p-sse"})

    task = open_stream("/api/threads/run:#{run_id}/stream")
    await_subscriber(task)

    append(run_id, 0, [{"RunSteerQueued", %{message_id: uid("m"), text: "go left"}}])

    :ok =
      apply_event("RunSteerQueued", %{run_id: run_id, message_id: uid("m"), text: "go left"})

    append(run_id, 1, [{"RunCompleted", %{}}])
    :ok = apply_event("RunCompleted", %{run_id: run_id, project_id: "p-sse"})

    conn = Task.await(task, 10_000)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"

    assert [steer, completed] = turn_payloads(conn.resp_body)
    assert %{"seq" => 0, "role" => "operator", "kind" => "steer", "text" => "go left"} = steer
    assert %{"seq" => 1, "role" => "system", "text" => "Run completed"} = completed
    assert String.ends_with?(conn.resp_body, "event: end\ndata: {\"terminal\":true}\n\n")
  end

  test "after replays only the missed turns and an already-terminal thread closes at once" do
    run_id = uid("sse-replay")
    append(run_id, 0, [{"RunPaused", %{reason: "a"}}, {"RunResumed", %{}}, {"RunCompleted", %{}}])

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: %{run_id: run_id, project_id: "p-sse"}},
        %{event_type: "RunCompleted", payload: %{run_id: run_id, project_id: "p-sse"}}
      ])

    conn = api_get("/api/threads/run:#{run_id}/stream?after=0")

    assert conn.status == 200
    assert [%{"seq" => 1, "text" => "Run resumed"}, %{"seq" => 2}] = turn_payloads(conn.resp_body)
    assert String.ends_with?(conn.resp_body, "event: end\ndata: {\"terminal\":true}\n\n")
  end

  test "an idle stream sends heartbeat comments at the configured interval" do
    # 0 ms: the stream heartbeats whenever its mailbox is empty, so no clock is needed
    Application.put_env(:foreman_server, :thread_stream_heartbeat_ms, 0)

    run_id = uid("sse-hb")
    :ok = apply_event("RunStarted", %{run_id: run_id, project_id: "p-sse"})

    task = open_stream("/api/threads/run:#{run_id}/stream")
    await_subscriber(task)

    # let the idle stream demonstrably loop before the thread ends
    {:reductions, start} = Process.info(task.pid, :reductions)

    await(fn ->
      case Process.info(task.pid, :reductions) do
        {:reductions, now} -> now - start > 500_000
        nil -> true
      end
    end)

    :ok = apply_event("RunCompleted", %{run_id: run_id, project_id: "p-sse"})

    conn = Task.await(task, 10_000)

    assert conn.resp_body =~ ": heartbeat\n\n"
    refute conn.resp_body =~ "event: turn"
    assert String.ends_with?(conn.resp_body, "event: end\ndata: {\"terminal\":true}\n\n")
  end

  test "junk or unknown parameters never open a stream" do
    assert %{status: 400} = api_get("/api/threads/run:x/stream?after=junk")
    assert %{status: 400} = api_get("/api/threads/run:x/stream?after=-2")
    assert %{status: 404} = api_get("/api/threads/run:#{uid("nope")}/stream")
  end

  describe "GET /api/threads/:id/transcript" do
    test "pages with after and limit; junk is a 400; unknown thread a 404" do
      run_id = uid("http-run")

      append(run_id, 0, [
        {"RunPaused", %{reason: "a"}},
        {"RunResumed", %{}},
        {"RunCompleted", %{}}
      ])

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "RunStarted", payload: %{run_id: run_id, project_id: "p-http"}},
          %{event_type: "RunCompleted", payload: %{run_id: run_id, project_id: "p-http"}}
        ])

      body = json_response(api_get("/api/threads/run:#{run_id}/transcript?limit=2"), 200)

      assert %{
               "next_cursor" => 1,
               "truncated" => false,
               "omitted_entries" => 0,
               "terminal" => true
             } =
               body

      assert Enum.map(body["turns"], & &1["seq"]) == [0, 1]
      assert hd(body["turns"])["text"] == "Run paused: a"

      rest = json_response(api_get("/api/threads/run:#{run_id}/transcript?after=1"), 200)
      assert [%{"seq" => 2, "text" => "Run completed"}] = rest["turns"]

      for bad <- ["after=x", "after=-2", "limit=0", "limit=1001", "limit=abc"] do
        assert %{status: 400} = api_get("/api/threads/run:#{run_id}/transcript?#{bad}")
      end

      assert %{status: 404} = api_get("/api/threads/run:#{uid("nope")}/transcript")
    end
  end
end
