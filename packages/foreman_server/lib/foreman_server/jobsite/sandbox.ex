defmodule ForemanServer.Jobsite.Sandbox do
  @moduledoc """
  User-facing handle for a provisioned sandbox: a worktree plus (for
  `:bind_mount` providers) a running container, or (for the host provider)
  nothing beyond the worktree itself.

  `owns_worktree?` implements the split-ownership rule: a sandbox obtained
  from `ForemanServer.Jobsite.create_sandbox/1` owns and closes its worktree
  on `close/1`; one obtained from `ForemanServer.Jobsite.Worktree.create_sandbox/2`
  does not — `close/1` tears down only the container, leaving worktree
  lifecycle to whoever created it.
  """

  alias ForemanServer.Jobsite.{Error, ExecResult, IterationResult, Result, Worktree}
  alias ForemanServer.Jobsite.{AgentRunner, Output, Prompt}

  @enforce_keys [:jobsite_id, :provider, :state, :worktree, :sandbox_repo_path]
  @type t :: %__MODULE__{
          jobsite_id: String.t(),
          provider: module(),
          state: term(),
          worktree: Worktree.t(),
          sandbox_repo_path: String.t(),
          container_id: String.t() | nil,
          config: map() | nil,
          owns_worktree?: boolean()
        }
  defstruct [
    :jobsite_id,
    :provider,
    :state,
    :worktree,
    :sandbox_repo_path,
    :container_id,
    :config,
    owns_worktree?: true
  ]

  @default_completion_signal "<promise>COMPLETE</promise>"
  @default_idle_timeout_seconds 600
  @default_completion_timeout_seconds 60

  @doc "A non-zero exit from the command is data in `ExecResult.exit_code`, not an `{:error, _}` — an error means the command could not be run at all."
  @spec exec(t(), String.t(), keyword()) :: {:ok, ExecResult.t()} | {:error, Error.t()}
  def exec(%__MODULE__{provider: provider, state: state}, command, opts \\ []) do
    provider.exec(state, command, opts)
  end

  @doc """
  Resolve the prompt, iterate the agent against this sandbox until it emits a
  completion signal or `max_iterations` is reached, and return the final
  result. Deliberately standalone from `ForemanServer.Jobsite.Executor`'s
  loop (step 19 unifies the Executor's own loop onto `Jobsite.Engine`, not
  this one) — this is the manual, non-event-sourced entry point used when a
  script provisions its own sandbox via `ForemanServer.Jobsite.create_sandbox/1`.
  """
  @spec run(t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(%__MODULE__{} = sandbox, opts) do
    agent = Keyword.fetch!(opts, :agent)
    max_iterations = Keyword.get(opts, :max_iterations, 1)
    signals = normalize_signals(Keyword.get(opts, :completion_signal, @default_completion_signal))
    idle_timeout_ms = Keyword.get(opts, :idle_timeout_seconds, @default_idle_timeout_seconds) * 1000

    completion_timeout_ms =
      Keyword.get(opts, :completion_timeout_seconds, @default_completion_timeout_seconds) * 1000

    resume_session = Keyword.get(opts, :resume_session)
    output_opts = Keyword.get(opts, :output)

    with {:ok, prompt_text} <- Prompt.resolve(opts, sandbox, %{}) do
      sandbox
      |> iterate(agent, prompt_text, 1, max_iterations, signals, idle_timeout_ms, completion_timeout_ms, resume_session, [])
      |> finalize(sandbox, agent, output_opts, idle_timeout_ms, completion_timeout_ms)
    end
  end

  defp iterate(sandbox, agent, prompt, index, max_iterations, signals, idle_ms, completion_ms, resume_session, acc) do
    runner_opts = [
      index: index,
      resume_session: resume_session,
      idle_timeout_ms: idle_ms,
      completion_timeout_ms: completion_ms,
      completion_signals: signals
    ]

    case AgentRunner.run(agent, prompt, sandbox, runner_opts) do
      {:ok, %IterationResult{} = result} ->
        acc = acc ++ [result]

        cond do
          result.signalled? ->
            {:ok, acc}

          index >= max_iterations ->
            {:ok, acc}

          true ->
            iterate(sandbox, agent, prompt, index + 1, max_iterations, signals, idle_ms, completion_ms, result.session_id, acc)
        end

      {:error, _} = err ->
        err
    end
  end

  defp finalize({:error, _} = err, _sandbox, _agent, _output_opts, _idle_ms, _completion_ms), do: err

  defp finalize({:ok, iterations}, sandbox, agent, output_opts, idle_ms, completion_ms) do
    last = List.last(iterations)

    with {:ok, output, iterations, last} <-
           extract_output(output_opts, sandbox, agent, iterations, last, idle_ms, completion_ms, 0) do
      {:ok,
       %Result{
         jobsite_id: sandbox.jobsite_id,
         iterations: iterations,
         branch: sandbox.worktree.branch,
         commits: [],
         status: last.status,
         text: last.text,
         output: output,
         session_id: last.session_id,
         worktree_path: sandbox.worktree.path
       }}
    end
  end

  defp extract_output(nil, _sandbox, _agent, iterations, last, _idle_ms, _completion_ms, _attempt),
    do: {:ok, nil, iterations, last}

  defp extract_output(%Output{} = spec, sandbox, agent, iterations, last, idle_ms, completion_ms, attempt) do
    case Output.extract(spec, last.text) do
      {:ok, value} ->
        {:ok, value, iterations, last}

      {:error, %Error{} = error} when attempt < spec.max_retries ->
        retry_prompt =
          "Your previous output failed: #{error.message}. Re-emit it inside <#{spec.tag}> tags."

        runner_opts = [
          index: last.index + 1,
          resume_session: last.session_id,
          idle_timeout_ms: idle_ms,
          completion_timeout_ms: completion_ms,
          completion_signals: []
        ]

        case AgentRunner.run(agent, retry_prompt, sandbox, runner_opts) do
          {:ok, %IterationResult{} = retried} ->
            extract_output(spec, sandbox, agent, iterations ++ [retried], retried, idle_ms, completion_ms, attempt + 1)

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  defp normalize_signals(nil), do: []
  defp normalize_signals(signal) when is_binary(signal), do: [signal]
  defp normalize_signals(signals) when is_list(signals), do: signals

  @doc """
  Tear the sandbox down. Only when `owns_worktree?` does this also close the
  worktree (merge/preserve per its branch strategy); otherwise only the
  container (or, for the host provider, nothing) is released.
  """
  @spec close(t()) :: {:ok, %{preserved_path: String.t() | nil, merged?: boolean()}} | {:error, Error.t()}
  def close(%__MODULE__{} = sandbox) do
    with :ok <- sandbox.provider.close(sandbox.state) do
      if sandbox.owns_worktree? do
        Worktree.close(sandbox.worktree)
      else
        {:ok, %{preserved_path: nil, merged?: false}}
      end
    end
  end
end
