defmodule ForemanServer.Approvals.PermissionPrompt do
  @moduledoc """
  The decision logic behind the in-flight permission tool (`approve`), served at
  `POST /agent-permission/:run_id` (`ForemanServerWeb.AgentPermissionController`).

  `decide/3` takes the arguments `claude --permission-prompt-tool` sends
  (`tool_name`, `input`, `tool_use_id`) and returns the permission result claude
  expects: `%{"behavior" => "allow", "updatedInput" => input}` or
  `%{"behavior" => "deny", "message" => text}`. It never raises and defaults to
  deny:

    1. the call is registered as a waiter, THEN recorded as a `tool.request`
       (delivery `inflight`, reusing `ForemanServer.Approvals.Requester`), so a
       decision can never beat the registration;
    2. it blocks until the operator's `tool.approve` / `tool.deny` arrives
       (`ForemanServer.Approvals.Deliverer` -> `Inflight.respond/5`);
    3. after `Config.approval_timeout_ms/0` it records a system denial
       (`ForemanServer.Approvals.TimeoutPolicy`, reason `timeout`), waits a short
       grace for that denial's own delivery, and answers deny;
    4. a run that ended while blocked has its open request expired and is denied.

  It cannot approve anything itself: only the operator's `tool.approve` command
  produces an `approve` decision.
  """

  alias ForemanServer.Approvals.{Config, Inflight, Requester, TimeoutPolicy}
  alias ForemanServer.ProjectionStore

  @grace_ms 5_000
  @id_prefix "inflight-"

  @type result :: %{required(String.t()) => term()}

  @doc """
  Decide one permission prompt of `run_id`. `opts`: `:timeout_ms` (default
  `Config.approval_timeout_ms/0`), `:grace_ms`, `:gateway` (test seam).
  """
  @spec decide(String.t(), term(), keyword()) :: result()
  def decide(run_id, %{"tool_name" => tool, "tool_use_id" => use_id} = args, opts)
      when is_binary(tool) and tool != "" and is_binary(use_id) and use_id != "" do
    input = Map.get(args, "input")
    tool_call_id = tool_call_id(args)
    key = {run_id, tool_call_id}

    case ProjectionStore.run(run_id) do
      %{terminal?: false} = run ->
        Inflight.register(run_id, tool_call_id)

        try do
          request_and_wait(run, tool, input, key, opts)
        after
          Inflight.unregister(run_id, tool_call_id)
        end

      _ended_or_unknown ->
        deny("The run is not active, so permission to use the `#{tool}` tool was denied.")
    end
  end

  def decide(_run_id, _args, _opts),
    do: deny("Permission request rejected: tool_name and tool_use_id are required.")

  @doc "The tool-call id `decide/3` uses for a prompt's `tool_use_id`, or `nil` for a malformed prompt."
  @spec tool_call_id(term()) :: String.t() | nil
  def tool_call_id(%{"tool_use_id" => use_id}) when is_binary(use_id) and use_id != "",
    do: @id_prefix <> use_id

  def tool_call_id(_args), do: nil

  @doc """
  The agent that asked is gone (its connection closed): wake the blocked `decide/3` for
  this prompt with a denial, which expires the request. No-op for a malformed prompt.
  """
  @spec client_gone(String.t(), term()) :: :ok
  def client_gone(run_id, args) do
    case tool_call_id(args) do
      nil -> :ok
      id -> _ = Inflight.respond(run_id, id, :deny, "client_gone")
    end

    :ok
  end

  defp request_and_wait(run, tool, input, {run_id, tool_call_id} = key, opts) do
    context = %{run_id: run_id, project_id: run.project_id, provider: :claude}

    request_opts =
      Keyword.take(opts, [:gateway]) ++ [tool_call_id: tool_call_id, delivery: :inflight]

    case Requester.request(context, tool, input, request_opts) do
      {:ok, ^tool_call_id} ->
        case already_decided(key) do
          nil -> wait(key, tool, input, opts)
          decided -> decided |> to_result(tool, input)
        end

      {:error, _reason} ->
        deny("Foreman could not record the permission request for the `#{tool}` tool.")
    end
  end

  # A redelivered prompt for a call the operator already decided.
  defp already_decided({run_id, tool_call_id}) do
    case ProjectionStore.tool_call(run_id, tool_call_id) do
      %{status: status} when status in ["approved", "finished"] -> {:approve, nil}
      %{status: status, reason: reason} when status in ["denied", "expired"] -> {:deny, reason}
      _requested_or_gone -> nil
    end
  end

  defp wait({run_id, tool_call_id} = key, tool, input, opts) do
    timeout = Keyword.get_lazy(opts, :timeout_ms, &Config.approval_timeout_ms/0)

    case Inflight.await(run_id, tool_call_id, timeout) do
      :timeout ->
        timed_out(key, tool, input, opts)

      {:deny, reason} = decision when reason in ["run_ended", "client_gone"] ->
        expire(key, opts, reason)
        to_result(decision, tool, input)

      decision ->
        to_result(decision, tool, input)
    end
  end

  defp timed_out({run_id, tool_call_id}, tool, input, opts) do
    subject = %{run_id: run_id, tool_call_id: tool_call_id}
    policy_opts = Keyword.take(opts, [:gateway]) ++ [on_timeout: :deny]

    # The denial is delivered through the same path as an operator's, so wait for it. When
    # the policy lost a race to an operator decision (`:already_decided`), that decision
    # is being delivered instead and is honoured: the agent is told what the record says.
    decision =
      case TimeoutPolicy.apply(:tool_call, subject, policy_opts) do
        {:ok, _denied_or_already_decided} ->
          Inflight.await(run_id, tool_call_id, Keyword.get(opts, :grace_ms, @grace_ms))

        {:error, _reason} ->
          :timeout
      end

    case decision do
      {:approve, _} = approved -> to_result(approved, tool, input)
      _denied_or_silent -> to_result({:deny, "timeout"}, tool, input)
    end
  end

  # The agent is gone, so its still-open request can no longer be answered.
  defp expire({run_id, tool_call_id}, opts, reason) do
    _ =
      TimeoutPolicy.expire_tool_call(run_id, tool_call_id, reason, Keyword.take(opts, [:gateway]))

    :ok
  end

  defp to_result({:approve, _reason}, _tool, input),
    do: %{"behavior" => "allow", "updatedInput" => input || %{}}

  defp to_result({:deny, "timeout"}, tool, _input),
    do:
      deny(
        "Nobody answered the request to use the `#{tool}` tool in time, so it was denied. Do not use it; continue without it, or say plainly what you cannot do."
      )

  defp to_result({:deny, reason}, tool, _input) when reason in ["run_ended", "client_gone"],
    do: deny("The run ended before the `#{tool}` tool was approved.")

  defp to_result({:deny, _reason}, tool, _input),
    do:
      deny(
        "The operator denied permission to use the `#{tool}` tool. Do not use it; continue without it, or say plainly what you cannot do."
      )

  defp deny(message), do: %{"behavior" => "deny", "message" => message}
end
