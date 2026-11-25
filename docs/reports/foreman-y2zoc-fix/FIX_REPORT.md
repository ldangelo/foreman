# Fix report — foreman-y2zoc (cut runs from `origin/<branch>`)

## 1. Root cause

`RunExecutor.resolve_declared_base/2` (`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`) resolved the run's
base revision from the **shared checkout's local `HEAD`** whenever the run declared no explicit `base`:

```elixir
defp resolve_declared_base(spec, project_root) do
  case Map.get(spec, :base) do
    declared when is_binary(declared) and declared != "" -> ...
    _ -> resolve_revision(project_root, "HEAD")
  end
end
```

The shared checkout is never fetched before a run starts, so `HEAD` may be arbitrarily far behind `origin/<branch>`; the run
worktree was then cut from that stale commit and the PR — whose base branch was latched from the same checkout by
`remember_run_base_branch/1` — compared against a stale base (bead `foreman-y2zoc`, issue `foreman-ch78x`). The plan for this
change is `docs/reports/foreman-y2zoc-fix/PLAN.md`.

The base branch *name* was already recorded and persisted (`remember_run_base_branch/1` → `persisted_run_base_branch/1`); the
base *commit* was not taken from the remote at all.

## 2. Change

| Path | Rationale |
| --- | --- |
| `packages/foreman_server/lib/foreman_server/exec/git.ex` | Added `remote_exists?/2`, `remote_branch_exists?/3` (`:present` / `:absent` / `:unreachable`, decided by the **exit code** of `git ls-remote --exit-code --heads`, never by stderr text) and `fetch_remote_tip/3` (`{:ok, sha}` / `{:error, :no_remote}` / `{:error, {:remote_branch_missing, remote, branch}}` / `{:error, %Error{}}`), plus the private `fetch_and_read_tip/3` and `classify_fetch_failure/4` — so the remote's tip for a branch can be read without moving the checkout's `HEAD`, and "the branch is absent" can be told apart from "the remote cannot be read". |
| `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` | `resolve_declared_base/2` → `resolve_declared_base/3` (it now needs `state`); its fallback clause calls the new `resolve_origin_base/2`, which cuts the run from the fetched `origin/<branch>` tip of the run's **recorded** base branch (`recorded_base_branch/2`: `run_base_branch/1` → `persisted_run_base_branch/1` → `checkout_branch/1`). `origin_base/4` maps a missing branch to the typed error `{:origin_base_missing, remote, branch}` and every other failure (no `origin`, unreadable remote) to `degrade_to_checkout_head/5` — the checkout's `HEAD` plus a `Logger.warning`, so an offline machine does not hard-fail every run. A run that names a task `source_branch` is not fetched at all: `apply_source_branch/4` still replaces the base with that local branch's tip. |
| `packages/foreman_server/test/foreman_server/workflow/run_executor_origin_base_test.exs` (new) | The eight plan cases: fetched tip, fetch leaves the checkout untouched, the recorded branch wins over the checkout's current branch, missing branch ⇒ typed error, no `origin` ⇒ HEAD, unreadable `origin` ⇒ HEAD, declared `base` stays local, `source_branch` stays local. |
| `packages/foreman_server/test/foreman_server/exec/git_test.exs` | Four unit tests for `fetch_remote_tip/3`: the remote's tip with the checkout untouched, a branch the remote does not carry, a checkout without the remote, an unreadable remote. |
| `packages/foreman_server/test/foreman_server/workflow/pr_ready_failed_sites_test.exs`, `.../multi_repo_pr_retry_test.exs`, `.../run_executor_multi_repo_pr_test.exs` | These fixtures create an `origin` without pushing to it; an `origin` that answers but does not carry the branch is now a typed error, so each fixture pushes `main` to its bare origin. |
| `docs/user-guide.md` | The `base`/`Base branch` sections now state that a run is cut from the fetched `origin/<branch>` tip, that a declared `base` is never fetched, and what happens without a readable `origin` or with a branch the remote lacks. |
| `docs/cli-reference.md` | Same one-sentence addition to the paragraph that latches the run's PR base branch. |
| `docs/lessons/phase-execution-and-pr-mechanics.md` | Corrected the now-false claim that the branch name and the base commit "describe one repository state": the name is local, the commit is the tip `origin` serves for that branch. |
| `docs/reports/foreman-y2zoc-fix/PLAN.md` | The CodeRabbit review phase's two round-1 findings were corrected in the plan (§3 case list, §4 "Edit 2 (c)") so the plan matches the implementation. |

