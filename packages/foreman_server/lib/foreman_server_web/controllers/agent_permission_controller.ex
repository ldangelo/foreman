defmodule ForemanServerWeb.AgentPermissionController do
  @moduledoc """
  The permission-prompt MCP tool of one claude run, over streamable-HTTP MCP with
  plain `application/json` replies (`POST /agent-permission/:run_id`).

  `claude --permission-prompt-tool mcp__foreman_permission__approve` sends every
  tool call that would prompt to the `approve` tool; this controller answers it
  through `ForemanServer.Approvals.PermissionPrompt`, which BLOCKS the reply until
  the operator decides (or a timeout denies). See `docs/plans/inflight-approvals.md`.

  It speaks exactly what the claude client sends: `initialize`, `tools/list`,
  `tools/call`, notifications (202) and the `server/discover` probe (answered with a
  JSON-RPC error: an unanswered request stalls the client for five seconds). The
  `GET` event-stream channel is refused (405). `tools/call` replies as a server-sent-event stream (see `stream_decision/4`).

  Authentication is the run's own bearer token (`ForemanServer.Approvals.Inflight.token/1`),
  not the operator token, so the agent holds no credential for anything but its own
  prompt tool. Deciding stays the operator's `tool.approve` / `tool.deny` command;
  this tool can only create a request and wait.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.Approvals.{Config, Inflight, PermissionPrompt}

  @protocol_fallback "2025-11-25"

  def stream_unsupported(conn, _params), do: send_resp(conn, 405, "")

  def rpc(conn, %{"run_id" => run_id} = params) do
    if authorized?(conn, run_id) do
      handle_rpc(conn, run_id, Map.drop(params, ["run_id"]))
    else
      conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})
    end
  end

  defp authorized?(conn, run_id) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Inflight.valid_token?(run_id, String.trim(token))
      _ -> false
    end
  end

  # A notification (no id) is acknowledged without a body.
  defp handle_rpc(conn, _run_id, %{"method" => "notifications/" <> _}),
    do: send_resp(conn, 202, "")

  defp handle_rpc(conn, _run_id, %{"method" => _, "id" => nil}), do: send_resp(conn, 202, "")

  defp handle_rpc(conn, _run_id, %{"method" => "initialize", "id" => id} = rpc) do
    version = get_in(rpc, ["params", "protocolVersion"]) || @protocol_fallback

    reply(conn, id, %{
      "protocolVersion" => version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "foreman-permission", "version" => "1.0.0"}
    })
  end

  defp handle_rpc(conn, _run_id, %{"method" => "tools/list", "id" => id}),
    do: reply(conn, id, %{"tools" => [tool_definition()]})

  defp handle_rpc(conn, run_id, %{"method" => "tools/call", "id" => id, "params" => params}) do
    case params do
      %{"name" => "approve"} -> stream_decision(conn, run_id, id, params)
      _other -> error(conn, id, -32602, "unknown tool")
    end
  end

  defp handle_rpc(conn, _run_id, %{"method" => method, "id" => id}),
    do: error(conn, id, -32601, "method not found: #{method}")

  defp handle_rpc(conn, _run_id, _malformed), do: error(conn, nil, -32600, "invalid request")

  # The decision can take an operator minutes, but the claude CLI abandons a plain HTTP reply
  # after ~60 s ("The operation timed out", observed on 2.1.308: the call fails and the model
  # retries). A `text/event-stream` reply that emits `notifications/progress` for the request's
  # `progressToken` keeps it alive (probed: a 100 s block over one call). So the reply is chunked:
  # a progress event every `Config.inflight_progress_ms/0` while the decision is pending, then the result.
  defp stream_decision(conn, run_id, id, params) do
    args = Map.get(params, "arguments")
    token = get_in(params, ["_meta", "progressToken"])
    task = Task.async(fn -> PermissionPrompt.decide(run_id, args, []) end)

    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
    |> stream_until_decided(task, run_id, args, id, token, 1)
  end

  defp stream_until_decided(conn, task, run_id, args, id, token, n) do
    case Task.yield(task, Config.inflight_progress_ms()) do
      {:ok, result} ->
        {:ok, conn} =
          chunk(conn, sse(%{"jsonrpc" => "2.0", "id" => id, "result" => result_content(result)}))

        conn

      nil ->
        case token && chunk(conn, sse(progress(token, n))) do
          {:error, _closed} ->
            # claude went away: release the blocked decision, which expires the request.
            PermissionPrompt.client_gone(run_id, args)
            _ = Task.await(task, 10_000)
            conn

          {:ok, conn} ->
            stream_until_decided(conn, task, run_id, args, id, token, n + 1)

          _no_progress_token ->
            stream_until_decided(conn, task, run_id, args, id, token, n + 1)
        end

      {:exit, _reason} ->
        conn
    end
  end

  defp progress(token, n) do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/progress",
      "params" => %{
        "progressToken" => token,
        "progress" => n,
        "message" => "waiting for the operator"
      }
    }
  end

  defp result_content(result),
    do: %{"content" => [%{"type" => "text", "text" => Jason.encode!(result)}]}

  defp sse(message), do: "event: message\ndata: " <> Jason.encode!(message) <> "\n\n"

  defp tool_definition do
    %{
      "name" => Inflight.tool_name(),
      "description" =>
        "Foreman's permission prompt: asks the operator whether this tool call may run.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "tool_name" => %{"type" => "string"},
          "input" => %{"type" => "object"},
          "tool_use_id" => %{"type" => "string"}
        },
        "required" => ["tool_name", "input"]
      }
    }
  end

  defp reply(conn, id, result),
    do: json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp error(conn, id, code, message),
    do:
      json(conn, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => code, "message" => message}
      })
end
