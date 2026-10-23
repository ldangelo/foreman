defmodule ForemanServerWeb.AgentPermissionListenerTest do
  # `Phoenix.ConnTest` never goes through Cowboy, so it cannot see what Cowboy does to a
  # long-lived response. Live run (docs/acceptance/live-claude-and-approvals.md): a blocked
  # permission prompt was lost after 60 s. Cowboy closes a connection that has RECEIVED no data
  # for `idle_timeout` (default 60 s; `reset_idle_timeout_on_send` is off, so the progress events
  # the controller keeps sending do not count), killing the request process and the blocked
  # decision with it; an approval after that reached nobody (`delivery_failed:
  # :no_live_request`) while the UI said "Done". This drives the endpoint through a REAL
  # listener whose idle timeout is shrunk to milliseconds.
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.ToolCall
  alias ForemanServer.Approvals.{Deliverer, Inflight}
  alias ForemanServer.{CommandGateway, CommandRouter, ProjectionStore}

  @moduletag :controller

  @idle_timeout_ms 250

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

    Application.put_env(:foreman_server, :approvals, inflight_progress_ms: 40)
    on_exit(fn -> Application.delete_env(:foreman_server, :approvals) end)

    ref = :"agent_permission_listener_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Plug.Cowboy,
       scheme: :http,
       plug: ForemanServerWeb.Endpoint,
       ref: ref,
       port: 0,
       ip: {127, 0, 0, 1},
       protocol_options: [idle_timeout: @idle_timeout_ms]}
    )

    {:ok, run_id: run_id, port: :ranch.get_port(ref)}
  end

  test "a blocked prompt outlives the listener's idle timeout and is answered by a late approval",
       %{run_id: run_id, port: port} do
    socket = open(port, run_id, "toolu_idle")

    # The stream is open and alive: headers plus a first progress event.
    acc = read_until(socket, "notifications/progress", "")
    assert acc =~ "HTTP/1.1 200"
    assert_receive {:projection_event, %{event_type: "ToolCallRequested"}}, 15_000

    # Idle for three times the listener's idle timeout. The client sends nothing; the server
    # keeps sending progress events, which Cowboy does not count as activity.
    acc = read_for(socket, 3 * @idle_timeout_ms, acc)

    refute acc == :closed,
           "Cowboy closed the connection after its idle timeout: the blocked decision was lost"

    assert %{status: "requested"} = ProjectionStore.tool_call(run_id, "inflight-toolu_idle")

    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "tool.approve",
        command_id: "op:listener:#{run_id}",
        aggregate_id: ToolCall.stream_id(run_id, "inflight-toolu_idle"),
        payload: %{run_id: run_id, tool_call_id: "inflight-toolu_idle"}
      })

    answer = read_until(socket, ~S(\"behavior\":\"allow\"), acc)
    assert answer =~ ~S(\"behavior\":\"allow\")

    assert_receive {:projection_event, %{event_type: "ToolCallFinished"}}, 15_000

    assert %{status: "finished", outcome: "delivered"} =
             ProjectionStore.tool_call(run_id, "inflight-toolu_idle")

    :gen_tcp.close(socket)
  end

  # A raw HTTP/1.1 POST of one `tools/call approve` (what claude's HTTP MCP transport sends).
  defp open(port, run_id, tool_use_id) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "tools/call",
        "params" => %{
          "_meta" => %{"progressToken" => 42},
          "name" => "approve",
          "arguments" => %{
            "tool_name" => "Write",
            "input" => %{"file_path" => "/w/hello.txt", "content" => "hi"},
            "tool_use_id" => tool_use_id
          }
        }
      })

    head =
      "POST /agent-permission/#{run_id} HTTP/1.1\r\nhost: localhost\r\n" <>
        "authorization: Bearer #{Inflight.token(run_id)}\r\n" <>
        "content-type: application/json\r\naccept: application/json, text/event-stream\r\n" <>
        "content-length: #{byte_size(body)}\r\n\r\n"

    :ok = :gen_tcp.send(socket, [head, body])
    socket
  end

  # Accumulate the response until `pattern` shows up; flunk if the peer closes first.
  defp read_until(socket, pattern, acc) do
    cond do
      acc == :closed ->
        flunk("the connection was closed before #{inspect(pattern)} arrived")

      String.contains?(acc, pattern) ->
        acc

      true ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> read_until(socket, pattern, acc <> data)
          {:error, :closed} -> read_until(socket, pattern, :closed)
          {:error, reason} -> flunk("no #{inspect(pattern)} within 5 s: #{inspect(reason)}")
        end
    end
  end

  # Keep reading for `ms`; `:closed` when the peer hangs up in the meantime.
  defp read_for(socket, ms, acc) do
    deadline = System.monotonic_time(:millisecond) + ms
    do_read_for(socket, deadline, acc)
  end

  defp do_read_for(socket, deadline, acc) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      acc
    else
      case :gen_tcp.recv(socket, 0, left) do
        {:ok, data} -> do_read_for(socket, deadline, acc <> data)
        {:error, :timeout} -> acc
        {:error, :closed} -> :closed
      end
    end
  end
end
