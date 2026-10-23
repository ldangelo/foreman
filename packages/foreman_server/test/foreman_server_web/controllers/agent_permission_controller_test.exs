defmodule ForemanServerWeb.AgentPermissionControllerTest do
  # The wire protocol claude's `--permission-prompt-tool` speaks (verified against the
  # real claude 2.1.308 CLI, docs/acceptance/inflight-approvals-live-run.md), through the
  # real endpoint, gateway, aggregates, projection and Deliverer.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias ForemanServer.Aggregates.ToolCall
  alias ForemanServer.Approvals.{Deliverer, Inflight}
  alias ForemanServer.{CommandGateway, CommandRouter, ProjectionStore}

  @moduletag :controller
  @endpoint ForemanServerWeb.Endpoint

  setup do
    :ok = ProjectionStore.subscribe(replay_existing: false)
    start_supervised!(Inflight)
    start_supervised!(Deliverer)

    project_id = "p-#{System.unique_integer([:positive])}"
    run_id = "run-#{System.unique_integer([:positive])}"

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
        task_id: "task-#{run_id}",
        workflow_snapshot: %{phases: [%{id: "phase-1", kind: "command"}]},
        phase_specs: [%{phase_id: "phase-1", kind: "command"}],
        approval_id: "approval-#{run_id}"
      })

    {:ok, run_id: run_id}
  end

  defp rpc(run_id, body, token \\ :valid) do
    token = if token == :valid, do: Inflight.token(run_id), else: token

    build_conn()
    |> put_req_header("authorization", "Bearer " <> to_string(token))
    |> put_req_header("accept", "application/json, text/event-stream")
    |> post("/agent-permission/#{run_id}", Map.put(body, "jsonrpc", "2.0"))
  end

  # `tools/call` replies as a server-sent-event stream: one `data:` JSON message per event.
  defp sse_messages(conn) do
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"

    conn.resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn event ->
      assert "event: message\ndata: " <> json = event
      Jason.decode!(json)
    end)
  end

  test "initialize, tools/list and the server/discover probe are answered like an MCP server", %{
    run_id: run_id
  } do
    assert %{
             "result" => %{
               "protocolVersion" => "2025-11-25",
               "serverInfo" => %{"name" => "foreman-permission"}
             }
           } =
             run_id
             |> rpc(%{
               "id" => 1,
               "method" => "initialize",
               "params" => %{"protocolVersion" => "2025-11-25"}
             })
             |> json_response(200)

    assert %{"result" => %{"tools" => [%{"name" => "approve"}]}} =
             run_id |> rpc(%{"id" => 2, "method" => "tools/list"}) |> json_response(200)

    # Unanswered, claude stalls five seconds on this request.
    assert %{"error" => %{"code" => -32_601}} =
             run_id
             |> rpc(%{"id" => "server-discover-probe-1", "method" => "server/discover"})
             |> json_response(200)

    assert rpc(run_id, %{"method" => "notifications/initialized"}).status == 202

    assert build_conn()
           |> put_req_header("authorization", "Bearer " <> Inflight.token(run_id))
           |> get("/agent-permission/#{run_id}")
           |> response(405)
  end

  test "only the run's own token opens the tool", %{run_id: run_id} do
    body = %{"id" => 1, "method" => "tools/list"}
    assert rpc(run_id, body, "nope").status == 401
    assert rpc(run_id, body, Inflight.token("another-run")).status == 401
    assert build_conn() |> post("/agent-permission/#{run_id}", body) |> response(401)
  end

  test "tools/call blocks until the operator decides over the real command path", %{
    run_id: run_id
  } do
    call = %{
      "id" => 7,
      "method" => "tools/call",
      "params" => %{
        "name" => "approve",
        "arguments" => %{
          "tool_name" => "Write",
          "input" => %{"file_path" => "/w/hello.txt", "content" => "hi"},
          "tool_use_id" => "toolu_http"
        }
      }
    }

    task = Task.async(fn -> rpc(run_id, call) end)
    assert_receive {:projection_event, %{event_type: "ToolCallRequested"}}, 15_000
    assert Task.yield(task, 100) == nil

    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "tool.approve",
        command_id: "op:http:#{run_id}",
        aggregate_id: ToolCall.stream_id(run_id, "inflight-toolu_http"),
        payload: %{run_id: run_id, tool_call_id: "inflight-toolu_http"}
      })

    conn = Task.await(task)

    assert conn.status == 200

    assert [%{"id" => 7, "result" => %{"content" => [%{"type" => "text", "text" => text}]}}] =
             sse_messages(conn)

    assert %{"behavior" => "allow", "updatedInput" => %{"file_path" => "/w/hello.txt"}} =
             Jason.decode!(text)
  end

  test "the agent cannot approve its own request: the tool has no decide path", %{run_id: run_id} do
    # Calling the prompt tool twice for the same call never turns a request into an approval.
    call = fn ->
      %{
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "approve",
          "arguments" => %{"tool_name" => "Bash", "input" => %{}, "tool_use_id" => "toolu_self"}
        }
      }
    end

    first = Task.async(fn -> rpc(run_id, call.()) end)
    assert_receive {:projection_event, %{event_type: "ToolCallRequested"}}, 15_000

    unknown =
      rpc(run_id, %{
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => "tool.approve", "arguments" => %{}}
      })

    assert %{"error" => %{"code" => -32_602}} = json_response(unknown, 200)
    assert %{status: "requested"} = ProjectionStore.tool_call(run_id, "inflight-toolu_self")

    Inflight.cancel_run(run_id, "run_ended")
    assert Task.await(first).status == 200
  end

  test "a blocked call emits progress events for its token, then the result (claude drops a silent reply after ~60s)",
       %{run_id: run_id} do
    Application.put_env(:foreman_server, :approvals, inflight_progress_ms: 30)
    on_exit(fn -> Application.delete_env(:foreman_server, :approvals) end)

    call = %{
      "id" => 9,
      "method" => "tools/call",
      "params" => %{
        "_meta" => %{"progressToken" => 42},
        "name" => "approve",
        "arguments" => %{"tool_name" => "Write", "input" => %{}, "tool_use_id" => "toolu_prog"}
      }
    }

    task = Task.async(fn -> rpc(run_id, call) end)
    assert_receive {:projection_event, %{event_type: "ToolCallRequested"}}, 15_000
    Process.sleep(200)

    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "tool.deny",
        command_id: "op:prog:#{run_id}",
        aggregate_id: ToolCall.stream_id(run_id, "inflight-toolu_prog"),
        payload: %{run_id: run_id, tool_call_id: "inflight-toolu_prog"}
      })

    messages = task |> Task.await() |> sse_messages()
    {progress, [final]} = Enum.split(messages, -1)

    assert progress != []

    assert Enum.all?(
             progress,
             &match?(
               %{"method" => "notifications/progress", "params" => %{"progressToken" => 42}},
               &1
             )
           )

    assert %{"id" => 9, "result" => %{"content" => [%{"text" => text}]}} = final
    assert %{"behavior" => "deny"} = Jason.decode!(text)
  end
end
