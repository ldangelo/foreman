defmodule ForemanServer.Agents.LlmErrorHandler do
  @moduledoc """
  LLM timeout/error handling.

  Wraps an `req_llm` call with `with_timeout/2`, normalises the result
  into `{:ok, value} | {:error, reason}`, and translates any error kind
  into an **error directive** for the agent: either `{:retry, directive}`
  for retriable failures or `{:escalate, directive}` for non-retriable
  ones.

  TRD-2026-4212be7e / JAI-T002 / TRD-040.
  """
  require Logger

  @timeout_ms 30_000

  @retriable [:timeout, :rate_limited, :connection_error]

  @max_attempts 3

  @doc """
  Run `fun` under a timeout. Returns:

    * `{:ok, value}` — fun returned `{:ok, value}` or any plain value
      (treated as success).
    * `{:error, :timeout}` — fun exceeded `timeout_ms`.
    * `{:error, {:exit, reason}}` — fun exited abnormally.
    * `{:error, reason}` — fun returned `{:error, reason}`.
  """
  def with_timeout(fun, timeout_ms \\ @timeout_ms) do
    task = Task.async(fun)
    # Detach the link so the caller's process does not receive the
    # task's exit signal — `with_timeout/2` reports exit reasons via
    # its return value rather than via process exit propagation.
    # `Process.unlink/1` is idempotent and safe to call after the task
    # has exited.
    Process.unlink(task.pid)

    try do
      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, value} ->
          case value do
            {:ok, _} = ok ->
              ok

            {:error, _} = err ->
              err

            other ->
              {:ok, other}
          end

        {:exit, reason} ->
          {:error, {:exit, reason}}

        nil ->
          {:error, :timeout}
      end
    catch
      :exit, reason ->
        {:error, {:exit, reason}}
    end
  end

  @doc """
  Classify an LLM error kind into a directive. Returns `{:retry,
  directive}` for retriable errors (capped at `@max_attempts`) or
  `{:escalate, directive}` for everything else.
  """
  def classify_and_directive(error_kind, context \\ %{}) do
    if error_kind in @retriable do
      Logger.warning("LLM retriable error: #{inspect(error_kind)}")

      {:retry,
       %{
         kind: error_kind,
         attempt: Map.get(context, :attempt, 1),
         max_attempts: @max_attempts
       }}
    else
      Logger.error("LLM non-retriable error: #{inspect(error_kind)}")
      {:escalate, %{kind: error_kind, context: context}}
    end
  end
end
