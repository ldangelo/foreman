# Multi-repo PRs against real git origins (fake `gh`, real heads, merges and a check): live run, 2026-10-31

Bead `foreman-w0tnj` (parity-audit row C3, multi-repo on real GitHub). **Verdict: PARTIAL.** Real GitHub was NOT used (the task forbade a real repository), so
the bead's acceptance as written (a real GitHub PR in each of two repositories, a real failing GitHub check) is unmet. What was added is the closest local
stand-in, and running it exposed two product gaps against the bead's own acceptance statements and one unexplained failure of the fix thread.

## What was built

- `scripts/e2e/multi_repo/fake-gh` gained an **opt-in real-git mode** (active while `$E2E_GH_STATE/real-git` exists; the default mode and the five old stages are unchanged).
  `pr create` refuses a head branch that is not on the origin of the checkout it runs in or has no commits ahead of the base; `pr view` reports the origin's real branch
  tip as `headRefOid`, `mergeable` from `git merge-tree --write-tree`, and a real check `e2e-ci` (while the marker `$state/ci/<repo>` exists: SUCCESS only when the head's tree has a file
  `CI_OK` containing `ok`); `pr merge` refuses a `--match-head-commit` that is not the tip and otherwise squash-merges on the origin through a scratch clone; `gh run view <id> --log-failed -R <o/r>`
  prints the failure log. `scripts/e2e/multi_repo/fake_gh_selftest.sh` (no stack, no model) checks the shim itself: `passed=45 failed=0`; five mutants of the shim (no head-pin check, no push,
  a stale head sha, the wrong origin, a CI check that ignores content) each made it fail.
- `scripts/e2e/multi_repo.sh` gained the stage **`realgit`** (run it alone: `E2E_STAGES=realgit`, which enables the PR monitor, `FOREMAN_PR_MONITOR_ENABLED=true`): one task over repositories a and b with a
  real pi agent; PRs bound to their own origins; the Overview card and Pull requests tab; a real failing check on b observed by `PrMonitor.poll_now/0`; merge of a alone; `run fix-ci --pr <b>` with a real pi fix
  jobsite; merge of b with `--repo-id b`. The server env now also carries `FOREMAN_PR_FIX_SANDBOX=host`, `FOREMAN_JOBSITES_ALLOW_HOST_SANDBOX=true` and a `FOREMAN_VFS_ALLOWED_ROOT` passthrough (needed when the checkout is outside the default root).
  Command: `FOREMAN_VFS_ALLOWED_ROOT=<parent of the checkout> E2E_STAGES=realgit devbox run -- sh scripts/e2e/multi_repo.sh`.

## Result

| Run | Result |
|---|---|
| `realgit`, attempt 1 | `45 passed, 8 failed in 621s` (provider pi, `minimax/MiniMax-M2.7-highspeed`): one of the failures was a harness bug (a null `checks_state` compared with the string `none`), fixed |
| `realgit`, attempt 2 | `46 passed, 7 failed in 623s` (same failing set as attempt 1 minus the harness bug; the fix leg now prints diagnostics) |
| default stages `gate green gates failure legacy` with the modified `fake-gh` and script | `110 passed, 0 failed in 37s` (the same 110 assertions as the 2026-10-21 run: the old stages are unaffected) |
| `sh scripts/e2e/multi_repo/fake_gh_selftest.sh` (no stack, no model) | `passed=45 failed=0` |

The stage is therefore **red on this revision by design**: its failing assertions encode the bead's acceptance and the fix-leg expectation (below). It is a manual live script, not part of CI.

## Observed and passing (both attempts)

- Each PR is bound to the origin of its own repository; its recorded head equals the tip of the run branch on that origin; `gh pr view` shows `OPEN MERGEABLE`, the real tip and, for a, no checks; the VERSION file the agent wrote is on each head (`1.4.5`); the two heads are different commits.
- The Overview card is `ready_for_review/pr_ready` while the primary's PR is open and the gate pending.
- b's check `e2e-ci` is FAILURE on its real head; `PrMonitor.poll_now/0` observed both PRs; Foreman's watch shows `checks_state: failing` on b's PR and none on a's; the Overview card is `waiting_on_you/ci_failing`.
- `approve-merge` and `merge` of a alone: exactly one new commit on a's origin main, a squash commit (one parent) whose tree carries the VERSION; b's origin main and PR branch did not move; `gh pr view`: a MERGED, b OPEN; Foreman's per-repository PR state `merged,open`.
- `approve-merge --repo-id b --head-sha <tip>` and `merge --repo-id b`: one squash commit on b's origin main, carrying the VERSION, a's main not moved again; both PRs MERGED; no unsupported `gh` invocation in real-git mode; no stray worktree or worktree directory left under `~/.foreman/worktrees`.
  (b was merged with its check still FAILURE: the fake `gh` does not enforce checks, and neither did Foreman's gate; on real GitHub only branch protection would refuse it. Not a verdict on the product.)

## Findings

1. **The Overview "Pull requests" tab shows one PR for a two-repository run** (expected 2, got 1; both attempts). `Overview.Tabs.PullRequests.rows/1` builds one row per run from the primary's PR state (code reading; not changed here). The bead's acceptance 1 ("Overview shows both PRs") is unmet.
2. **A failing check on the non-primary PR is invisible once the primary PR merges** (expected the card `waiting_on_you`, got `resolved/pr_merged`; both attempts), although Foreman still watches b's PR as `failing`. `Overview.Group.classify/1` ranks `pr_state == :merged` before `ci_failing` and its input uses the primary's PR state (code reading). The bead's acceptance 3 is unmet. Suggested fix: classify per live PR across the run's repositories. Severity: medium (a run with an open, failing PR in a sibling repository is shown as resolved).
3. **`run fix-ci --pr <b's PR>` produced no commit (undetermined cause).** The command was accepted; Foreman asked the fake `gh` for the failing check's log; a fix jobsite started and completed within about 7 s; the PR row then showed `fixes.attempts.ci: 1`, `in_flight: null`, `last_outcome.ci: "no_change"`; nothing was pushed to b's branch in 600 s (both attempts), so the dependent assertions (new head has `CI_OK`, check SUCCESS, Foreman sees `passing`) failed. Whether the pi agent did nothing, or worked in the wrong checkout for a non-primary repository, could not be told from the output of the harness; a third attempt with `E2E_KEEP=1` and a look at the jobsite transcript is needed (two attempts were allowed).

## Not proven

Real GitHub (a real PR in each repository, a real failing check, real branch protection, `gh pr create` against github.com) and the fix leg of finding 3. The self-test and the stage exercise the fake `gh`, not Foreman's behaviour against GitHub's API.
