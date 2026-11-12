defmodule ForemanServer.PrReadySignal do
  @moduledoc """
  The one implementation of the `run.pr.ready` signal (TRD-008).

  A PR enters the merge gate with the head GitHub names, never a local `git rev-parse`: after
  a force push or a rewritten branch the local tip is not the head GitHub shows, and the
  evidence is bound to the head GitHub names. `signal/2` reads the PR once
  (`GitHub.PrStatus.fetch/2`, one `gh pr view`) and dispatches `run.pr.ready` with that
  `head_sha` under the deterministic command id (`Identity.run_pr_ready_command_id/2`), so a
  repeat for one run and repository is a no-op rather than a second `PrReady`.

  Callers: `Workflow.RunExecutor.signal_pr_ready/2`, `PrCreate.signal_ready/6` and
  `Workflow.RepoPr.signal_ready/2`. Each keeps its own failure handling (a log, or
  `{:pr_ready_signal_failed, reason}`); none of them reads a local revision any more.

  Errors: `{:error, {:head_read_failed, reason}}` when GitHub cannot be read (no `PrReady` is
  appended) and `{:error, {:ready_dispatch_failed, reason}}` when the command is refused.

  A failed signal is a recorded condition (TRD-033): before returning either error `signal/2`
  dispatches the system command `run.pr.ready_failed` (`PrReadyFailed`, `stage` `head_read` |
  `ready_dispatch`, `reason`, `failed_at`), which `PrEvidence` folds into
  `evidence.delivery_issue` until a later `PrReady` clears it. `reason` is the head atom of the
  error, with the exit code for a `gh` failure (`gh_failed:1`), and never carries `gh` output.
  Recording is best effort: if it is refused too, that is logged and the original error is
  still the result.

  `set_command_runner/1` is the test seam (3-arity `(cmd, args, opts)` returning
  `{output, exit_code}`); `opts[:command_runner]` overrides it for one call.
  """

  alias ForemanServer.CommandGateway
  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.Identity

  require Logger

  @runner_key {__MODULE__, :command_runner}

  @type attrs :: %{
          required(:run_id) => String.t(),
          required(:project_id) => String.t(),
          required(:task_id) => String.t(),
          required(:pr_url) => String.t(),
          required(:branch_name) => String.t(),
          required(:base_branch) => String.t(),
          optional(:repo_id) => String.t() | nil
        }

  @type error ::
          {:head_read_failed, term()}
          | {:ready_dispatch_failed, term()}

  @doc "Route the `gh` read of this module through `fun`, a 3-arity `(cmd, args, opts)` runner."
  @spec set_command_runner((String.t(), [String.t()], keyword() -> {String.t(), integer()})) ::
          :ok
  def set_command_runner(fun) when is_function(fun, 3) do
    :persistent_term.put(@runner_key, fun)
  end

  @doc "Remove the runner installed by `set_command_runner/1`."
  @spec clear_command_runner() :: boolean()
  def clear_command_runner, do: :persistent_term.erase(@runner_key)

  @doc """
  Read the head of `attrs.pr_url` from GitHub and dispatch `run.pr.ready` with it.

  `attrs.repo_id` is `nil`/absent for a run's primary repository.
  """
  @spec signal(attrs(), keyword()) :: :ok | {:error, error()}
  def signal(%{run_id: run_id, pr_url: pr_url} = attrs, opts \\ [])
      when is_binary(run_id) and is_binary(pr_url) do
    repo_id = Map.get(attrs, :repo_id)

    result =
      case PrStatus.fetch(pr_url, runner_opts(opts)) do
        {:ok, %PrStatus{head_sha: head_sha}} when is_binary(head_sha) and head_sha != "" ->
          dispatch(attrs, repo_id, String.downcase(head_sha))

        {:ok, %PrStatus{head_sha: other}} ->
          {:error, {:head_read_failed, {:empty_head_sha, other}}}

        {:error, reason} ->
          {:error, {:head_read_failed, reason}}
      end

    with {:error, error} <- result do
      record_failure(attrs, repo_id, error)
      result
    end
  end

  defp record_failure(attrs, repo_id, error) do
    {stage, cause} =
      case error do
        {:head_read_failed, cause} -> {"head_read", cause}
        {:ready_dispatch_failed, cause} -> {"ready_dispatch", cause}
      end

    failed_at = System.system_time(:millisecond)

    payload =
      %{
        run_id: attrs.run_id,
        project_id: attrs.project_id,
        task_id: attrs.task_id,
        pr_url: attrs.pr_url,
        stage: stage,
        reason: reason_of(cause),
        failed_at: failed_at
      }
      |> then(&if(repo_id, do: Map.put(&1, :repo_id, repo_id), else: &1))

    case CommandGateway.dispatch_system(%{
           type: "run.pr.ready_failed",
           command_id: Identity.run_pr_ready_failed_command_id(attrs.run_id, repo_id, failed_at),
           aggregate_id: "run:#{attrs.run_id}",
           payload: payload
         }) do
      {:ok, _spec} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "PrReadySignal #{attrs.run_id}: ready failure of #{attrs.pr_url} (#{stage}) " <>
            "could not be recorded: #{inspect(reason)}"
        )

        :ok
    end
  end

  # The head atom of the error; a `gh` failure keeps its exit code. `gh` output is never part
  # of the reason (it stays in the log line of the caller).
  defp reason_of({:gh_failed, code, _output}) when is_integer(code), do: "gh_failed:#{code}"
  defp reason_of(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_of(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and
              is_atom(elem(reason, 0)),
       do: Atom.to_string(elem(reason, 0))

  defp reason_of(_other), do: "unknown"

  defp dispatch(attrs, repo_id, head_sha) do
    payload =
      %{
        run_id: attrs.run_id,
        project_id: attrs.project_id,
        task_id: attrs.task_id,
        pr_url: attrs.pr_url,
        branch_name: attrs.branch_name,
        head_sha: head_sha,
        base_branch: attrs.base_branch
      }
      |> then(&if(repo_id, do: Map.put(&1, :repo_id, repo_id), else: &1))

    case CommandGateway.dispatch_system(%{
           type: "run.pr.ready",
           command_id: Identity.run_pr_ready_command_id(attrs.run_id, repo_id),
           aggregate_id: "run:#{attrs.run_id}",
           payload: payload
         }) do
      {:ok, _spec} -> :ok
      {:error, reason} -> {:error, {:ready_dispatch_failed, reason}}
    end
  end

  defp runner_opts(opts) do
    case Keyword.fetch(opts, :command_runner) do
      {:ok, fun} ->
        [command_runner: fun]

      :error ->
        case :persistent_term.get(@runner_key, :unset) do
          :unset -> []
          fun -> [command_runner: fun]
        end
    end
  end
end
