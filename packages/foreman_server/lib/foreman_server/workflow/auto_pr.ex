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

  A `FOREMAN_BRANCH=<branch>` line in the artifact is still honoured as an explicit
  override for a skill that manages its own branch, in exactly one form
  (`branch_override/1`): the whole line, starting at column 0 (trailing whitespace and a
  CR are ignored), outside any fenced code block, and naming a valid git branch. The
  artifact is the agent's whole report, so the same text anywhere else (in a sentence, an
  inline code span, a list item or a quote, on an indented line, in a quoted diff or in a
  fence) is a mention, not a declaration, and changes nothing. A declared name that is not a
  valid branch name, or two different declared names, is an error
  (`{:invalid_branch_override, name, reason}`, `{:ambiguous_branch_override, first,
  second}`), never a fallback to the run's own branch: the PR is not opened.

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

  ## The push and the PR create are keyed effects

  Both external calls run through `ForemanServer.Idempotency.Effect.run/4` (TRD-013),
  so a crash between the call and its outcome leaves an `ambiguous` key that boot
  reconciliation hands to the class's reconciler instead of repeating the call:
  `Reconcilers.BranchPush` keys the push by `(run_id, head_branch)` and records the
  remote head before the push and the local tip being pushed; `Reconcilers.PrCreate`
  keys the create by `(run_id, head_branch, base_branch)` and asks GitHub.

  Both keys carry `cwd`, the directory the reconcilers run `git` and `gh` in, so a
  context without a `cwd` cannot push or open a PR: the effect does not run and
  `maybe_create_pr/1` returns `{:error, {:intent_not_recorded, :cwd_missing}}`. The
  same shape comes back when the push's remote or local head cannot be read, or the
  key cannot be written. A push or create that runs keeps its own result and error
  shapes (`{:git_push_failed, ...}`, `{:gh_pr_create_failed, ...}`).

  A key nobody has decided (`started`, or `ambiguous` with no recorded decision) refuses
  the effect: `{:error, {:effect_undecided, key}}` comes back unchanged, the push or the
  PR create is not made and is not retried here, and the log says it did not run and names
  the key. An undecided PR-create key stops the push too (the preflight runs first). The
  boot sweep decides the key; this module only reports the refusal.

  ## An existing PR is adopted, never created again

  Before any effect, `maybe_create_pr/1` reads the local tip of the head branch (the push's own
  intent, `Reconcilers.BranchPush.intent/4`, read once and passed on to the push) and asks
  GitHub, through `ForemanServer.GitHub.PrLookup`, for the open PR of this repository for the
  head and the base. The PR whose head is that tip IS the run's PR: `{:ok, url}` comes back
  with no preflight, no push and no `gh pr create`, and a `pr_create` key of the run that is
  `started` or `ambiguous` is settled `completed` (GitHub has answered it, so the doctor does
  not list it and a later Create PR after the PR was closed is not refused for good). A fork's
  PR of the same branch name is never adopted. Every other answer (no PR, a PR with another
  head, a failed lookup, an unreadable tip) goes on into the sequence: creating the PR stays
  the loud authority, and a failed lookup is never a success.

  After a non-zero exit of `gh pr create` the lookup runs once more before the key settles
  `failed`. The PR with the tip is adopted (`{:ok, url}`, the key settles `completed`); a PR of
  this repository with another head is `{:error, {:pr_lookup_mismatch, url, expected,
  actual}}` and nothing is adopted (an operator closes or aligns it); none, or a failed
  lookup, keeps `{:error, {:gh_pr_create_failed, code, output}}`. That is what ends the wedge
  of a run that was blocked on a `done` verdict, reset and resumed: its PR is adopted before
  the key is touched, not refused again by GitHub as a duplicate.
  """

  alias ForemanServer.GitHub.PrLookup
  alias ForemanServer.Idempotency.Effect
  alias ForemanServer.Idempotency.Reconcilers.Command
  alias ForemanServer.Idempotency.Reconcilers.BranchPush
  alias ForemanServer.Idempotency.Reconcilers.PrCreate, as: PrCreateEffect
  alias ForemanServer.Workflow.PrBody
  alias ForemanServer.Workflow.PrBodyPath

  defmodule PrContent do
    @moduledoc """
    The title and body AutoPR proposes for a pull request.

    A struct, not a bare map, so the payload's shape is enforced where it is
    built (AGENTS.md §5.1).
    """

    @enforce_keys [:title, :body]
    @type t :: %__MODULE__{title: String.t(), body: String.t()}
    defstruct [:title, :body]
  end

  require Logger

  # System.cmd/3 prepends the executable, so these are subcommand args only.
  @gh_args ~w[pr create]
  # The one line an artifact declares its head branch with: this prefix, then the branch name.
  @branch_marker "FOREMAN_BRANCH="
  # The artifact is the agent's text: an error carries at most this much of a name taken from it.
  @max_reported_chars 120

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
          # The commit the run's work was cut from, when the run knows it. A run cut
          # from the fetched `origin/<branch>` tip leaves the local base branch behind
          # that commit: the commit range then starts there instead of at the branch
          # NAME, so the origin commits are not counted as the run's own work. Absent
          # means the range starts at the base branch name.
          optional(:base_ref) => String.t(),
          optional(:artifact_path) => String.t() | nil,
          # The repository root the artifact path is made relative to in the PR body.
          optional(:artifact_root) => String.t() | nil,
          optional(:head_branch) => String.t() | nil,
          # Optional for the commit probe only: the push and the PR create are keyed
          # effects that record `cwd` and refuse to run without it (TRD-013).
          optional(:cwd) => String.t() | nil,
          # A nil value means the field was never set (the Task aggregate
          # defaults description to nil). Producers MUST omit the key rather
          # than store nil, so presence and nil never mean the same thing.
          optional(:task_title) => String.t(),
          optional(:task_description) => String.t(),
          # The headings the project requires in its pull-request bodies. Present
          # only when the project sets them; absent means the body keeps the
          # task's own text.
          optional(:pr_body_headings) => [String.t()],
          optional(:command_runner) => (String.t(), [String.t()], keyword() ->
                                          {String.t(), integer()})
        }

  @type result :: {:ok, String.t()} | :noop | {:error, term()}

  # The rule a declared branch name breaks (`branch_override/1`).
  @type branch_name_defect ::
          :empty
          | :not_utf8
          | :space
          | :control_character
          | :leading_dash
          | :leading_plus
          | :reserved_name
          | :forbidden_character
          | :double_dot
          | :at_brace
          | :trailing_dot
          | :empty_component
          | :dot_component
          | :lock_component

  @type branch_override_error ::
          {:invalid_branch_override, String.t(), branch_name_defect()}
          | {:ambiguous_branch_override, String.t(), String.t()}

  @doc """
  Opens a PR for the run described by `context`.

  Returns `{:ok, pr_url}` (the PR it created, or the one GitHub already had for the run's head),
  `:noop` when the head branch has no commits beyond the base, or `{:error, reason}`
  (`{:pr_lookup_mismatch, url, expected, actual}` names a PR of this repository whose head is
  not the tip; `{:invalid_branch_override, name, reason}` and `{:ambiguous_branch_override,
  first, second}` refuse a head branch the artifact declares badly, before any `git` or `gh`
  call). `base_branch` must be the branch the run's work was cut from; it is not defaulted.
  """
  @spec maybe_create_pr(context()) :: result()
  def maybe_create_pr(%{run_id: run_id, base_branch: base_branch} = context)
      when is_binary(run_id) and is_binary(base_branch) and base_branch != "" do
    cwd = Map.get(context, :cwd)

    with {:ok, head_branch} <- resolve_head_branch(context),
         {:ok, ahead} <- commits_ahead(context, base_branch, head_branch, cwd) do
      if ahead > 0 do
        with {:ok, pr_content} <- pr_content(context, head_branch) do
          propose(context, run_id, base_branch, head_branch, pr_content, cwd)
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
  The head branch the artifact `content` declares with `FOREMAN_BRANCH=`.

  A declaration is one form only: a whole line that is `FOREMAN_BRANCH=` and the branch
  name, starting at column 0 (trailing whitespace and a CR are ignored), outside a fenced
  code block (`ReviewFindings.unfenced_lines/1`, the rule the findings marker lines
  follow). The artifact is the agent's whole report, so the same text anywhere else (in a
  sentence, an inline code span, a list item or a quote, on an indented line, in a quoted
  diff or in a fence) is a mention and declares nothing.

  Returns

    * `{:ok, branch}`: one name is declared (once, or the same name more than once);
    * `:none`: nothing is declared, so the caller falls back to the Foreman-derived branch;
    * `{:error, {:invalid_branch_override, name, reason}}`: the declared name is not a valid
      git branch name; `reason` is the rule it breaks (`t:branch_name_defect/0`);
    * `{:error, {:ambiguous_branch_override, first, second}}`: two different names are
      declared, and neither is picked.

  A declaration that cannot be honoured is never `:none`: falling back would open the PR
  from a branch the artifact did not name.
  """
  @spec branch_override(String.t()) ::
          {:ok, String.t()} | :none | {:error, branch_override_error()}
  def branch_override(content) when is_binary(content) do
    declared =
      content
      |> ForemanServer.Workflow.ReviewFindings.unfenced_lines()
      |> Enum.flat_map(fn {_index, line} ->
        case String.trim_trailing(line) do
          @branch_marker <> name -> [name]
          _ -> []
        end
      end)
      |> Enum.uniq()

    case declared do
      [] ->
        :none

      [name] ->
        valid_override(name)

      [first, second | _more] ->
        {:error, {:ambiguous_branch_override, excerpt(first), excerpt(second)}}
    end
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  @doc """
  The branch `maybe_create_pr/1` pushes and opens the PR from: the one the artifact declares
  (`branch_override/1`) when it declares one, otherwise `context.head_branch`.

  A declaration that cannot be honoured is an error, never a fallback to
  `context.head_branch` (`t:branch_override_error/0`). With no declaration and no
  `context.head_branch` the error is `:no_head_branch`. An artifact that is absent or cannot
  be read declares nothing.

  Public so a caller that must name the PR's head (the merge gate's `PrReady`) resolves it
  exactly as AutoPR does rather than re-deriving it.
  """
  @spec resolve_head_branch(map()) ::
          {:ok, String.t()} | {:error, :no_head_branch | branch_override_error()}
  def resolve_head_branch(context) do
    case declared_override(Map.get(context, :artifact_path)) do
      {:ok, _branch} = declared -> declared
      :none -> own_head_branch(Map.get(context, :head_branch))
      {:error, _reason} = refused -> refused
    end
  end

  defp declared_override(artifact_path) do
    case read_artifact(artifact_path) do
      {:ok, content} -> branch_override(content)
      :skip -> :none
    end
  end

  defp own_head_branch(branch) when is_binary(branch) and branch != "", do: {:ok, branch}
  defp own_head_branch(_branch), do: {:error, :no_head_branch}

  defp valid_override(name) do
    case branch_name_defect(name) do
      nil -> {:ok, name}
      reason -> {:error, {:invalid_branch_override, excerpt(name), reason}}
    end
  end

  # `git check-ref-format --branch` as a pure function: the rules of git-check-ref-format(1)
  # for `refs/heads/<name>`, plus its two branch-only rules (no leading `-`, not `HEAD`), plus
  # two refusals git does not make: a leading `+` (`git push -u origin +name` reads it as a
  # forced refspec) and text that is not UTF-8 (the name is stored in events). Returns the
  # first rule the name breaks, or nil.
  defp branch_name_defect(name) do
    cond do
      name == "" -> :empty
      not String.valid?(name) -> :not_utf8
      String.contains?(name, " ") -> :space
      String.match?(name, ~r/[\x00-\x1f\x7f]/) -> :control_character
      String.starts_with?(name, "-") -> :leading_dash
      String.starts_with?(name, "+") -> :leading_plus
      name == "HEAD" -> :reserved_name
      String.contains?(name, ["~", "^", ":", "?", "*", "[", "\\"]) -> :forbidden_character
      String.contains?(name, "..") -> :double_dot
      String.contains?(name, "@{") -> :at_brace
      String.ends_with?(name, ".") -> :trailing_dot
      true -> component_defect(String.split(name, "/"))
    end
  end

  defp component_defect(components) do
    cond do
      "" in components -> :empty_component
      Enum.any?(components, &String.starts_with?(&1, ".")) -> :dot_component
      Enum.any?(components, &String.ends_with?(&1, ".lock")) -> :lock_component
      true -> nil
    end
  end

  defp excerpt(text) do
    if String.length(text) > @max_reported_chars,
      do: String.slice(text, 0, @max_reported_chars) <> "…",
      else: text
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

  # The range the run's own commits live in. A run cut from the fetched
  # `origin/<branch>` tip leaves the local base branch behind that commit: a range
  # that starts at the branch NAME would count the origin commits as the run's work.
  # When the run recorded the commit it was cut from, the range starts there.
  defp base_range(context, base_branch) do
    case Map.get(context, :base_ref) do
      sha when is_binary(sha) and sha != "" -> sha
      _ -> base_branch
    end
  end

  defp commits_ahead(context, base_branch, head_branch, cwd) do
    args = ["rev-list", "--count", base_range(context, base_branch) <> ".." <> head_branch]
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

  # GitHub is asked before any effect is touched: the PR of this repository whose head is the
  # local tip IS the run's PR, however the keys stand (TRD-004). The tip is read first, once, as
  # the push's own intent (`BranchPush.intent/4`). Every other answer (no PR, another head, a
  # failed lookup, an unreadable tip) goes on into the sequence, because creating the PR stays
  # the loud authority and a failed lookup is never a success.
  defp propose(context, run_id, base_branch, head_branch, pr_content, cwd) do
    intent = BranchPush.intent(runner(context), run_id, head_branch, cwd)

    case adopt_open_pr(context, run_id, base_branch, head_branch, cwd, intent) do
      {:ok, _url} = adopted ->
        adopted

      :continue ->
        with :ok <- preflight_open_pr(run_id, base_branch, head_branch),
             {:ok, push_meta} <-
               log_refusal(intent, run_id, head_branch, "autopr.git_push", "git push"),
             :ok <- push_head(context, run_id, head_branch, cwd, push_meta) do
          open_pr(
            context,
            run_id,
            base_branch,
            head_branch,
            pr_content,
            cwd,
            push_meta.pushed_local_sha
          )
        end
    end
  end

  # The unreadable-tip case has nothing to compare a PR's head with: the sequence reports it at
  # the push, as it always did.
  defp adopt_open_pr(_context, _run_id, _base_branch, _head_branch, _cwd, {:error, _reason}),
    do: :continue

  defp adopt_open_pr(
         context,
         run_id,
         base_branch,
         head_branch,
         cwd,
         {:ok, %{pushed_local_sha: tip}}
       ) do
    lookup =
      PrLookup.find_open(head_branch, base_branch,
        cwd: cwd,
        command_runner: runner(context),
        timeout_ms: lookup_timeout_ms(context),
        expected_head: tip
      )

    case lookup do
      {:ok, %PrLookup.Pr{url: url}} ->
        settle_adopted_key(run_id, base_branch, head_branch)

        Logger.info(
          "AutoPR.run_id=#{run_id} adopted #{url}: GitHub already has this run's PR for #{head_branch} into #{base_branch}, so nothing is pushed or created",
          run_id: run_id,
          base_branch: base_branch,
          head_branch: head_branch,
          pr_url: url,
          operation: "autopr.lookup",
          outcome: "adopted"
        )

        {:ok, url}

      :none ->
        :continue

      {:error, reason} ->
        Logger.warning(
          "AutoPR.run_id=#{run_id} no PR adopted for #{head_branch} into #{base_branch} (#{inspect(reason)}); going on to the push and gh pr create",
          run_id: run_id,
          base_branch: base_branch,
          head_branch: head_branch,
          operation: "autopr.lookup",
          outcome: "not_adopted",
          reason: inspect(reason)
        )

        :continue
    end
  end

  # GitHub has answered for the run's PR create, so the key an earlier attempt left `started` or
  # `ambiguous` is settled (`PrCreateEffect.settle_adopted/3`).
  defp settle_adopted_key(run_id, base_branch, head_branch) do
    case PrCreateEffect.settle_adopted(run_id, head_branch, base_branch) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "AutoPR.run_id=#{run_id} could not settle #{inspect(PrCreateEffect.key(run_id, head_branch, base_branch))} after adopting the PR: #{inspect(reason)}",
          run_id: run_id,
          key: PrCreateEffect.key(run_id, head_branch, base_branch),
          operation: "autopr.lookup",
          outcome: "key_not_settled",
          reason: inspect(reason)
        )
    end
  end

  # A PR-create key recovery left unresolved refuses the whole sequence BEFORE
  # the push: a push that ran anyway could publish commits the remote lacks.
  defp preflight_open_pr(run_id, base_branch, head_branch) do
    Effect.preflight(
      :pr_create,
      PrCreateEffect.key(run_id, head_branch, base_branch),
      %{"run_id" => run_id}
    )
    |> log_refusal(run_id, head_branch, "autopr.preflight", "git push and gh pr create")
  end

  # GitHub cannot open a PR from a branch it has never seen: `gh pr create`
  # fails with "Head ref must be a branch" / "No commits between ...". Foreman
  # creates the run branch locally in a worktree, so it must be published
  # first.
  #
  # The push is a keyed effect: `BranchPush.intent/4` read the remote head and
  # the local tip BEFORE the push (`propose/6`, once, ahead of the PR lookup) and
  # `Effect.run/4` records them in the `started` key, so a crash around the push
  # is reconciled against the remote at boot instead of the push being repeated
  # blind. A push whose intent cannot be recorded (no `cwd`, an unreadable head,
  # the key store down) does not run.
  defp push_head(context, run_id, head_branch, cwd, meta) do
    Effect.run(
      :branch_push,
      BranchPush.key(run_id, head_branch),
      fn -> git_push(context, run_id, head_branch, cwd) end,
      meta
    )
    |> log_refusal(run_id, head_branch, "autopr.git_push", "git push")
  end

  defp git_push(context, run_id, head_branch, cwd) do
    opts = [stderr_to_stdout: true, cd: cwd]

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

  # `gh pr create` is a keyed effect too (`Reconcilers.PrCreate`): a crash after
  # GitHub made the PR and before the run recorded it is found by asking GitHub
  # at boot, never by creating a second PR.
  defp open_pr(context, run_id, base_branch, head_branch, pr_content, cwd, tip) do
    Effect.run(
      :pr_create,
      PrCreateEffect.key(run_id, head_branch, base_branch),
      fn -> gh_pr_create(context, run_id, base_branch, head_branch, pr_content, cwd, tip) end,
      PrCreateEffect.intent(run_id, head_branch, base_branch, cwd)
    )
    |> log_refusal(run_id, head_branch, "autopr.gh_create", "gh pr create")
  end

  defp gh_pr_create(
         context,
         run_id,
         base_branch,
         head_branch,
         %PrContent{title: title, body: body},
         cwd,
         tip
       ) do
    cmd =
      @gh_args ++
        ["--base", base_branch, "--head", head_branch, "--title", title, "--body", body]

    opts = [stderr_to_stdout: true, cd: cwd]

    Logger.info(
      "AutoPR.run_id=#{run_id} gh pr create --base=#{base_branch} --head=#{head_branch} (cwd=#{cwd})",
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

        failure = {:gh_pr_create_failed, exit_code, String.trim(output)}
        after_failed_create(context, run_id, base_branch, head_branch, cwd, tip, failure)
    end
  end

  # A non-zero exit does not say the PR does not exist: GitHub may have made it, or already had
  # it (it refuses a duplicate open PR, but not a closed one). Ask again before the key settles
  # `failed`: the PR with the tip is the run's (`{:ok, url}`, so the key settles `completed`); a
  # PR of this repository with another head is the typed mismatch and nothing is adopted; none,
  # or a failed lookup, keeps the create's own error.
  defp after_failed_create(context, run_id, base_branch, head_branch, cwd, tip, failure) do
    lookup =
      PrLookup.find_open(head_branch, base_branch,
        cwd: cwd,
        command_runner: runner(context),
        timeout_ms: lookup_timeout_ms(context),
        expected_head: tip
      )

    case lookup do
      {:ok, %PrLookup.Pr{url: url}} ->
        Logger.info(
          "AutoPR.run_id=#{run_id} adopted #{url} after gh pr create failed: it is this run's PR for #{head_branch} into #{base_branch}",
          run_id: run_id,
          base_branch: base_branch,
          head_branch: head_branch,
          pr_url: url,
          operation: "autopr.lookup",
          outcome: "adopted"
        )

        {:ok, url}

      {:error, {:pr_lookup_mismatch, url, expected, actual}} = mismatch ->
        Logger.error(
          "AutoPR.run_id=#{run_id} #{url} already exists for #{head_branch} into #{base_branch} but its head is #{actual}, not the pushed tip #{expected}: not adopted; an operator closes or aligns it",
          run_id: run_id,
          base_branch: base_branch,
          head_branch: head_branch,
          pr_url: url,
          operation: "autopr.lookup",
          outcome: "mismatch"
        )

        mismatch

      :none ->
        {:error, failure}

      {:error, reason} ->
        Logger.warning(
          "AutoPR.run_id=#{run_id} could not look the PR up after gh pr create failed (#{inspect(reason)}); the create's own error stands",
          run_id: run_id,
          base_branch: base_branch,
          head_branch: head_branch,
          operation: "autopr.lookup",
          outcome: "lookup_failed",
          reason: inspect(reason)
        )

        {:error, failure}
    end
  end

  # An effect whose intent was not recorded did not run. Nothing downstream
  # tells that from a failed call, so say it here.
  defp log_refusal(
         {:error, {:effect_unresolved, key}} = result,
         run_id,
         head_branch,
         operation,
         what
       ) do
    Logger.error(
      "AutoPR.run_id=#{run_id} #{what} NOT run: #{inspect(key)} is unresolved (see foreman_doctor, Unresolved effect keys). " <>
        "run.reset lifts this only for a failed, stuck, blocked or paused run, and only when the reset run resumes and reaches the effect again; for any other run check GitHub and the doctor list",
      run_id: run_id,
      head_branch: head_branch,
      operation: operation,
      outcome: "refused",
      reason: "effect_unresolved"
    )

    result
  end

  defp log_refusal(
         {:error, {:effect_undecided, key}} = result,
         run_id,
         head_branch,
         operation,
         what
       ) do
    Logger.error(
      "AutoPR.run_id=#{run_id} #{what} NOT run: #{inspect(key)} is undecided: an earlier attempt may still be in flight or may already have happened, and nothing has said which, so it is not repeated. " <>
        "The boot sweep is asked to decide it; check GitHub and foreman_doctor, Unresolved effect keys",
      run_id: run_id,
      head_branch: head_branch,
      operation: operation,
      outcome: "refused",
      reason: "effect_undecided"
    )

    result
  end

  defp log_refusal(
         {:error, {:effect_marker_malformed, key}} = result,
         run_id,
         head_branch,
         operation,
         what
       ) do
    Logger.error(
      "AutoPR.run_id=#{run_id} #{what} NOT run: the unresolved marker of #{inspect(key)} is malformed; no reset clears it, the stored key needs an operator's repair (see foreman_doctor, Unresolved effect keys)",
      run_id: run_id,
      head_branch: head_branch,
      operation: operation,
      outcome: "refused",
      reason: "effect_marker_malformed"
    )

    result
  end

  defp log_refusal(
         {:error, {:effect_check_failed, reason}} = result,
         run_id,
         head_branch,
         operation,
         what
       ) do
    Logger.error(
      "AutoPR.run_id=#{run_id} #{what} NOT run: could not check whether its key is unresolved: #{inspect(reason)}",
      run_id: run_id,
      head_branch: head_branch,
      operation: operation,
      outcome: "refused",
      reason: inspect(reason)
    )

    result
  end

  defp log_refusal(
         {:error, {:intent_not_recorded, reason}} = result,
         run_id,
         head_branch,
         operation,
         what
       ) do
    Logger.error(
      "AutoPR.run_id=#{run_id} #{what} NOT run: its intent could not be recorded: #{inspect(reason)}",
      run_id: run_id,
      head_branch: head_branch,
      operation: operation,
      outcome: "refused",
      reason: inspect(reason)
    )

    result
  end

  defp log_refusal(result, _run_id, _head_branch, _operation, _what), do: result

  @doc false
  def __pr_content_for_test__(context) do
    case resolve_head_branch(context) do
      {:ok, head_branch} -> pr_content(context, head_branch)
      {:error, :no_head_branch} -> pr_content(context, nil)
      {:error, {:invalid_branch_override, _name, _reason}} = refused -> refused
      {:error, {:ambiguous_branch_override, _first, _second}} = refused -> refused
    end
  end

  defp pr_content(context, head_branch) do
    case Map.fetch(context, :pr_body_headings) do
      {:ok, headings} when headings != [] ->
        templated_pr_content(context, headings, head_branch)

      {:ok, []} ->
        task_or_legacy_pr_content(context)

      :error ->
        task_or_legacy_pr_content(context)
    end
  end

  defp task_or_legacy_pr_content(context) do
    title = fetch_task_field(context, :task_title)
    description = fetch_task_field(context, :task_description)

    case {title, description} do
      {:absent, :absent} ->
        {:ok, legacy_pr_content(context)}

      _task_backed ->
        with {:ok, title} <- resolve_task_field(context, title, :task_title, :title),
             {:ok, body} <-
               resolve_task_field(context, description, :task_description, :description) do
          {:ok, %PrContent{title: title, body: body}}
        end
    end
  end

  # A project that requires headings gets a body that carries them, whatever the
  # task says: the task, the run's commits and the phase artifact are placed
  # under the headings, and a heading Foreman has no content for says so.
  defp templated_pr_content(context, headings, head_branch) do
    with {:ok, title} <- pr_title(context) do
      case PrBody.build(headings, pr_body_sources(context, head_branch)) do
        {:ok, body} -> {:ok, %PrContent{title: title, body: body}}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp pr_title(context) do
    case fetch_task_field(context, :task_title) do
      {:present, title} -> validate_task_value(context, title, :title)
      :absent -> {:ok, legacy_pr_title(context)}
    end
  end

  defp pr_body_sources(context, head_branch) do
    %PrBody.Sources{
      task_title: Map.get(context, :task_title),
      task_description: Map.get(context, :task_description),
      commits: run_commits(context, head_branch),
      artifact_path: artifact_reference(context),
      artifact_section: artifact_section(context)
    }
  end

  # The artifact is named the way the untemplated body names it (`PrBodyPath`):
  # relative to the tree the PR renders from, and not at all when it sits outside
  # that tree, so a body never carries the host path of the worktree it was
  # written in.
  defp artifact_reference(context) do
    case PrBodyPath.repo_relative(Map.get(context, :artifact_path), body_path_root(context)) do
      {:ok, relative} -> relative
      :outside_repo -> nil
    end
  end

  # The review-findings section is the one the untemplated body carries
  # (`findings_section/1`: one renderer, AGENTS.md §5.7). A run with no artifact
  # has none, and the heading that would have held it says so.
  defp artifact_section(context) do
    case Map.get(context, :artifact_path) do
      nil -> nil
      _artifact_path -> findings_section(context)
    end
  end

  # The head branch is the one `maybe_create_pr/1` resolved (an artifact's
  # `FOREMAN_BRANCH=` override can name a branch other than the run's own), so
  # the listed range is the range the PR is opened for.
  defp run_commits(context, head_branch) do
    base_branch = Map.get(context, :base_branch)

    cond do
      not (is_binary(base_branch) and base_branch != "") ->
        {:error, "the run's base branch is unknown"}

      not (is_binary(head_branch) and head_branch != "") ->
        {:error, "the run's head branch is unknown"}

      true ->
        list_commits(context, base_branch, head_branch)
    end
  end

  defp list_commits(context, base_branch, head_branch) do
    opts =
      case Map.get(context, :cwd) do
        cwd when is_binary(cwd) and cwd != "" -> [stderr_to_stdout: true, cd: cwd]
        _ -> [stderr_to_stdout: true]
      end

    range = "#{base_range(context, base_branch)}..#{head_branch}"

    case run(context, "git", ["log", "--format=%H%x09%s", range], opts) do
      {output, 0} ->
        {:ok, parse_commits(output)}

      {output, exit_code} ->
        Logger.warning(
          "AutoPR could not list the commits of #{base_branch}..#{head_branch}: " <>
            "git log exited with #{exit_code}: #{output}",
          run_id: Map.get(context, :run_id),
          outcome: "commits_unavailable"
        )

        # The body is public: git's own output can name host paths, so it stays in
        # the log above and the body carries the exit code only.
        {:error, "git log exited with #{exit_code}"}
    end
  end

  defp parse_commits(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, "\t", parts: 2) do
        [sha, subject] -> {String.trim(sha), String.trim(subject)}
        [sha] -> {String.trim(sha), ""}
      end
    end)
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
      is_binary(value) and String.trim(value) != "" ->
        {:ok, value}

      is_binary(value) ->
        {:error, %TaskMetadataError{run_id: run_id, field: field, reason: :blank}}

      true ->
        {:error, %TaskMetadataError{run_id: run_id, field: field, reason: :invalid}}
    end
  end

  defp generated_body(context) do
    run_id = Map.fetch!(context, :run_id)
    artifact_path = Map.get(context, :artifact_path)

    "Foreman run `#{run_id}` complete.\n" <>
      ForemanServer.Workflow.PrBodyPath.artifact_line(artifact_path, body_path_root(context)) <>
      findings_section(context)
  end

  defp legacy_pr_content(context) do
    %PrContent{title: legacy_pr_title(context), body: generated_body(context)}
  end

  defp run(context, executable, args, opts), do: runner(context).(executable, args, opts)

  defp runner(context), do: Map.get(context, :command_runner) || (&System.cmd/3)

  # The bound on a `gh pr list` lookup: a hung `gh` must not hold the executor.
  defp lookup_timeout_ms(context),
    do: Map.get(context, :lookup_timeout_ms) || Command.default_timeout_ms()

  defp pr_url_from_output(output) do
    case Regex.run(~r"https://github\.com/[^\s]+", output) do
      [url | _] -> String.trim(url)
      nil -> nil
    end
  end

  defp findings_section(context),
    do:
      ForemanServer.Workflow.ReviewFindings.pr_section(
        %ForemanServer.Workflow.ReviewFindings.Context{
          artifact_path: Map.get(context, :artifact_path),
          run_id: Map.fetch!(context, :run_id),
          phase_name: nil,
          repo_root: body_path_root(context)
        },
        "AutoPR"
      )

  # The artifact lives in the run WORKTREE, while `cwd` is the repository the
  # `gh` commands run in, so the worktree root is tried first; the artifact line
  # is dropped when neither yields a relative path (`PrBodyPath`).
  defp body_path_root(context),
    do: Map.get(context, :artifact_root) || Map.get(context, :cwd)
end
