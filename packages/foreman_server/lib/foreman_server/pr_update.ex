defmodule ForemanServer.PrUpdate do
  @moduledoc """
  Builds the `run.pr.update` command that both PR-state sources dispatch: the
  GitHub webhook (`ForemanServer.Webhooks.Github`) and the polling fallback
  (`ForemanServer.PrMonitor`).

  The `Run` aggregate requires `project_id`, `task_id`, `pr_url`, `branch_name`,
  `head_sha`, `base_branch` and `phase`. A run's own ids come from the run
  projection; the branch, sha and base come from the observation. Two sources
  building this payload separately is how both came to omit most of those fields
  and have every update rejected, so there is exactly one builder.

  The command id is derived from the run, the observed status and the head SHA.
  The same observation reaching the router twice — a webhook redelivery, a poll
  that sees nothing new, or the webhook and the poller reporting the same state —
  is deduplicated instead of appended again. A PR that returns to an earlier
  (status, sha) pair therefore appends nothing; `PrUpdated` has no downstream
  consumer that would notice.

  Multi-repo (E12): a PR is addressed as `{run_id, repo_id}`. The command id already
  contains `pr_url`, which is unique per repository, so two PRs of one run never
  dedupe against each other. The payload carries `repo_id` only for a non-primary
  repository (absent == the run's primary), so a single-repo run's command is
  byte-for-byte what it was.
  """

  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.ProjectionStore

  @type error ::
          {:run_not_found, String.t()}
          | {:run_projection_missing_ids, String.t()}

  @doc """
  The `run.pr.update` command for `pr` observed on `run_id`'s PR `pr_url`.
  `repo_id` is the effective id of the repository that opened the PR (`nil` or
  the run's primary id means the primary: no `repo_id` key in the payload).
  """
  @spec command(String.t(), String.t(), PrStatus.t(), String.t() | nil) ::
          {:ok, map()} | {:error, error()}
  def command(run_id, pr_url, %PrStatus{} = pr, repo_id \\ nil)
      when is_binary(run_id) and run_id != "" and is_binary(pr_url) and pr_url != "" do
    case ProjectionStore.run(run_id) do
      nil ->
        {:error, {:run_not_found, run_id}}

      %{project_id: project_id, task_id: task_id}
      when is_binary(project_id) and project_id != "" and is_binary(task_id) and task_id != "" ->
        {:ok,
         %{
           type: "run.pr.update",
           command_id:
             "pr_update:#{run_id}:#{pr_url}:#{pr.status}:#{pr.head_sha}:#{pr.base_branch}",
           aggregate_id: "run:#{run_id}",
           payload:
             %{
               run_id: run_id,
               project_id: project_id,
               task_id: task_id,
               pr_url: pr_url,
               pr_status: pr.status,
               branch_name: pr.head_branch,
               head_sha: pr.head_sha,
               base_branch: pr.base_branch,
               phase: phase(pr.status),
               observed_at: System.system_time(:millisecond)
             }
             |> put_non_primary_repo(run_id, repo_id)
         }}

      _malformed ->
        {:error, {:run_projection_missing_ids, run_id}}
    end
  end

  defp put_non_primary_repo(payload, run_id, repo_id) do
    case payload_repo_id(run_id, repo_id) do
      nil -> payload
      id -> Map.put(payload, :repo_id, id)
    end
  end

  @doc """
  The `repo_id` a PR event payload carries for the PR of `run_id` opened by the
  repository `repo_id` (effective id): `nil` for the run's primary (absent == primary),
  the id itself otherwise.
  """
  @spec payload_repo_id(String.t(), String.t() | nil) :: String.t() | nil
  def payload_repo_id(_run_id, nil), do: nil

  def payload_repo_id(run_id, repo_id) when is_binary(repo_id) do
    primary_id =
      Enum.find_value(ProjectionStore.run_repositories(run_id), &(&1.primary? && &1.repo_id))

    if repo_id == primary_id, do: nil, else: repo_id
  end

  defp phase(:merged), do: "merge_pending"
  defp phase(:open), do: "pr_open"
  defp phase(:closed), do: "pr_closed"
  defp phase(:conflicted), do: "pr_conflict"
end
