defmodule ForemanServer.Overview.Tabs.PullRequests do
  @moduledoc """
  Pull requests tab: one row per PR of the project, from the folded PR state
  (`ProjectionStore.pr_states_for_project/1` for each run's primary repository,
  `ProjectionStore.repo_pr_states_for_project/1` for the PRs a multi-repository run
  opened in its other repositories) joined with the run's thread for title, branch and
  review verdict. A single-repository run has one row. Rows are ordered newest PR
  activity first; rows with the same activity list a run's primary first, then its other
  repositories by repository id.

  A row of a non-primary repository's PR carries its `"repo_id"`; a row without one is
  the run's primary repository (the same convention as the PR events). Every row has its
  own `pr_url`, `pr_number`, `pr_state`, `merge_gate`, `head_sha` and `updated_at`.

  Rows are string-keyed and read-only; merging stays operator-only.
  """

  @behaviour ForemanServer.Overview.TabProvider

  alias ForemanServer.{ProjectionStore, Threads}
  alias ForemanServer.Threads.Thread

  @impl true
  def tab, do: :pull_requests

  @impl true
  def rows(project_id) do
    threads_by_run =
      for %Thread{run_ids: run_ids} = thread <-
            Threads.list(project_id, limit: Threads.max_limit()),
          run_id <- run_ids,
          into: %{},
          do: {run_id, thread}

    repo_states = ProjectionStore.repo_pr_states_for_project(project_id)

    project_id
    |> ProjectionStore.pr_states_for_project()
    |> Enum.flat_map(fn {run_id, primary} ->
      thread = Map.get(threads_by_run, run_id)

      [primary | Map.get(repo_states, run_id, [])]
      |> Enum.filter(&(&1.pr_url != nil or &1.pr_state != nil))
      |> Enum.map(&row(run_id, &1, thread))
    end)
    |> Enum.sort_by(&{&1["updated_at"] || 0, &1["run_id"]}, :desc)
  end

  defp row(run_id, pr, thread) do
    %{
      "run_id" => run_id,
      "thread_id" => thread && thread.id,
      "title" => thread && thread.title,
      "branch" => thread && thread.branch,
      "pr_url" => pr.pr_url,
      "pr_number" => pr.pr_number,
      "pr_state" => pr.pr_state && Atom.to_string(pr.pr_state),
      "merge_gate" => Atom.to_string(pr.merge_gate),
      "head_sha" => pr.head_sha,
      "review_verdict" => thread && thread.last_report && thread.last_report.verdict,
      "updated_at" => pr.pr_updated_at || (thread && thread.updated_at)
    }
    |> put_repo_id(Map.get(pr, :repo_id))
  end

  # Only a non-primary repository's view names its repo: no key means the run's primary.
  defp put_repo_id(row, nil), do: row
  defp put_repo_id(row, repo_id), do: Map.put(row, "repo_id", repo_id)
end
