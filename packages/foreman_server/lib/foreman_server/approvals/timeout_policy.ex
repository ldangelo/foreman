defmodule ForemanServer.Approvals.TimeoutPolicy do
  @moduledoc """
  What happens when a tool-call request or an operator question is not answered in
  time (`config :foreman_server, :approvals, on_timeout:`).

    * `:surface` (default) - the request is expired (`tool.expire` /
      `question.expire`): a durable `ToolCallExpired` / `QuestionExpired`, so the
      thread shows up in the Overview as waiting on you with reason
      `:approval_expired` / `:question_expired` instead of silently doing nothing.
      An expired call can no longer be approved; the operator re-requests by
      resuming or steering the run.
    * `:deny` - a tool call is denied (`tool.deny`, `decided_by: "system"`, reason
      `"timeout"`) and `ForemanServer.Approvals.Deliverer` tells the agent and
      resumes the run. It is denied only, never also expired (a denied call is
      terminal). A question has nothing to deny, so it expires under both policies.

  Every command carries a deterministic `command_id`, and the aggregates reject a
  decision on a request that is no longer open, so applying the policy twice (the
  sweeper and the fast-path timer racing, or a restart) records it once:
  `{:ok, :already_decided}` for the loser.
  """

  alias ForemanServer.Aggregates.{OperatorQuestion, ToolCall}
  alias ForemanServer.Approvals.{Config, Dispatch}

  @type outcome :: {:ok, :expired | :denied | :already_decided} | {:error, term()}

  @doc """
  Apply the policy to a projected tool call (`:tool_call`) or question
  (`:question`). `opts`: `:on_timeout` (default `Config.on_timeout/0`), `:gateway`.
  """
  @spec apply(:tool_call | :question, map(), keyword()) :: outcome()
  def apply(kind, subject, opts \\ [])

  def apply(:tool_call, %{run_id: run_id, tool_call_id: id}, opts) do
    gateway = Keyword.get(opts, :gateway, ForemanServer.CommandGateway)

    case Keyword.get_lazy(opts, :on_timeout, &Config.on_timeout/0) do
      :deny ->
        run(
          %{
            type: "tool.deny",
            command_id: "timeout-deny:#{run_id}:#{id}",
            aggregate_id: ToolCall.stream_id(run_id, id),
            payload: %{run_id: run_id, tool_call_id: id, decided_by: "system", reason: "timeout"}
          },
          :denied,
          gateway
        )

      :surface ->
        expire_tool_call(run_id, id, "timeout", gateway: gateway)
    end
  end

  def apply(:question, %{run_id: run_id, question_id: id}, opts) do
    run(
      %{
        type: "question.expire",
        command_id: "expire:question:#{run_id}:#{id}",
        aggregate_id: OperatorQuestion.stream_id(run_id, id),
        payload: %{run_id: run_id, question_id: id, reason: "timeout"}
      },
      :expired,
      Keyword.get(opts, :gateway, ForemanServer.CommandGateway)
    )
  end

  @doc """
  Expire a still-open tool call whose request can no longer be answered (`tool.expire`),
  recording why: `"timeout"` for the `:surface` policy; `"run_ended"`, `"client_gone"` or
  `"server_restart"` when its agent is gone (`ForemanServer.Approvals.Inflight`). The command id is
  the call's alone, so whichever expiry reaches the aggregate first records its reason, once.
  `opts`: `:gateway`.
  """
  @spec expire_tool_call(String.t(), String.t(), String.t(), keyword()) :: outcome()
  def expire_tool_call(run_id, id, reason, opts \\ []) do
    run(
      %{
        type: "tool.expire",
        command_id: "expire:tool_call:#{run_id}:#{id}",
        aggregate_id: ToolCall.stream_id(run_id, id),
        payload: %{run_id: run_id, tool_call_id: id, reason: reason}
      },
      :expired,
      Keyword.get(opts, :gateway, ForemanServer.CommandGateway)
    )
  end

  defp run(command, success, gateway) do
    case Dispatch.system(command, gateway) do
      {:ok, _} -> {:ok, success}
      {:error, reason} -> classify(reason)
      {:error, reason, _detail} -> classify(reason)
    end
  end

  # Someone decided (or the request expired) first: that is not a failure.
  defp classify({:tool_call_terminal, _status}), do: {:ok, :already_decided}
  defp classify({:tool_call_expired, _reason}), do: {:ok, :already_decided}
  defp classify({:invalid_tool_call_status, _status}), do: {:ok, :already_decided}
  defp classify({:question_not_open, _status}), do: {:ok, :already_decided}
  defp classify(reason), do: {:error, reason}
end
