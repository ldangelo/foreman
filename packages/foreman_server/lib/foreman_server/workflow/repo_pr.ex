defmodule ForemanServer.Workflow.RepoPr do
  @moduledoc """
  One repository's PR for a run (E12 S3 §7).

    * `open/2` builds the context from projections (`RepoPrContext`) and opens
      the PR with `AutoPR`. A repository whose branch has no commits beyond its
      base is untouched: `:noop`, no PR, no association. A repository that
      already has an association returns its recorded URL (idempotent).
    * `finalize/2` is `open/2` plus the association (`PrAssociate`) and the
      `run.pr.ready` signal, for any repository, the primary included. A
      failure to record or signal never turns an opened PR into an error.
    * `cross_link/2` appends the sibling PR links to every PR body of a
      multi-repository run, best effort.

  Results are `:noop | {:ok, pr_url} | {:error, reason}`; callers collect them
  as `[{repo_id, result}]` and never short-circuit on an error.
  """

  require Logger

  alias ForemanServer.CommandGateway
  alias ForemanServer.Identity
  alias ForemanServer.PrAssociate
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Workflow.AutoPR
  alias ForemanServer.Workflow.RepoPrContext
  alias ForemanServer.Workflow.Worktree
  alias ForemanServer.Workflow.WorktreeSpec

  @type result :: :noop | {:ok, String.t()} | {:error, term()}

  @doc "Opens `repo_id`'s PR for `run_id`, or returns its existing one."
  @spec open(String.t(), String.t()) :: result()
  def open(run_id, repo_id) when is_binary(run_id) and is_binary(repo_id) do
    case existing_association(run_id, repo_id) do
      %{pr_url: url} when is_binary(url) ->
        {:ok, url}

      nil ->
        case RepoPrContext.build(run_id, repo_id) do
          {:ok, ctx} -> AutoPR.maybe_create_pr(ctx.auto_pr)
          {:error, _} = error -> error
        end
    end
  end

  @doc """
  Opens, associates and signals `repo_id`'s PR. An association already on
  record is not repeated; `run.pr.ready` carries a deterministic command id, so
  repeating it is a no-op.
  """
  @spec finalize(String.t(), String.t()) :: result()
  def finalize(run_id, repo_id) when is_binary(run_id) and is_binary(repo_id) do
    already? = existing_association(run_id, repo_id) != nil

    with {:ok, url} <- open(run_id, repo_id),
         {:ok, ctx} <- RepoPrContext.build(run_id, repo_id) do
      unless already?, do: associate(ctx, url)
      signal_ready(ctx, url)
      {:ok, url}
    else
      :noop ->
        :noop

      {:error, reason} = error ->
        Logger.error("RepoPr #{run_id} repository #{repo_id}: PR FAILED: #{inspect(reason)}")

        error
    end
  end

  @doc """
  Records that `repo_id`'s PR could not be created (`RunRepoPrFailed`) so the
  repository reads `create_failed` and can be retried. `repo_id` is the
  repository's real id, the primary's included. A failed append is logged, never
  raised: the run keeps completing.
  """
  @spec record_failure(String.t(), String.t(), term(), integer()) :: :ok
  def record_failure(run_id, repo_id, reason, at \\ System.system_time(:millisecond))
      when is_binary(run_id) and is_binary(repo_id) do
    result =
      CommandGateway.dispatch_system(%{
        type: "run.repo_pr_failed",
        command_id: Identity.run_repo_pr_failed_command_id(run_id, repo_id, at),
        aggregate_id: "run:#{run_id}",
        payload: %{run_id: run_id, repo_id: repo_id, reason: inspect(reason), at: at}
      })

    case result do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.error(
          "RepoPr #{run_id} repository #{repo_id}: PR failure NOT recorded: #{inspect(error)}"
        )
    end
  end

  @doc """
  The operator's `run.pr.retry`: runs `finalize/2` again from the repository's
  preserved worktree. Success reclaims that worktree when its manifest policy
  would have (`cleanup: always | on_success`), which finalisation deferred while
  the PR was missing. Idempotent: with the PR already open it returns it again
  and a worktree already gone is left alone. A failed attempt re-records
  `RunRepoPrFailed` with the new reason.
  """
  @spec retry(String.t(), String.t()) :: result()
  def retry(run_id, repo_id) when is_binary(run_id) and is_binary(repo_id) do
    case finalize(run_id, repo_id) do
      {:ok, _url} = opened ->
        reclaim_worktree(run_id, repo_id)
        opened

      {:error, reason} = error ->
        unless context_error?(reason), do: record_failure(run_id, repo_id, reason)
        error

      :noop ->
        :noop
    end
  end

  # Errors of `RepoPrContext.build/2`: the repository or its worktree is not
  # known, which is not a PR-creation failure of that repository.
  defp context_error?(:run_not_found), do: true
  defp context_error?({tag, _repo_id}) when tag in [:unknown_repo, :no_worktree], do: true
  defp context_error?({:base_branch_unrecorded, _repo_id}), do: true
  defp context_error?(_reason), do: false

  # The reclaim policy is the workflow's `worktree.cleanup` from the run's frozen
  # snapshot (the worktree projection does not carry it); absent means `never`,
  # as at finalisation.
  defp reclaim_worktree(run_id, repo_id) do
    entry = Enum.find(ProjectionStore.run_repositories(run_id), &(&1.repo_id == repo_id))

    with %{worktree: %{status: "created"} = worktree} <- entry,
         true <- cleanup_policy(run_id) in ["always", "on_success"] do
      Worktree.clean(%{
        operation_id: worktree.operation_id,
        project_id: worktree.project_id,
        run_id: run_id,
        phase_id: Identity.phase_id(run_id, 1),
        repo_path: worktree.repo_path
      })
    end

    :ok
  end

  defp cleanup_policy(run_id) do
    with %{workflow_snapshot: %{} = snapshot} <- ProjectionStore.run(run_id),
         %{} = declared <- Map.get(snapshot, :worktree) || Map.get(snapshot, "worktree"),
         %{cleanup: cleanup} <- WorktreeSpec.normalize(declared) do
      to_string(cleanup)
    else
      _ -> "never"
    end
  end

  @doc """
  Appends "Part of multi-repo run <run_id>" and the sibling PR links to each
  opened PR's body. Skipped unless two or more repositories opened a PR; a
  failing `gh` is logged and never fatal.
  """
  @spec cross_link(String.t(), [{String.t(), result()}]) :: :ok
  def cross_link(run_id, results) when is_binary(run_id) and is_list(results) do
    prs = for {repo_id, {:ok, url}} <- results, do: {repo_id, url}

    if length(prs) >= 2 do
      Enum.each(prs, fn {repo_id, url} ->
        siblings = for {id, sibling} <- prs, id != repo_id, do: sibling
        link_one(run_id, repo_id, url, siblings)
      end)
    end

    :ok
  end

  defp link_one(run_id, repo_id, url, siblings) do
    marker = "Part of multi-repo run #{run_id}"
    cwd = link_cwd(run_id, repo_id)

    with {:ok, body} <- gh(["pr", "view", url, "--json", "body", "--jq", ".body"], cwd),
         false <- String.contains?(body, marker),
         {:ok, _} <- gh(["pr", "edit", url, "--body", linked_body(body, marker, siblings)], cwd) do
      :ok
    else
      true ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "RepoPr #{run_id} repository #{repo_id}: cross-linking #{url} failed: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp linked_body(body, marker, siblings) do
    links = Enum.map_join(siblings, "\n", &"- #{sibling_ref(&1)}")
    String.trim_trailing(body) <> "\n\n" <> marker <> "\n\nSibling PRs:\n" <> links <> "\n"
  end

  defp sibling_ref(url) do
    case Regex.run(~r{github\.com/([^/]+/[^/]+)/pull/(\d+)}, url) do
      [_, repo, number] -> "#{repo}##{number} (#{url})"
      _ -> url
    end
  end

  defp link_cwd(run_id, repo_id) do
    case RepoPrContext.build(run_id, repo_id) do
      {:ok, %{auto_pr: %{cwd: cwd}}} -> cwd
      _ -> nil
    end
  end

  defp gh(args, cwd) do
    opts = [stderr_to_stdout: true]
    opts = if cwd, do: Keyword.put(opts, :cd, cwd), else: opts

    case System.cmd("gh", args, opts) do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {output, code} -> {:error, {:gh_failed, code, String.trim(output)}}
    end
  rescue
    error in ErlangError -> {:error, {:gh_unavailable, error.original}}
  end

  defp existing_association(run_id, repo_id) do
    Enum.find(ProjectionStore.pr_associations_for_run(run_id), &(&1.repo_id == repo_id))
  end

  # Absent `repo_id` is the run's primary (E12), so only a non-primary
  # repository carries one on the association and the signal.
  defp event_repo_id(%RepoPrContext{primary?: true}), do: nil
  defp event_repo_id(%RepoPrContext{repo_id: repo_id}), do: repo_id

  defp associate(%RepoPrContext{run_id: run_id} = ctx, url) do
    case PrAssociate.store(run_id, url, event_repo_id(ctx)) do
      {:ok, ^run_id} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "RepoPr #{run_id} repository #{ctx.repo_id}: PR #{url} created but NOT recorded " <>
            "on the run read model: #{inspect(reason)}"
        )
    end
  end

  defp signal_ready(%RepoPrContext{run_id: run_id} = ctx, url) do
    %{base_branch: base_branch, head_branch: head_branch, cwd: cwd} = ctx.auto_pr
    repo_id = event_repo_id(ctx)

    payload =
      %{
        run_id: run_id,
        project_id: ctx.project_id,
        task_id: ctx.task_id,
        pr_url: url,
        branch_name: head_branch,
        head_sha: nil,
        base_branch: base_branch
      }
      |> then(&if(repo_id, do: Map.put(&1, :repo_id, repo_id), else: &1))

    with {:ok, head_sha} <- head_sha(cwd, head_branch),
         {:ok, _} <-
           CommandGateway.dispatch_system(%{
             type: "run.pr.ready",
             command_id: Identity.run_pr_ready_command_id(run_id, repo_id),
             aggregate_id: "run:#{run_id}",
             payload: %{payload | head_sha: head_sha}
           }) do
      :ok
    else
      {:error, reason} ->
        Logger.error(
          "RepoPr #{run_id} repository #{ctx.repo_id}: PR #{url} created but run.pr.ready " <>
            "was NOT signalled, so its merge gate never engages: #{inspect(reason)}"
        )
    end
  end

  defp head_sha(cwd, branch) do
    case System.cmd("git", ["-C", cwd, "rev-parse", "--verify", "#{branch}^{commit}"],
           stderr_to_stdout: true
         ) do
      {sha, 0} -> {:ok, sha |> String.trim() |> String.downcase()}
      {output, _} -> {:error, {:unresolvable_revision, String.trim(output)}}
    end
  end
end
