defmodule ForemanServer.Overview.Tabs.PullRequests do
  @moduledoc """
  Pull requests tab: one row per run of the project that has a PR, from the
  folded PR state (`ProjectionStore.pr_states_for_project/1`) joined with the
  run's thread for title, branch and review verdict. Newest PR activity first.

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

    project_id
    |> ProjectionStore.pr_states_for_project()
    |> Enum.filter(fn {_run_id, pr} -> pr.pr_url != nil or pr.pr_state != nil end)
    |> Enum.map(fn {run_id, pr} -> row(run_id, pr, Map.get(threads_by_run, run_id)) end)
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
  end
end
