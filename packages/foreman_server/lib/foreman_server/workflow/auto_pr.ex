defmodule ForemanServer.Workflow.AutoPR do
  @moduledoc """
  Opens a GitHub PR for a finished run via the `gh` CLI.

  Called from `RunExecutor.finalize_run/1` after the task provider confirms
  completion and before dispatching `run.complete`, so the PR is created while
  the run record is still open.

  ## The head branch comes from run state, not from agent output

  This previously required the final phase artifact to contain three exact
  lines printed by the skill:

      FOREMAN_BRANCH=<current-branch>
      FOREMAN_SHA=<git-revision>
      FOREMAN_COMPLETE=true

  Nothing ever emitted them — the only references to `FOREMAN_COMPLETE` in the
  repository were inside this module — so `maybe_create_pr/1` always returned
  `:noop` at `info` level while the run reported success. A PR could not land
  from any workflow, and nothing surfaced that.

  Foreman already knows the branch: it creates it (`foreman/<run_id>/<phase>`)
  and records it on `WorktreeCreated`. `RunExecutor` now retains it as
  `state.last_worktree`, so the head branch is derived from run state and a PR
  no longer depends on an agent formatting output correctly.

  A `FOREMAN_BRANCH=` marker in the artifact is still honoured as an explicit
  override for skills that manage their own branch.

  ## Whether to open a PR is decided by commits, not a marker

  `maybe_create_pr/1` opens a PR when the head branch has at least one commit
  that the base branch does not. No commits means there is genuinely nothing to
  propose, which is the only legitimate `:noop`. Every other outcome —
  unresolvable branch, failed `git` probe, failed `gh pr create` — is returned
  as `{:error, reason}` so the caller can surface it instead of completing the
  run as if a PR had been created.

  ## The base branch is the branch the run was cut from

  `base_branch` is required and is never defaulted here. `RunExecutor` records
  it when the run's first phase starts, from the symbolic ref `HEAD` points at
  in the project checkout — the same checkout this module runs `git` and `gh`
  in — and returns `{:auto_pr_base_branch_unresolved, reason}` instead of
  calling `maybe_create_pr/1` when it cannot name that branch.

  It used to arrive as `plan_context["base_branch"]` with a `"main"` fallback,
  and nothing ever wrote that key, so every run targeted `main`.
  run-776527010ea5d3568b742adbd25ab872 was cut from `feat/mcp-run-details` and
  opened PR #420 against `main`: the diff carried an entire unrelated session of
  commits rather than the two documents the run produced.

  The `commits_ahead/3` gate is measured against that same base, so it counts
  only what the run added on top of its own starting point. Against the default
  branch it also counted every commit the run's base branch already carried,
  which is how a run that produced nothing could still look like it had work to
  propose.
  """

  require Logger

  # System.cmd/3 prepends the executable, so these are subcommand args only.
  @gh_args ~w[pr create]
  @branch_regex ~r/FOREMAN_BRANCH=(\S+)/

  @type context :: %{
          required(:run_id) => String.t(),
          required(:base_branch) => String.t(),
          optional(:artifact_path) => String.t() | nil,
          optional(:head_branch) => String.t() | nil,
          optional(:cwd) => String.t() | nil
        }

  @type result :: {:ok, String.t()} | :noop | {:error, term()}

  @doc """
  Opens a PR for the run described by `context`.

  Returns `{:ok, pr_url}`, `:noop` when the head branch has no commits beyond
  the base, or `{:error, reason}`. `base_branch` must be the branch the run's
  work was cut from; it is not defaulted.
  """
  @spec maybe_create_pr(context()) :: result()
  def maybe_create_pr(%{run_id: run_id, base_branch: base_branch} = context)
      when is_binary(run_id) and is_binary(base_branch) and base_branch != "" do
    cwd = Map.get(context, :cwd)

    with {:ok, head_branch} <- resolve_head_branch(context),
         {:ok, ahead} <- commits_ahead(base_branch, head_branch, cwd) do
      if ahead > 0 do
        with :ok <- push_head(run_id, head_branch, cwd) do
          open_pr(run_id, base_branch, head_branch, Map.get(context, :artifact_path), cwd)
        end
      else
        Logger.info(
          "AutoPR.run_id=#{run_id} noop: #{head_branch} has no commits beyond #{base_branch}"
        )

        :noop
      end
    end
  end

  def maybe_create_pr(context) do
    {:error, {:invalid_context, context}}
  end

  @doc """
  Extracts an explicit `FOREMAN_BRANCH=` override from skill output.

  Returns `nil` when the artifact declares no branch, in which case the caller
  falls back to the Foreman-derived branch.
  """
  @spec branch_override(String.t()) :: String.t() | nil
  def branch_override(content) when is_binary(content) do
    case Regex.run(@branch_regex, content, capture: :all_but_first) do
      [branch | _] -> String.trim(branch)
      nil -> nil
    end
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  # Artifact override wins; otherwise use the branch Foreman created.
  defp resolve_head_branch(context) do
    override =
      case read_artifact(Map.get(context, :artifact_path)) do
        {:ok, content} -> branch_override(content)
        :skip -> nil
      end

    case override || Map.get(context, :head_branch) do
      branch when is_binary(branch) and branch != "" ->
        {:ok, branch}

      _ ->
        {:error, :no_head_branch}
    end
  end

  defp read_artifact(nil), do: :skip

  defp read_artifact(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        # Absent artifacts are normal: the head branch comes from run state.
        Logger.debug("AutoPR could not read artifact #{path}: #{inspect(reason)}")
        :skip
    end
  end

  defp commits_ahead(base_branch, head_branch, cwd) do
    args = ["rev-list", "--count", base_branch <> ".." <> head_branch]
    opts = [stderr_to_stdout: true]
    opts = if cwd, do: Keyword.put(opts, :cd, cwd), else: opts

    case System.cmd("git", args, opts) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {count, _} -> {:ok, count}
          :error -> {:error, {:unparsable_rev_list, output}}
        end

      {output, exit_code} ->
        {:error, {:rev_list_failed, exit_code, String.trim(output)}}
    end
  end

  # GitHub cannot open a PR from a branch it has never seen: `gh pr create`
  # fails with "Head ref must be a branch" / "No commits between ...". Foreman
  # creates the run branch locally in a worktree, so it must be published
  # first.
  defp push_head(run_id, head_branch, cwd) do
    opts = [stderr_to_stdout: true]
    opts = if cwd, do: Keyword.put(opts, :cd, cwd), else: opts

    Logger.info("AutoPR.run_id=#{run_id} git push -u origin #{head_branch}")

    case System.cmd("git", ["push", "-u", "origin", head_branch], opts) do
      {_output, 0} ->
        :ok

      {output, exit_code} ->
        {:error, {:git_push_failed, exit_code, String.trim(output)}}
    end
  end

  defp open_pr(run_id, base_branch, head_branch, artifact_path, cwd) do
    title = "feat(run): #{run_id}"

    body =
      "Foreman run `#{run_id}` complete.\n" <>
        if(artifact_path, do: "\nArtifact: #{artifact_path}\n", else: "")

    cmd =
      @gh_args ++
        ["--base", base_branch, "--head", head_branch, "--title", title, "--body", body]

    opts = [stderr_to_stdout: true]
    opts = if cwd, do: Keyword.put(opts, :cd, cwd), else: opts

    Logger.info(
      "AutoPR.run_id=#{run_id} gh pr create --base=#{base_branch} --head=#{head_branch}" <>
        if(cwd, do: " (cwd=#{cwd})", else: "")
    )

    case System.cmd("gh", cmd, opts) do
      {output, 0} ->
        pr_url = pr_url_from_output(output) || String.trim(output)
        Logger.info("AutoPR.run_id=#{run_id} PR created: #{pr_url}")
        {:ok, pr_url}

      {output, exit_code} ->
        Logger.error("AutoPR.run_id=#{run_id} gh pr create failed (#{exit_code}): #{output}")
        {:error, {:gh_pr_create_failed, exit_code, String.trim(output)}}
    end
  end

  defp pr_url_from_output(output) do
    case Regex.run(~r"https://github\.com/[^\s]+", output) do
      [url | _] -> String.trim(url)
      nil -> nil
    end
  end
end
