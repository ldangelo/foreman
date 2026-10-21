defmodule ForemanServer.TestSupport.PrSurfaceSupport do
  @moduledoc """
  Seeds one run with two watched PRs through the real command path for the E9
  read surfaces (HTTP and MCP): `failing_url` is the run's own PR (merge gate pending) with failing CI, two review
  comments and a requested CI fix; `merged_url` is merged.
  """

  alias ForemanServer.TestSupport.PrWatchSupport, as: Support

  @doc "A completed run with a failing-CI PR (fix requested) and a merged PR."
  @spec seed_two_prs!() :: %{
          run_id: String.t(),
          failing_url: String.t(),
          merged_url: String.t()
        }
  def seed_two_prs! do
    %{run_id: run_id, project_id: project_id, task_id: task_id, pr_url: failing_url} =
      Support.start_run!()

    merged_url = failing_url <> "-merged"

    # The run's own PR: `run.pr.ready` holds the merge gate (pending) for it.
    command!(run_id, "run.pr.ready", %{
      project_id: project_id,
      task_id: task_id,
      pr_url: failing_url,
      branch_name: "foreman/#{run_id}/work",
      head_sha: "sha-fail",
      base_branch: "main"
    })

    Support.complete_run!(run_id, project_id)

    command!(run_id, "run.pr.checks", %{
      pr_url: failing_url,
      head_sha: "sha-fail",
      digest: "d-fail",
      checks_state: "failing",
      failing: [%{name: "unit"}, %{name: "lint"}],
      pr_status: "open",
      base_branch: "main",
      branch_name: "foreman/#{run_id}/work",
      observation_seq: 1
    })

    command!(run_id, "run.pr.review", %{
      pr_url: failing_url,
      head_sha: "sha-fail",
      digest: "r-fail",
      review_decision: "changes_requested",
      comment_ids: ["c1", "c2"],
      pr_status: "open"
    })

    command!(run_id, "run.pr.fix_ci", %{pr_url: failing_url, trigger: "operator"})

    command!(run_id, "run.pr.checks", %{
      pr_url: merged_url,
      head_sha: "sha-merged",
      digest: "d-merged",
      checks_state: "passing",
      pr_status: "merged",
      observation_seq: 1
    })

    %{run_id: run_id, failing_url: failing_url, merged_url: merged_url}
  end

  defp command!(run_id, type, payload) do
    Support.dispatch!(%{
      type: type,
      command_id: "#{type}:#{run_id}:#{System.unique_integer([:positive])}",
      aggregate_id: "run:#{run_id}",
      payload: Map.put(payload, :run_id, run_id)
    })
  end
end
