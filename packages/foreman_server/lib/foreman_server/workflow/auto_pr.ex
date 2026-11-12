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
  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.Idempotency.Reconcilers.BranchPush
  alias ForemanServer.Idempotency.Reconcilers.PrCreate, as: PrCreateEffect

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
          # Optional for the commit probe only: the push and the PR create are keyed
          # effects that record `cwd` and refuse to run without it (TRD-013).
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

  Returns `{:ok, pr_url}` (the PR it created, or the one GitHub already had for the run's head),
  `:noop` when the head branch has no commits beyond the base, or `{:error, reason}`
  (`{:pr_lookup_mismatch, url, expected, actual}` names a PR of this repository whose head is
  not the tip). `base_branch` must be the branch the run's work was cut from; it is not
  defaulted.
  """
  @spec maybe_create_pr(context()) :: result()
  def maybe_create_pr(%{run_id: run_id, base_branch: base_branch} = context)
      when is_binary(run_id) and is_binary(base_branch) and base_branch != "" do
    cwd = Map.get(context, :cwd)

    with {:ok, head_branch} <- resolve_head_branch(context),
         {:ok, ahead} <- commits_ahead(context, base_branch, head_branch, cwd) do
      if ahead > 0 do
        with {:ok, pr_content} <- pr_content(context) do
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

  @doc """
  The branch `maybe_create_pr/1` pushes and opens the PR from: the artifact's
  `FOREMAN_BRANCH=` override when present, otherwise `context.head_branch`.

  Public so a caller that must name the PR's head (the merge gate's `PrReady`)
  resolves it exactly as AutoPR does rather than re-deriving it.
  """
  @spec resolve_head_branch(map()) :: {:ok, String.t()} | {:error, :no_head_branch}
  def resolve_head_branch(context) do
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

  # What recovery wrote on a key is cleared with it: `KeyStore` merges metadata, so a marker or a
  # decision left on a settled key would come back with the next attempt's re-mark and make the
  # key look unresolved or decided when nobody has looked at it.
  @recovery_fields %{
    "unresolved_at_run_version" => nil,
    "unresolved_reason" => nil,
    "decision" => nil
  }

  # GitHub has answered for the run's PR create, so a key an earlier attempt left `started` or
  # `ambiguous` is settled: the doctor does not list it, and a later Create PR after the PR was
  # closed is not refused for good. A key that is absent or already settled is left alone.
  defp settle_adopted_key(run_id, base_branch, head_branch) do
    key = PrCreateEffect.key(run_id, head_branch, base_branch)

    case read_and_settle(key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "AutoPR.run_id=#{run_id} could not settle #{inspect(key)} after adopting the PR: #{inspect(reason)}",
          run_id: run_id,
          key: key,
          operation: "autopr.lookup",
          outcome: "key_not_settled",
          reason: inspect(reason)
        )
    end
  end

  defp read_and_settle(key) do
    case KeyStore.get(key) do
      {:ok, %{status: status}} when status in [:started, :ambiguous] ->
        KeyStore.mark_completed(key, @recovery_fields)

      :not_found ->
        :ok

      {:ok, %{status: _settled}} ->
        :ok
    end
  catch
    :exit, reason -> {:error, {:key_store_unavailable, reason}}
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
         %{title: title, body: body},
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
  def __pr_content_for_test__(context), do: pr_content(context)

  defp pr_content(context) do
    title = fetch_task_field(context, :task_title)
    description = fetch_task_field(context, :task_description)

    case {title, description} do
      {:absent, :absent} ->
        {:ok, legacy_pr_content(context)}

      _task_backed ->
        with {:ok, title} <- resolve_task_field(context, title, :task_title, :title),
             {:ok, body} <-
               resolve_task_field(context, description, :task_description, :description) do
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
      if(artifact_path, do: "\nArtifact: #{artifact_path}\n", else: "") <>
      findings_section(artifact_path)
  end

  defp legacy_pr_content(context) do
    %{title: legacy_pr_title(context), body: generated_body(context)}
  end

  defp run(context, executable, args, opts), do: runner(context).(executable, args, opts)

  defp runner(context), do: Map.get(context, :command_runner) || (&System.cmd/3)

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
