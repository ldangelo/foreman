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

  ## Evidence (TRD-024)

  Every row has an `"evidence"` key: `evidence_view/1` of the PR's `PrWatch.DTO`, built from
  the PR's own watch record under the project's policy (read ONCE per `rows/1`), so each PR of a
  multi-repository run shows its own evidence and the status is the one the approval gate
  decides on. It is `nil` for a PR with no watch record yet. The view is display only: no
  field of it can approve or merge anything, and agent-written text in it is bounded and must
  be escaped by whoever renders it (`ForemanServerWeb.Workspace.Components` does, through
  HEEx).

  Rows are string-keyed and read-only; merging stays operator-only.
  """

  @behaviour ForemanServer.Overview.TabProvider

  alias ForemanServer.{PrEvidence, ProjectionStore, Threads}
  alias ForemanServer.PrWatch.DTO
  alias ForemanServer.Threads.Thread

  @max_reasons 20
  @settled ["merged", "closed"]
  @max_items 5
  @max_display 160

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
    policy = evidence_policy(project_id)
    now_ms = System.system_time(:millisecond)

    project_id
    |> ProjectionStore.pr_states_for_project()
    |> Enum.flat_map(fn {run_id, primary} ->
      thread = Map.get(threads_by_run, run_id)
      watch = ProjectionStore.pr_watch(run_id)
      context = %{policy: policy, now_ms: now_ms, run_status: thread && thread.status}

      [primary | Map.get(repo_states, run_id, [])]
      |> Enum.filter(&(&1.pr_url != nil or &1.pr_state != nil))
      |> Enum.map(&row(run_id, &1, thread, evidence(watch, &1, context)))
    end)
    |> Enum.sort_by(&{&1["updated_at"] || 0, &1["run_id"]}, :desc)
  end

  defp row(run_id, pr, thread, evidence) do
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
      "updated_at" => pr.pr_updated_at || (thread && thread.updated_at),
      "evidence" => evidence
    }
    |> put_repo_id(Map.get(pr, :repo_id))
  end

  # Only a non-primary repository's view names its repo: no key means the run's primary.
  defp put_repo_id(row, nil), do: row
  defp put_repo_id(row, repo_id), do: Map.put(row, "repo_id", repo_id)

  # The view of the watch record of this PR's URL. `nil` when the PR has no record (never
  # observed) and when it is already merged or closed: evidence is the input of an approval
  # decision and a settled PR has none left to take (decided by the record's status, explicitly).
  defp evidence(watch, %{pr_url: url} = pr, context) when is_binary(url) do
    case Enum.find(watch, &(&1.pr_url == url)) do
      nil -> nil
      %{status: status} when status in @settled -> nil
      record -> record |> DTO.from_projection(pr.merge_gate, context) |> evidence_view()
    end
  end

  defp evidence(_watch, _pr, _context), do: nil

  @doc """
  The evidence view of every watched PR of ONE run, for the thread pane: the same
  `evidence_view/1` the tab rows carry, built under the policy of `project_id` (the project the
  page is for, as `rows/1` and the Overview classification do) and each PR's own merge gate.
  `:unavailable` when the projection store does not answer: the status is unknown, never an
  empty list that reads as clean.
  """
  @spec run_evidence(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, [map()]} | :unavailable
  def run_evidence(run_id, project_id, run_status) when is_binary(run_id) do
    context = %{
      policy: evidence_policy(project_id),
      now_ms: System.system_time(:millisecond),
      run_status: run_status
    }

    gates =
      gates_by_url(ProjectionStore.pr_state(run_id), ProjectionStore.repo_pr_states(run_id))

    {:ok,
     for record <- ProjectionStore.pr_watch(run_id), record.status not in @settled do
       record |> DTO.from_projection(Map.get(gates, record.pr_url), context) |> evidence_view()
     end}
  catch
    :exit, _reason -> :unavailable
  end

  @doc """
  The merge gate of each PR of a run, keyed by PR URL: the run's primary PR view and the views of
  the PRs it opened in its other repositories (`ProjectionStore.pr_state/1` and
  `repo_pr_states/1` shapes). The gate is per PR (S6), so evidence is judged under its own.
  """
  @spec gates_by_url(map() | nil, [map()]) :: %{String.t() => atom()}
  def gates_by_url(primary, others) do
    for %{pr_url: url, merge_gate: gate} <- [primary | others], is_binary(url), into: %{} do
      {url, gate}
    end
  end

  @doc """
  The project's evidence policy in the shape `PrWatch.DTO.from_projection/3` takes: the policy
  of `PrEvidence.project_policy/1`, or `{:error, detail}` (shown as `unknown`, never as `off`)
  when it cannot be read. Read it once per project and pass it to every PR of that project.
  """
  @spec evidence_policy(String.t() | nil) :: {:ok, map() | nil} | {:error, String.t()}
  def evidence_policy(project_id) do
    case PrEvidence.project_policy(project_id) do
      {:ok, policy} ->
        {:ok, policy}

      {:error, {:policy_unavailable, reason}} ->
        {:error, inspect(reason, limit: 8, printable_limit: 200)}
    end
  end

  @doc """
  The display view of one `PrWatch.DTO`: string-keyed, JSON-safe, every agent-written text cut
  at #{@max_display} characters (the DTO already bounds it; this keeps a card readable) and
  every list capped. Nothing in it is trusted: render through an escaping template only.

  `"status"` is `off | eligible | ineligible | waived | unknown`; `"reasons"` are
  `%{"code", "subject", "detail"}`; `"next_actions"` are the action names of
  `PrEvidence.next_actions/2` (`fix_ci`, `rerun_review`, `waive`, `publish`, `reset`).
  """
  @spec evidence_view(DTO.t()) :: map()
  def evidence_view(%DTO{} = dto) do
    eligibility = dto.eligibility

    %{
      "pr_url" => dto.pr_url,
      "repo_id" => dto.repo_id,
      "head_sha" => dto.head_sha,
      "status" => eligibility.status,
      "policy_version" => eligibility.policy_version,
      "reasons" => eligibility.reasons |> Enum.take(@max_reasons) |> Enum.map(&reason_view/1),
      "waived" => eligibility.waived |> Enum.take(@max_reasons) |> Enum.map(&reason_view/1),
      "risk" => risk_view(dto.risk),
      "report" => report_view(dto.report),
      "waiver" => waiver_view(dto.waiver),
      "findings" => findings_view(dto.findings),
      "delivery_issue" => dto.delivery_issue && cut(dto.delivery_issue.reason),
      "next_actions" => Enum.map(dto.next_actions, & &1.action)
    }
  end

  defp reason_view(reason),
    do: %{
      "code" => reason.code,
      "subject" => cut(reason.subject),
      "detail" => cut(reason.detail)
    }

  defp risk_view(nil), do: nil

  defp risk_view(risk),
    do: %{
      "level" => risk.level,
      "current" => risk.current,
      "rationale" =>
        risk.rationale
        |> Enum.take(@max_items)
        |> Enum.map(&%{"rule" => &1.rule, "level" => &1.level, "detail" => cut(&1.detail)})
    }

  defp report_view(nil), do: nil

  defp report_view(report),
    do: %{
      "status" => report.status,
      "current" => report.current,
      "stale" => report.stale,
      "reason" => cut(report.reason)
    }

  defp waiver_view(nil), do: nil

  defp waiver_view(waiver),
    do: %{
      "codes" => waiver.codes,
      "applies" => waiver.applies,
      "ignored_because" => waiver.ignored_because,
      "waived_by" => cut(waiver.waived_by),
      "reason" => cut(waiver.reason)
    }

  defp findings_view(nil), do: nil

  defp findings_view(findings),
    do: %{
      "status" => findings.status,
      "current" => findings.current,
      "unresolved" => findings.unresolved,
      "total" => findings.total,
      "defect_detail" => cut(findings.defect_detail),
      "items" =>
        findings.items
        |> Enum.take(@max_items)
        |> Enum.map(
          &%{
            "severity" => &1.severity,
            "disposition" => &1.disposition,
            "description" => cut(&1.description),
            "path" => cut(&1.path)
          }
        )
    }

  defp cut(nil), do: nil

  defp cut(text) when is_binary(text) do
    if String.length(text) > @max_display,
      do: String.slice(text, 0, @max_display) <> "…",
      else: text
  end
end
