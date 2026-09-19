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

  defmodule TaskMetadataError do
    @moduledoc "Typed AutoPR task metadata validation error."
    @enforce_keys [:run_id, :field, :reason]
    @type t :: %__MODULE__{
            run_id: String.t(),
            field: :title | :description,
            reason: :missing | :blank | :invalid
          }
    defstruct [:run_id, :field, :reason]
  end

  @type context :: %{
          required(:run_id) => String.t(),
          required(:base_branch) => String.t(),
          optional(:artifact_path) => String.t() | nil,
          optional(:head_branch) => String.t() | nil,
          optional(:cwd) => String.t() | nil,
          # A nil value means the field was never set (the Task aggregate
          # defaults description to nil). Producers MUST omit the key rather
          # than store nil, so presence and nil never mean the same thing.
          optional(:task_title) => String.t(),
          optional(:task_description) => String.t(),
          optional(:command_runner) => (String.t(), [String.t()], keyword() ->
                                          {String.t(), integer()})
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
         {:ok, ahead} <- commits_ahead(context, base_branch, head_branch, cwd) do
      if ahead > 0 do
        with {:ok, pr_content} <- pr_content(context),
             :ok <- push_head(context, run_id, head_branch, cwd) do
          open_pr(context, run_id, base_branch, head_branch, pr_content, cwd)
        end
      else
        Logger.info(
          "AutoPR.run_id=#{run_id} noop: #{head_branch} has no commits beyond #{base_branch}",
          run_id: run_id,
          base_branch: base_branch,
          head_branch: head_branch,
          operation: "autopr.commits_ahead",
          outcome: "noop",
          reason: "no_commits_ahead"
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
        Logger.debug("AutoPR could not read artifact #{path}: #{inspect(reason)}",
          operation: "autopr.read_artifact",
          outcome: "skip",
          reason: reason
        )

        :skip
    end
  end

  defp commits_ahead(context, base_branch, head_branch, cwd) do
    args = ["rev-list", "--count", base_branch <> ".." <> head_branch]
    opts = [stderr_to_stdout: true]
    opts = if cwd, do: Keyword.put(opts, :cd, cwd), else: opts

    case run(context, "git", args, opts) do
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
  defp push_head(context, run_id, head_branch, cwd) do
    opts = [stderr_to_stdout: true]
    opts = if cwd, do: Keyword.put(opts, :cd, cwd), else: opts

    Logger.info("AutoPR.run_id=#{run_id} git push -u origin #{head_branch}",
      run_id: run_id,
      head_branch: head_branch,
      operation: "autopr.git_push",
      outcome: "start"
    )

    case run(context, "git", ["push", "-u", "origin", head_branch], opts) do
      {_output, 0} ->
        :ok

      {output, exit_code} ->
        Logger.error("AutoPR.run_id=#{run_id} git push failed (#{exit_code})",
          run_id: run_id,
          head_branch: head_branch,
          operation: "autopr.git_push",
          outcome: "error",
          exit_code: exit_code,
          reason: String.trim(output)
        )

        {:error, {:git_push_failed, exit_code, String.trim(output)}}
    end
  end

  defp open_pr(context, run_id, base_branch, head_branch, %{title: title, body: body}, cwd) do
    cmd =
      @gh_args ++
        ["--base", base_branch, "--head", head_branch, "--title", title, "--body", body]

    opts = [stderr_to_stdout: true]
    opts = if cwd, do: Keyword.put(opts, :cd, cwd), else: opts

    Logger.info(
      "AutoPR.run_id=#{run_id} gh pr create --base=#{base_branch} --head=#{head_branch}" <>
        if(cwd, do: " (cwd=#{cwd})", else: ""),
      run_id: run_id,
      base_branch: base_branch,
      head_branch: head_branch,
      operation: "autopr.gh_create",
      outcome: "start"
    )

    case run(context, "gh", cmd, opts) do
      {output, 0} ->
        pr_url = pr_url_from_output(output) || String.trim(output)

        Logger.info("AutoPR.run_id=#{run_id} PR created: #{pr_url}",
          run_id: run_id,
          base_branch: base_branch,
          head_branch: head_branch,
          pr_url: pr_url,
          operation: "autopr.gh_create",
          outcome: "success"
        )

        {:ok, pr_url}

      {output, exit_code} ->
        Logger.error("AutoPR.run_id=#{run_id} gh pr create failed (#{exit_code}): #{output}",
          run_id: run_id,
          base_branch: base_branch,
          head_branch: head_branch,
          operation: "autopr.gh_create",
          outcome: "error",
          exit_code: exit_code,
          reason: String.trim(output)
        )

        {:error, {:gh_pr_create_failed, exit_code, String.trim(output)}}
    end
  end

  @doc false
  def __pr_content_for_test__(context), do: pr_content(context)

  defp pr_content(context) do
    title = fetch_task_field(context, :task_title)
    description = fetch_task_field(context, :task_description)

    case {title, description} do
      {:absent, :absent} ->
        {:ok, legacy_pr_content(context)}

      _task_backed ->
        with {:ok, title} <- resolve_task_field(context, title, :task_title, :title),
             {:ok, body} <- resolve_task_field(context, description, :task_description, :description) do
          {:ok, %{title: title, body: body}}
        end
    end
  end

  # A task key the producer never set is `:absent` (fall back); a key explicitly
  # stored - even as nil - is present and must validate its type (AGENTS.md
  # §5.3). Map.take is NOT used: on the pinned toolchain (Elixir 1.20) it
  # injects `key: nil` for absent keys, silently turning "absent" into a typed
  # error.
  defp fetch_task_field(context, key) do
    case Map.fetch(context, key) do
      {:ok, value} -> {:present, value}
      :error -> :absent
    end
  end

  defp resolve_task_field(context, field_result, context_key, field) do
    case field_result do
      {:present, value} -> validate_task_value(context, value, field)
      :absent -> {:ok, absent_task_field(context, context_key)}
    end
  end

  defp absent_task_field(context, :task_title), do: legacy_pr_title(context)
  defp absent_task_field(context, :task_description), do: generated_body(context)

  defp legacy_pr_title(context), do: "feat(run): " <> Map.fetch!(context, :run_id)

  defp validate_task_value(context, value, field) do
    run_id = Map.fetch!(context, :run_id)

    cond do
      is_binary(value) and String.trim(value) != "" -> {:ok, value}
      is_binary(value) -> {:error, %TaskMetadataError{run_id: run_id, field: field, reason: :blank}}
      true -> {:error, %TaskMetadataError{run_id: run_id, field: field, reason: :invalid}}
    end
  end

  defp generated_body(context) do
    run_id = Map.fetch!(context, :run_id)
    artifact_path = Map.get(context, :artifact_path)

    "Foreman run `#{run_id}` complete.\n" <>
      if(artifact_path, do: "\nArtifact: #{artifact_path}\n", else: "") <>
      findings_section(artifact_path)
  end

  defp legacy_pr_content(context) do
    %{title: legacy_pr_title(context), body: generated_body(context)}
  end



  defp run(context, executable, args, opts) do
    runner = Map.get(context, :command_runner) || (&System.cmd/3)
    runner.(executable, args, opts)
  end

  defp pr_url_from_output(output) do
    case Regex.run(~r"https://github\.com/[^\s]+", output) do
      [url | _] -> String.trim(url)
      nil -> nil
    end
  end

  defp findings_section(artifact_path) do
    case ForemanServer.Workflow.ReviewFindings.extract(artifact_path) do
      {:ok, block} -> "\n## Unresolved review findings\n\n" <> block <> "\n"
      :none -> ""
      {:error, :unterminated_block} -> unterminated_findings_section(artifact_path)
    end
  end

  defp unterminated_findings_section(artifact_path) do
    Logger.warning(
      "AutoPR could not read unresolved review findings: unterminated block in #{artifact_path}"
    )

    ForemanServer.Workflow.ReviewFindings.unterminated_section(artifact_path)
  end
end
