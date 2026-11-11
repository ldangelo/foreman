defmodule ForemanServer.Idempotency.Reconcilers.Command do
  @moduledoc """
  One external command (`git`, `gh`) of a reconciler, through its injectable
  3-arity runner (`System.cmd/3` by default), with an optional bounded wait.

  The boot sweep runs the reconcilers synchronously inside
  `BootReconciliation.handle_continue/2`, so a `git ls-remote` or `gh pr list`
  that never returns (a stalled network) would stop every later boot scan, and
  `Reconciler.verdict/3`'s rescue cannot see a hang. A reconciler therefore passes
  `:timeout_ms` (default `default_timeout_ms/0`): the runner call runs in a task
  that is killed when the time is up, and the call answers
  `{:error, {:timeout, timeout_ms}}`, which every reconciler maps to `:unknown`
  (fail closed, never `:done` or `:not_done`).

  The wait is on the Elixir side only: killing the task closes the port, but an
  OS process stuck in a connect is not signalled (the same known limit as
  `Sandboxes.ExecTimeout`); it no longer blocks recovery. Callers that run in an
  executor (`BranchPush.intent/4`) pass no timeout and the runner is called inline.

  Options: `:cd` (required), `:env` (`[{name, value}]`, passed to the runner),
  `:timeout_ms` (default `:infinity`).
  """

  @default_timeout_ms 30_000

  @type runner :: (String.t(), [String.t()], keyword() -> {String.t(), integer()})

  @doc "The bounded wait a reconciler applies to each of its commands."
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @doc """
  Run `executable args` through `runner` in `opts[:cd]`, with stderr merged into
  the output. `{:ok, {output, exit_code}}`, or `{:error, reason}` when the
  command could not be run (`{:command_not_run, executable, original}`, a runner
  that answers something else, a runner that raised) or ran out of time
  (`{:timeout, timeout_ms}`).
  """
  @spec run(runner(), String.t(), [String.t()], keyword()) ::
          {:ok, {String.t(), integer()}} | {:error, term()}
  def run(runner, executable, args, opts) do
    runner_opts =
      [cd: Keyword.fetch!(opts, :cd), stderr_to_stdout: true] ++ Keyword.take(opts, [:env])

    call = fn -> invoke(runner, executable, args, runner_opts) end

    case Keyword.get(opts, :timeout_ms, :infinity) do
      :infinity -> call.()
      timeout_ms when is_integer(timeout_ms) and timeout_ms >= 0 -> bounded(call, timeout_ms)
    end
  end

  defp invoke(runner, executable, args, opts) do
    case runner.(executable, args, opts) do
      {output, code} when is_binary(output) and is_integer(code) -> {:ok, {output, code}}
      other -> {:error, {:unexpected_runner_result, other}}
    end
  rescue
    error in ErlangError -> {:error, {:command_not_run, executable, error.original}}
  end

  # The task is linked to the caller, so it dies with it; it turns anything the
  # runner raises into a value, so it never takes the caller down with it.
  defp bounded(call, timeout_ms) do
    task = Task.async(fn -> contained(call) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:command_exited, reason}}
      nil -> {:error, {:timeout, timeout_ms}}
    end
  end

  defp contained(call) do
    call.()
  rescue
    error -> {:error, {:command_raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:command_raised, {kind, reason}}}
  end
end
