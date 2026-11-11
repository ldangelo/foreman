defmodule ForemanServer.Idempotency.Reconcilers.TaskProvider do
  @moduledoc """
  The `task_provider` effect class (TRD-015): how a task-provider state change
  (`claim`, `complete`, `fail`, `reopen`) is keyed, what its intent records, and
  how an interrupted one is reconciled. The task provider is the source of truth
  for the issue's status.

  ## Key and intent

  The key is `effect:task_provider:<run_id>:<op>:<issue_id>` (`key/3`); `op` is
  one of `claim`, `complete`, `fail`, `reopen`. `intent/5` is the metadata of the
  `started` key `Effect.run/4` writes: `run_id`, `project_id`, `op`, `issue_id`
  (and, for a claim, the claiming `actor` when there is one). The provider module
  and its `project_config` are NOT stored: `reconcile/2` resolves both from
  `project_id` through `ForemanServer.TaskProvider.Registry.project_config/1`.

  ## Reconciliation

  `reconcile/2` reads the issue with `provider.get/2` and compares its status with
  the two a call moves between:

  | op         | `:not_done` (starting status) | `:done` (resulting status)         |
  | ---------- | ----------------------------- | ---------------------------------- |
  | `claim`    | `open`                        | `in_progress`, for the claimant    |
  | `complete` | `in_progress`                 | `closed`                           |
  | `fail`     | `in_progress`                 | `blocked`                          |
  | `reopen`   | `in_progress`                 | `open`                             |

  Everything else is `:unknown` (fail closed): any other status, a claim that is
  `in_progress` for a different assignee than the key's `actor`, a registry that
  cannot resolve the project, a `get/2` that errors, raises, exits or does not
  answer within `opts[:timeout_ms]` (default `Reconcilers.Command.default_timeout_ms/0`,
  because the boot sweep waits on it), and incomplete metadata.
  """

  @behaviour ForemanServer.Idempotency.Reconciler

  alias ForemanServer.Idempotency.Effect
  alias ForemanServer.Idempotency.Reconciler
  alias ForemanServer.Idempotency.Reconcilers.Command
  alias ForemanServer.TaskProvider.Registry

  require Logger

  @ops ~w(claim complete fail reopen)

  # op => {status before the call, status after it}
  @transitions %{
    "claim" => {"open", "in_progress"},
    "complete" => {"in_progress", "closed"},
    "fail" => {"in_progress", "blocked"},
    "reopen" => {"in_progress", "open"}
  }

  @doc "The effect key of `op` (`:claim`, `:complete`, `:fail` or `:reopen`) on `issue_id` for `run_id`."
  @spec key(String.t(), atom() | String.t(), String.t()) :: String.t()
  def key(run_id, op, issue_id),
    do: Effect.key(:task_provider, run_id, "#{op}:#{issue_id}")

  @doc """
  The metadata of a task-provider call's intent key. Pass it to
  `Effect.run(:task_provider, key(run_id, op, issue_id), fun, meta)`. `extra`
  adds optional fields (the claiming `actor`).
  """
  @spec intent(String.t(), String.t(), atom() | String.t(), String.t(), map()) :: map()
  def intent(run_id, project_id, op, issue_id, extra \\ %{}) do
    Map.merge(
      %{run_id: run_id, project_id: project_id, op: to_string(op), issue_id: issue_id},
      Map.reject(extra, fn {_k, v} -> is_nil(v) end)
    )
  end

  @doc """
  Run `fun` (the provider call) as the keyed effect `op` on `issue_id`. Returns
  `fun`'s result, or `{:error, reason}` when `Effect.run/4` refused to run it
  (see `Effect.run/4`); never `:ok`/`{:ok, _}` for a refusal.
  """
  @spec run(String.t(), String.t(), atom() | String.t(), String.t(), (-> term()), map()) ::
          term()
  def run(run_id, project_id, op, issue_id, fun, extra \\ %{}) when is_function(fun, 0) do
    Effect.run(
      :task_provider,
      key(run_id, op, issue_id),
      fun,
      intent(run_id, project_id, op, issue_id, extra)
    )
  end

  @impl Reconciler
  def reconcile(metadata), do: reconcile(metadata, [])

  @doc """
  `reconcile/1` with `opts[:timeout_ms]` replacing the bound on the provider read.
  """
  @spec reconcile(map(), keyword()) :: Reconciler.verdict()
  def reconcile(metadata, opts) when is_map(metadata) and is_list(opts) do
    with {:ok, fields} <- fields(metadata),
         {:ok, provider, config} <- resolve(fields.project_id),
         {:ok, issue} <- read_issue(provider, config, fields.issue_id, opts) do
      decide(fields, issue, metadata)
    else
      {:error, reason} -> unknown(metadata, reason)
    end
  end

  defp decide(%{op: op, actor: actor}, issue, metadata) do
    {from, to} = Map.fetch!(@transitions, op)

    case issue_field(issue, :status) do
      ^to -> claimant_check(op, actor, issue_field(issue, :assignee), metadata)
      ^from -> :not_done
      other -> unknown(metadata, {:unexpected_status, other})
    end
  end

  # A claim is `:done` only for its own actor; a provider that reports no assignee
  # (or a key without an actor) cannot contradict it.
  defp claimant_check("claim", actor, assignee, metadata)
       when is_binary(actor) and is_binary(assignee) and assignee != "" and assignee != actor,
       do: unknown(metadata, {:claimed_by_other, assignee})

  defp claimant_check(_op, _actor, _assignee, _metadata), do: :done

  defp issue_field(%{} = issue, field), do: Map.get(issue, field)
  defp issue_field(_issue, _field), do: nil

  defp fields(metadata) do
    with {:ok, project_id} <- text(metadata, "project_id"),
         {:ok, issue_id} <- text(metadata, "issue_id"),
         {:ok, op} <- text(metadata, "op"),
         :ok <- known_op(op) do
      {:ok,
       %{
         project_id: project_id,
         issue_id: issue_id,
         op: op,
         actor: optional_text(metadata, "actor")
       }}
    end
  end

  defp known_op(op) when op in @ops, do: :ok
  defp known_op(op), do: {:error, {:unknown_op, op}}

  defp text(metadata, field) do
    case Map.get(metadata, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:incomplete_metadata, field}}
    end
  end

  defp optional_text(metadata, field) do
    case Map.get(metadata, field) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp resolve(project_id) do
    case Registry.project_config(project_id) do
      {:ok, %{provider_module: provider, config: config}}
      when is_atom(provider) and is_map(config) ->
        {:ok, provider, config}

      {:ok, other} ->
        {:error, {:unexpected_registry_answer, other}}

      {:error, reason} ->
        {:error, {:project_unresolved, reason}}
    end
  catch
    kind, reason -> {:error, {:registry_failed, kind, reason}}
  end

  # The provider read runs in a task that is killed when the time is up: the boot
  # sweep waits on it, and a stalled provider must not stop every later boot scan.
  defp read_issue(provider, config, issue_id, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, Command.default_timeout_ms())

    task =
      Task.async(fn ->
        try do
          {:ok, provider.get(issue_id, config)}
        rescue
          error -> {:error, {:get_raised, Exception.message(error)}}
        catch
          kind, reason -> {:error, {:get_raised, kind, reason}}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {:ok, issue}}} -> {:ok, issue}
      {:ok, {:ok, {:error, reason}}} -> {:error, {:get_failed, reason}}
      {:ok, {:ok, other}} -> {:error, {:unexpected_get_answer, other}}
      {:ok, {:error, _} = error} -> error
      {:exit, reason} -> {:error, {:get_exited, reason}}
      nil -> {:error, {:timeout, timeout_ms}}
    end
  end

  defp unknown(metadata, reason) do
    Logger.warning(
      "TaskProvider reconciler: cannot tell whether #{inspect(metadata["op"])} of " <>
        "#{inspect(metadata["issue_id"])} happened: #{inspect(reason, limit: 8)}",
      run_id: metadata["run_id"]
    )

    :unknown
  end
end
