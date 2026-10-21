defmodule ForemanServer.Workflow.TaskFanout do
  @moduledoc """
  `task.fanout` (E12 S11): goal fan-out, one thread per repository.

  Independent per-repo work ("bump the lint config in every repo") is N
  single-repo runs, not one multi-repo run: each run has its own worktree, its
  own PR and merges independently, and one failing does not affect the others.
  This system command creates ONE task per repository, each with that
  repository as the run's primary (`repo_id`), by looping `task.create` through
  `CommandGateway.dispatch_system/2` - so project pause/archive checks, repo
  validation and the daily thread cap apply per task.

  Payload: `%{project_id, title, prompt, workflow_name, repo_ids: [id] | "all",
  fanout_id?}`. Task ids are `<fanout_id>-<repo_id>` and command ids
  `fanout:<fanout_id>:<repo_id>`, so retrying the same fan-out (same
  `fanout_id`) creates no duplicates: an existing task is reported `exists`.
  `fanout_id` is minted when omitted and linked to every task as
  `source: "fanout:<fanout_id>"`.

  Rejections are reported per repository and never undo tasks already
  created. Tasks are created open: approving them is the caller's step
  (approval gating and run caps apply then). A task targeting a non-primary
  repository is refused by the run-start multi-repo gate until multi-repo runs
  are released.

  System-only: not in the operator allowlist and not an HTTP route; the MCP
  tool `foreman_task_fanout` (a write tool) is the one entry point.
  """

  alias ForemanServer.CommandGateway
  alias ForemanServer.ProjectionStore

  @type outcome :: %{
          repo_id: String.t(),
          task_id: String.t(),
          status: String.t(),
          reason: String.t() | nil
        }

  @type result ::
          {:ok, %{fanout_id: String.t(), project_id: String.t(), tasks: [outcome()]}}
          | {:error, term()}

  @doc "Runs one fan-out. `command` is `%{payload: payload}` (atom or string keys)."
  @spec execute(map()) :: result()
  def execute(%{payload: payload}) when is_map(payload) do
    with {:ok, project_id} <- require_binary(field(payload, :project_id), :project_id),
         {:ok, title} <- require_binary(field(payload, :title), :title),
         {:ok, prompt} <- require_binary(field(payload, :prompt), :prompt),
         {:ok, workflow} <- require_binary(field(payload, :workflow_name), :workflow_name),
         {:ok, fanout_id} <- fanout_id(field(payload, :fanout_id)),
         {:ok, repos} <- registered_repos(project_id),
         {:ok, repo_ids} <- target_repo_ids(field(payload, :repo_ids), repos) do
      spec = %{
        project_id: project_id,
        title: title,
        prompt: prompt,
        workflow: workflow,
        fanout_id: fanout_id
      }

      {:ok,
       %{
         fanout_id: fanout_id,
         project_id: project_id,
         tasks: Enum.map(repo_ids, &create_one(spec, &1))
       }}
    end
  end

  def execute(_command), do: {:error, {:invalid_envelope, :task_fanout}}

  defp create_one(spec, repo_id) do
    task_id = spec.fanout_id <> "-" <> repo_id

    outcome =
      with :ok <- check_daily_cap(spec.project_id) do
        CommandGateway.dispatch_system(%{
          type: "task.create",
          command_id: "fanout:#{spec.fanout_id}:#{repo_id}",
          aggregate_id: "task:" <> task_id,
          payload: %{
            task_id: task_id,
            project_id: spec.project_id,
            title: spec.title,
            description: spec.prompt,
            prompt: spec.prompt,
            task_type: "task",
            workflow_type: spec.workflow,
            status: "open",
            source: "fanout:" <> spec.fanout_id,
            provider_tracked: false,
            repo_id: repo_id
          }
        })
      end

    report(repo_id, task_id, outcome)
  end

  defp report(repo_id, task_id, {:ok, _}), do: outcome(repo_id, task_id, "created", nil)

  defp report(repo_id, task_id, {:error, {:already_exists, :task, _id}}),
    do: outcome(repo_id, task_id, "exists", nil)

  defp report(repo_id, task_id, {:error, reason}),
    do: outcome(repo_id, task_id, "rejected", inspect(reason))

  defp report(repo_id, task_id, {:error, reason, detail}),
    do: outcome(repo_id, task_id, "rejected", inspect({reason, detail}))

  defp outcome(repo_id, task_id, status, reason),
    do: %{repo_id: repo_id, task_id: task_id, status: status, reason: reason}

  defp check_daily_cap(project_id) do
    case ProjectionStore.project_limits(project_id) do
      %{cap_reached?: true, daily_thread_cap: cap} ->
        {:error, {:cap_exceeded, :daily_thread_cap, cap}}

      _ ->
        :ok
    end
  end

  defp registered_repos(project_id) do
    case ProjectionStore.project_repositories(project_id) do
      nil -> {:error, {:project_not_found, project_id}}
      repos -> {:ok, repos}
    end
  end

  defp target_repo_ids("all", repos), do: {:ok, Enum.map(repos, & &1.id)}

  defp target_repo_ids([_ | _] = ids, _repos) do
    cond do
      not Enum.all?(ids, &is_binary/1) ->
        {:error, {:invalid_repo_ids, ids}}

      (duplicates = ids -- Enum.uniq(ids)) != [] ->
        {:error, {:duplicate_repo_ids, Enum.uniq(duplicates)}}

      true ->
        {:ok, ids}
    end
  end

  defp target_repo_ids(other, _repos), do: {:error, {:invalid_repo_ids, other}}

  defp fanout_id(nil),
    do: {:ok, "fanout-" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)}

  defp fanout_id(id) when is_binary(id) do
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/, id),
      do: {:ok, id},
      else: {:error, {:invalid_fanout_id, id}}
  end

  defp fanout_id(other), do: {:error, {:invalid_fanout_id, other}}

  defp require_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp require_binary(value, key), do: {:error, {:missing_or_invalid, key, value}}

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