## 3. Deviations from plan

- **The plan's §4 "Edit 2 (c)" snippet was corrected, not followed verbatim.** It read the checkout's *current* branch when
  choosing the branch to fetch; the implementation fetches the branch the run **recorded** (`recorded_base_branch/2`). The plan
  was updated to the implementation — the fetched branch and the PR's base branch must be the same branch, otherwise a checkout
  switched between recording and provisioning would cut the run from `origin/<other-branch>` while the PR still names the old
  one. This is CodeRabbit round-1 finding F2.
- **One test case beyond the plan's list**: "the run's recorded base branch wins over the checkout's current branch"
  (`run_executor_origin_base_test.exs`). It is the regression test for the same F2 correction; the plan's §3 case list was
  renumbered to eight cases to include it (CodeRabbit round-1 finding F1: case 2 asserts on `refs/remotes/origin/main`, so the
  resolver has to run *inside* that case — each ExUnit case builds its own checkout).
- `origin_base/4` matches `:no_remote` and `%JobsiteError{}` explicitly instead of the plan's catch-all `{:error, reason}`
  clause; the plan's own §5 (typed boundaries, no catch-all) wins.
- **Not applied from the bead, on purpose** (all listed as out of scope in the plan): the `base_sha` provenance change
  (`base_sha` already comes from `WorktreeCreated.base_ref`, i.e. the commit the worktree was actually cut from), the
  `base_ref_policy` project setting (no consumer reads it), the "N commits behind origin" recommendation text (no occurrence
  in `lib/`), the `VcsAdapter` `fetch_base` callback and its 25/50 ms retry backoff (a separate adapter concern), and the
  secondary-repository base (`repo_base/1`, `workflow/repo_attach.ex` — still the default branch's tip).

## 4. Tests

- **Failing before the change** (`run_executor_origin_base_test.exs`, 8 cases): **4 of 8 failed** — cases 1-3 returned the
  stale `HEAD` instead of `origin_tip`, and case 4 returned `{:ok, repo, sha, nil, nil}` instead of
  `{:error, {:origin_base_missing, "origin", "feat/local-only"}}`.
- **Passing after the change**: 8/8 in that file; `exec/git_test.exs` 21/21 (17 pre-existing + the 4 new `fetch_remote_tip/3`
  tests). The four `fetch_remote_tip/3` tests were written against the new API and pass; they have no failing-first proof,
  because the function did not exist before this change.
- The nine-file run (`run_executor_origin_base_test.exs`, `exec/git_test.exs`, `run_executor_run_worktree_test.exs`,
  `run_executor_source_branch_test.exs`, `run_executor_resume_context_test.exs`, `run_executor_multi_repo_test.exs`,
  `run_executor_multi_repo_pr_test.exs`, `multi_repo_pr_retry_test.exs`, `pr_ready_failed_sites_test.exs`): **170 passed,
  exit 0**.

## 5. Local verification

| Command | Result |
| --- | --- |
| `MIX_ENV=test mix compile --warnings-as-errors` | exit 0, no warnings |
| `DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors <9 files>` | 170 passed, exit 0 |
| `MIX_ENV=test mix format --check-formatted` | exit 0 (after `mix format` fixed the new test file's long `System.cmd` lines) |
| `DATABASE_URL=… MIX_ENV=test mix test --warnings-as-errors` (full suite) | see §6 of the review report / the run log |
| `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` | two rounds; see `REVIEW_CODERABBIT_REPORT.md` |

The shell exports a stale `DATABASE_URL` (port 55434, `foreman_dev`), which fails at boot with
`** (Postgrex.Error) FATAL 28P01 (invalid_password)`; every test command above therefore sets
`DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/foreman_test`.

## 6. Follow-ups

- Secondary repositories still take their base from the default branch's tip (`repo_base/1`, `workflow/repo_attach.ex`) — out
  of scope for this change, and the source of the task's finding (3).
- `VcsAdapter`'s `fetch_base` retry (3 attempts, 25/50 ms backoff) is still too short for a network fetch; this change fetches
  through `Exec.Git` instead, so the adapter path was left alone.
- `base_ref_policy` remains a project setting with no consumer.
- `ask_advisor` could not be reached in this environment (Anthropic OAuth `400 invalid_grant`, "Refresh token expired"), so no
  advisor verdict informed this change.
