defmodule ForemanServer.Workflow.AutoPR do
  @moduledoc """
  Reads FOREMAN_BRANCH / FOREMAN_SHA / FOREMAN_COMPLETE from a skill
  output artifact and creates a GitHub PR via the `gh` CLI.

  Called from RunExecutor.finalize_run/1 after the task provider completes
  and before dispatching run.complete, so the PR is created while the
  run record is still open.

  The handoff variables are printed as plain text lines by the skill's
  final phase output step:

      FOREMAN_BRANCH=<current-branch>
      FOREMAN_SHA=<git-revision>
      FOREMAN_COMPLETE=true

  The PR title defaults to "feat(run): <run_id>" and the body references
  the run and artifact path.
  """

  require Logger

  # ~w sigil produces ["pr", "create", "--no-editor"] — tl() drops "pr",
  # leaving ["create", "--no-editor"] for System.cmd("gh", ["create", ...])
  @gh_args ~w[pr create --no-editor]
  @branch_regex ~r/FOREMAN_BRANCH=(\S+)/
  @sha_regex ~r/FOREMAN_SHA=(\S+)/
  @complete_regex ~r/FOREMAN_COMPLETE=true/

  @type handoff :: %{branch: String.t(), sha: String.t()}

  @doc """
  Returns `:noop` if `artifact_path` is nil or missing the FOREMAN_COMPLETE
  marker. Returns `{:ok, pr_url}` on success or `{:error, term}` on failure.

  `cwd` is passed as the working directory for the `gh` invocation so it
  resolves the correct remote and branch context. Defaults to nil (inherits
  the beam daemon's working directory).
  """
  @spec maybe_create_pr(String.t(), String.t() | nil, String.t(), String.t() | nil) ::
          :noop | {:ok, String.t()} | {:error, term()}
  def maybe_create_pr(run_id, artifact_path, base_branch, cwd \\ nil)

  def maybe_create_pr(run_id, nil, _base_branch, _cwd) do
    Logger.info("AutoPR.run_id=#{run_id} skipped: no artifact_path")
    :noop
  end

  def maybe_create_pr(run_id, artifact_path, base_branch, cwd) do
    with {:ok, content} <- read_artifact(artifact_path),
         {:ok, handoff} <- parse_handoff(content),
         :ok <- validate_handoff(handoff) do
      do_create_pr(run_id, handoff, base_branch, artifact_path, cwd)
    else
      {:error, :no_handoff} ->
        Logger.info("AutoPR.run_id=#{run_id} skipped: no FOREMAN_COMPLETE marker")
        :noop

      {:error, reason} ->
        Logger.warning("AutoPR.run_id=#{run_id} parse error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # -------------------------------------------------------------------
  # Internal

  defp read_artifact(path) do
    case File.read(path) do
      {:ok, _} = ok -> ok
      {:error, reason} = error ->
        Logger.info("AutoPR could not read artifact #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc "Extract handoff fields from skill output text."
  @spec parse_handoff(String.t()) :: {:ok, handoff()} | {:error, :no_handoff}
  def parse_handoff(content) when is_binary(content) do
    branch = Regex.run(@branch_regex, content, capture: :all_but_first) |> List.first()
    sha = Regex.run(@sha_regex, content, capture: :all_but_first) |> List.first()
    complete? = Regex.match?(@complete_regex, content)

    if complete? do
      {:ok, %{branch: branch || "", sha: sha || ""}}
    else
      {:error, :no_handoff}
    end
  end

  defp validate_handoff(%{branch: branch}) when branch != "", do: :ok
  defp validate_handoff(handoff), do: {:error, {:invalid_handoff, handoff}}

  defp do_create_pr(run_id, handoff, base_branch, artifact_path, cwd) do
    title = "feat(run): #{run_id}"
    body = "Foreman run `#{run_id}` complete.\n\nArtifact: #{artifact_path}\n"

    cmd =
      @gh_args ++
        ["--base", base_branch, "--head", handoff.branch, "--title", title, "--body", body]

    opts = [stderr_to_stdout: true]
    opts = if cwd, do: Keyword.put(opts, :cd, cwd), else: opts

    Logger.info(
      "AutoPR.run_id=#{run_id} gh pr create --base=#{base_branch} --head=#{handoff.branch}" <>
        if(cwd, do: " (cwd=#{cwd})", else: "")
    )

    case System.cmd("gh", cmd, opts) do
      {output, 0} ->
        pr_url = pr_url_from_output(output) || output
        Logger.info("AutoPR.run_id=#{run_id} PR created: #{pr_url}")
        {:ok, pr_url}

      {output, exit} ->
        Logger.error("AutoPR.run_id=#{run_id} gh pr create failed (#{exit}): #{output}")
        {:error, {:gh_pr_create_failed, exit, output}}
    end
  end

  # gh prints the PR URL on stdout on success
  defp pr_url_from_output(output) do
    case Regex.run(~r"https://github\.com/[^\s]+", output) do
      [url | _] -> String.trim(url)
      nil -> nil
    end
  end
end
