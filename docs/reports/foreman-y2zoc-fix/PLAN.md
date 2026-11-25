# PLAN — cut runs from `origin/<branch>` (foreman-y2zoc, redo of foreman-ch78x)

## 1. Verdict

**Real bug, unfixed on this tree** (HEAD `0b700eba`). The new-run worktree path never
fetches: `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:4528`
`resolve_declared_base/2`, with no declared `worktree: base:`, returns
`resolve_revision(project_root, "HEAD")` — the shared checkout's local HEAD, arbitrarily
behind `origin/<branch>`. `grep -rn "fetch_branch" packages/foreman_server/lib` → only
`exec/git.ex:568` (definition) and `exec/worktree.ex:147` (`sync_branch/3`, the follow-up
path).

Scope decisions (PRs #942/#943/#945/#946 closed unmergeable; do not reintroduce their defects):

- **No `origin` configured is NOT an error**, it is a logged degradation. Remote-less
  checkouts are supported (`projects/repo_validation.ex:113`) and ~63 test fixtures have no
  remote; such a checkout has no tip to be stale against.
- **`origin` exists but lacks the branch IS a typed error.** `remember_run_base_branch/1`
  records that branch as the PR base, so a HEAD fallback would open a PR against a branch the
  remote does not have. #942's rejected silent fallback.
- **Fetch failure (offline/auth/timeout) degrades to local HEAD + warning**, never fails the
  run (#942's rejected hard-fail; bead item 2).
- **Bead item 3 (`base_sha`): already satisfied — do not add it.** `WorktreeCreated.base_ref`
  IS the commit the worktree was cut from, persisted on the worktree projection
  (`projection_store.ex:3659`) and already preferred over the run's `base_branch` by
  `lib/foreman_server_web/operator_dashboard.ex:648`
  (`value(worktree, :base_ref) || value(run, :base_branch)`). #945's second record resolved
  the LOCAL branch and was rejected for that.
- **Bead item 4 (`base_ref_policy`)**: no consumer → not added (#943's defect).
- **Bead item 5 (reword "N commits behind origin")**: `grep -rn
  "behind_origin\|commits_behind"` over repo and `docs/` → 0 hits; that detector existed only
  on closed branch #946. Nothing to reword.
- **Bead item 6 (declared `spec.base`)**: stays local, never fetched; PR base branch still the
  checkout's branch. Documented, no code change.

## 2. Root cause

`resolve_declared_base/2` (`run_executor.ex:4528`) resolves `"HEAD"` of the shared checkout;
`create_new_run_worktree/2` (`:4174`) passes it as the worktree `base_ref`.

## 3. Failing check first

New `packages/foreman_server/test/foreman_server/workflow/run_executor_origin_base_test.exs`,
`defmodule ForemanServer.Workflow.RunExecutorOriginBaseTest`, `use ExUnit.Case, async: true`
(no ProjectionStore: `default_project_root/2` reads `task.working_directory`).

`setup`: `tmp` under `System.tmp_dir!()`; bare `origin.git` (`git init --bare --quiet
--initial-branch=main`); clone `repo` (the operator checkout) commits `seed.txt`, pushes
`main`; clone `peer` commits `ahead.txt`, pushes — so `origin/main` is ahead while `repo` is
behind. Export `tmp, origin, repo, stale_head` (`git -C repo rev-parse HEAD`), `origin_tip`
(`git -C peer rev-parse HEAD`). Helpers `git!(dir, args)` (assert exit 0, trimmed output) and
`commit!(repo, file, msg)` with `-c user.name=T -c user.email=t@x -c commit.gpgsign=false`.

`state(repo, task_extra \\ %{})` → `%{task: Map.merge(%{project_id: "proj-origin-base",
task_id: "t-origin-base", working_directory: repo}, task_extra),
run_id: "run-" <> String.duplicate("0", 32), plan_context: nil, worktree_spec: %{}}`.
Subject: `RunExecutor.__resolve_provisioned_base_for_test__(state, spec)` (Edit 2d), which
returns `{:ok, project_root, base_ref, _, _}`.

1. `"the base is the fetched origin tip, not the stale checkout HEAD"` — `spec = %{}`; assert
   `{:ok, ^repo, ^origin_tip, nil, nil}` and `origin_tip != stale_head`.
2. `"the fetch leaves the checkout untouched"` — after case 1: `rev-parse HEAD == stale_head`,
   `symbolic-ref --short HEAD == "main"`, `status --porcelain == ""`,
   `rev-parse refs/remotes/origin/main == origin_tip`.
3. `"a remote that does not carry the branch is a typed error"` —
   `git!(repo, ["checkout", "-q", "-b", "feat/local-only"])` + a commit; assert
   `{:error, {:origin_base_missing, "origin", "feat/local-only"}}`.
4. `"no origin remote falls back to HEAD"` — `git!(repo, ["remote", "remove", "origin"])`;
   base == `rev-parse HEAD` of `repo`.
5. `"an unreachable origin falls back to HEAD"` —
   `git!(repo, ["remote", "set-url", "origin", Path.join(tmp, "gone.git")])`; base ==
   `rev-parse HEAD` of `repo`.
6. `"a declared base is resolved locally and never fetched"` — `spec = %{base: "main"}`; base
   == local `rev-parse main^{commit}` (`== stale_head`), not `origin_tip`.
7. `"a task source_branch is still cut from the local branch"` —
   `state(repo, %{source_branch: "feat/local-only"})` on case 3's branch, `spec = %{}`; base
   == that local branch tip, no error.

Add to `packages/foreman_server/test/foreman_server/exec/git_test.exs`: `fetch_remote_tip/3`
returns `{:ok, tip}` on a pushed branch, `{:error, :no_remote}` with no remote,
`{:error, {:remote_branch_missing, "origin", "nope"}}` for an absent branch,
`{:error, %ForemanServer.Exec.Error{}}` for an unreachable remote URL.

Red before the fix: case 1 returns `stale_head`; case 3 returns `{:ok, ...}`.

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test \
  test/foreman_server/workflow/run_executor_origin_base_test.exs'
```

## 4. Edits

### Edit 1 — `packages/foreman_server/lib/foreman_server/exec/git.ex`

Insert after `ref_sha/2` (ends line 604). `Error` is aliased; `check_ref/2` at `:398`,
`cmd_with_deadline/3` at `:486`. Exit codes verified on git 2.55.0: `ls-remote --exit-code`
gives 0 present, 2 absent, 128 unreachable — classify by exit code, never by matching
stderr text (#942's substring match on `"couldn't find remote ref"`).

```elixir
  @doc "Whether `remote` is configured in `repo`."
  @spec remote_exists?(String.t(), String.t()) :: boolean()
  def remote_exists?(repo, remote) do
    case check_ref(:remote, remote) do
      :ok ->
        match?(
          {_output, 0},
          System.cmd("git", ["-C", repo, "remote", "get-url", remote], stderr_to_stdout: true)
        )

      {:error, _} ->
        false
    end
  end

  @doc """
  Whether `remote` carries `branch`, asked with `git ls-remote --exit-code --heads`.

  `:absent` ("the remote does not have it") and `:unreachable` ("I could not ask") are
  distinct on purpose.
  """
  @spec remote_branch_exists?(String.t(), String.t(), String.t()) ::
          :present | :absent | :unreachable
  def remote_branch_exists?(repo, remote, branch) do
    with :ok <- check_ref(:remote, remote),
         :ok <- check_ref(:branch, branch) do
      case cmd_with_deadline(
             ["-C", repo, "ls-remote", "--exit-code", "--heads", remote, "refs/heads/#{branch}"],
             30_000,
             "ls-remote"
           ) do
        {_output, 0} -> :present
        {_output, 2} -> :absent
        {_output, _other} -> :unreachable
      end
    else
      {:error, _} -> :unreachable
    end
  end

  @doc """
  Fetch `branch` from `remote` and return the commit the remote's branch points at.

  Only `refs/remotes/<remote>/<branch>` moves: the working tree, the index and the checked-out
  branch are untouched. The remote is asked a second time only after a failed fetch, to tell
  "no such branch" (`{:error, {:remote_branch_missing, remote, branch}}`) apart from "could
  not read the remote" (`{:error, %Error{}}`). `{:error, :no_remote}` means `remote` is not
  configured in `repo`.
  """
  @spec fetch_remote_tip(String.t(), String.t(), String.t()) ::
          {:ok, String.t()}
          | {:error, :no_remote | {:remote_branch_missing, String.t(), String.t()} | Error.t()}
  def fetch_remote_tip(repo, remote, branch) do
    if remote_exists?(repo, remote) do
      case fetch_branch(repo, remote, branch) do
        :ok -> ref_sha(repo, "refs/remotes/#{remote}/#{branch}")
        {:error, %Error{} = error} -> classify_fetch_failure(repo, remote, branch, error)
      end
    else
      {:error, :no_remote}
    end
  end

  defp classify_fetch_failure(repo, remote, branch, error) do
    case remote_branch_exists?(repo, remote, branch) do
      :absent -> {:error, {:remote_branch_missing, remote, branch}}
      _present_or_unreachable -> {:error, error}
    end
  end
```

### Edit 2 — `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`

(a) Line 4522, in `resolve_run_base/2`: `resolve_declared_base(spec, project_root)` →
`resolve_declared_base(state, spec, project_root)`.

(b) `resolve_declared_base/2` (lines 4528-4541): rename to `/3` taking `state` first; replace
only its `_ ->` clause body `resolve_revision(project_root, "HEAD")` with
`resolve_origin_base(state, project_root)`. The declared-base clause is unchanged.

(c) Add directly below it (`JobsiteGit` is the existing alias for `Exec.Git`, `:74`):

```elixir
  # A run with no declared base is cut from the FETCHED tip of its checkout's branch on
  # `origin`, not the checkout's own `HEAD`: a shared checkout nobody has pulled is
  # arbitrarily behind, and a run cut from it opens a PR against stale code. The fetch only
  # advances `refs/remotes/origin/<branch>`. A task naming a `source_branch` is cut from that
  # LOCAL branch by `apply_source_branch/4`, which replaces whatever this returns, so nothing
  # is fetched for it; a detached checkout has no branch to fetch, and
  # `remember_run_base_branch/1` already refuses its PR.
  defp resolve_origin_base(state, project_root) do
    if is_binary(source_branch(state)) do
      resolve_revision(project_root, "HEAD")
    else
      case checkout_branch(project_root) do
        {:ok, branch} -> origin_base(state, project_root, "origin", branch)
        {:error, _detached_head} -> resolve_revision(project_root, "HEAD")
      end
    end
  end

  # Three answers, three behaviours. The remote's tip is the base. "The remote answered and
  # does not carry the branch" is a TYPED failure, because `remember_run_base_branch/1`
  # records that branch name as the PR base and the PR would target a branch the remote does
  # not have. "I could not read the remote" (offline, auth, timeout, no `origin`) cuts from
  # the checkout's `HEAD`, LOUDLY: failing every run whenever the network is down is worse
  # than the stale base this removes, and a remote-less checkout has no tip to be stale
  # against.
  defp origin_base(state, project_root, remote, branch) do
    case JobsiteGit.fetch_remote_tip(project_root, remote, branch) do
      {:ok, sha} ->
        {:ok, sha}

      {:error, {:remote_branch_missing, ^remote, ^branch}} ->
        {:error, {:origin_base_missing, remote, branch}}

      {:error, reason} ->
        Logger.warning(
          "RunExecutor #{state.run_id} could not read #{remote}/#{branch} in #{project_root}; " <>
            "cutting the run from the checkout's HEAD instead: #{inspect(reason)}",
          run_id: state.run_id,
          operation: "run_executor.origin_base",
          outcome: "degraded"
        )

        resolve_revision(project_root, "HEAD")
    end
  end
```

(d) Add beside the other test exports (after `__create_run_worktree_for_test__/2`, `:5993`):

```elixir
  @doc false
  def __resolve_provisioned_base_for_test__(state, spec),
    do: resolve_provisioned_base(state, spec)
```

### Edit 3 — three fixtures that add an `origin` without pushing

`init_repo!/2` in `test/foreman_server/workflow/pr_ready_failed_sites_test.exs:331`,
`.../multi_repo_pr_retry_test.exs:335`, `.../run_executor_multi_repo_pr_test.exs:515` end with
`git!(repo, ["remote", "add", "origin", origin])` and never push, so `main` is absent on the
remote and Edit 2 returns `{:origin_base_missing, "origin", "main"}`. Add one line after each
`remote add`: `git!(repo, ["push", "-q", "-u", "origin", "main"])`.

### Edit 4 — documentation (the base COMMIT changed; the base BRANCH did not)

- `docs/user-guide.md:117-121` — "for every other workflow the base is the project checkout's
  `HEAD` when the run's first phase starts" → the fetched `origin/<branch>` tip of the
  checkout's branch (the fetch advances only `refs/remotes/origin/<branch>`); a declared
  `base` is resolved locally and never fetched; no `origin`, or a remote that cannot be read,
  falls back to the checkout's `HEAD` with a logged warning; an `origin` that does not carry
  the branch fails the run with `origin_base_missing`.
- `docs/user-guide.md:566-568` ("**Base branch.**") — branch name unchanged; add one sentence
  that the base COMMIT is that branch's fetched `origin` tip.
- `docs/cli-reference.md:626` — same one-sentence addition to the "Foreman latches the run's
  PR base **branch** …" paragraph.
- `docs/lessons/phase-execution-and-pr-mechanics.md:235ff` — that paragraph claims branch name
  and base commit "describe one repository state" because both read the same checkout at the
  same moment. Correct it: the NAME is still local, the COMMIT is now the branch's fetched
  `origin` tip, with the two fallbacks and the one typed refusal.
- `CLAUDE.md`: `grep -niE "\bHEAD\b|base branch|origin/"` → 0 hits, no edit. `README.md:280`
  says only "the recorded run base branch" (unchanged), no edit. State both in the fix report.

Identifiers added: `Exec.Git.remote_exists?/2`, `remote_branch_exists?/3`, `fetch_remote_tip/3`
and the run failure reason `{:origin_base_missing, remote, branch}`. None removed or renamed.
No routes, config keys, env vars, CLI verbs or MCP tools.

## 5. Verification

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors \
  test/foreman_server/workflow/run_executor_origin_base_test.exs \
  test/foreman_server/exec/git_test.exs \
  test/foreman_server/workflow/run_executor_run_worktree_test.exs \
  test/foreman_server/workflow/run_executor_source_branch_test.exs \
  test/foreman_server/workflow/run_executor_resume_context_test.exs \
  test/foreman_server/workflow/run_executor_multi_repo_test.exs \
  test/foreman_server/workflow/run_executor_multi_repo_pr_test.exs \
  test/foreman_server/workflow/multi_repo_pr_retry_test.exs \
  test/foreman_server/workflow/pr_ready_failed_sites_test.exs'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'
```

Success = every command exits 0 with no warnings. The full suite is required: ~35 other test
files provision run worktrees from repos with no `origin` and must all take the warn+HEAD
path. If a suite stalls, suspect a fixture whose `origin` URL is a real host — report it, do
not shorten the deadlines. Postgres:
`DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test`, `foreman-postgres` up.

## 6. Out of scope

- Secondary repositories: `repo_base/1` in `run_executor.ex:~4336` and the duplicate in
  `workflow/repo_attach.ex:~113` keep basing on the registered `default_branch` tip / local
  HEAD. The duplication is pre-existing; do not extend the fetch into it here.
- `VcsAdapter`: do NOT add a `fetch_base` callback (#942 did). Its retry loop is 3 attempts at
  25/50 ms, useless for a network fetch, and a new callback forces edits to all four stubs in
  `test/foreman_server/vcs_adapter_test.exs`. Degradation replaces retry.
- `base_sha` on `RunBaseBranchRecorded`, a `base_ref_policy` setting, any "behind origin"
  recommendation (see Verdict).
- `apply_source_branch/4`, the ImplementationContext branch of `resolve_run_base/2`,
  `remember_run_base_branch/1`, `resolve_revision/2`, `Exec.Worktree.sync_branch/3` (its fetch
  failure must stay fatal), `Workflow.AttachBranch`, AutoPR.
- Rebasing the branch, committing `docs/reports/**`, and any `git add -A`.
