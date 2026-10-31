# Multi-repo PRs against real git origins (fake `gh`, real heads, merges and a check): live run, 2026-10-31

Bead `foreman-w0tnj` (parity-audit row C3, multi-repo on real GitHub). **Verdict: PARTIAL.** Real GitHub was NOT used (the task forbade a real repository), so
the bead's acceptance as written (a real GitHub PR in each of two repositories, a real failing GitHub check) is unmet. What was added is the closest local
stand-in, and running it exposed two product gaps against the bead's own acceptance statements and one unexplained failure of the fix thread. **All three were then fixed on this branch and the stage passes (`56 passed, 0 failed in 46s`): see "Re-run after the fixes" at the end; the sections above it are the original run, kept as history.**

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

The stage was therefore **red on this revision by design** when first run: its failing assertions encoded the bead's acceptance and the fix-leg expectation (below). It is a manual live script, not part of CI. The fixes below turned it green.

## Observed and passing (both attempts)

- Each PR is bound to the origin of its own repository; its recorded head equals the tip of the run branch on that origin; `gh pr view` shows `OPEN MERGEABLE`, the real tip and, for a, no checks; the VERSION file the agent wrote is on each head (`1.4.5`); the two heads are different commits.
- The Overview card is `ready_for_review/pr_ready` while the primary's PR is open and the gate pending.
- b's check `e2e-ci` is FAILURE on its real head; `PrMonitor.poll_now/0` observed both PRs; Foreman's watch shows `checks_state: failing` on b's PR and none on a's; the Overview card is `waiting_on_you/ci_failing`.
- `approve-merge` and `merge` of a alone: exactly one new commit on a's origin main, a squash commit (one parent) whose tree carries the VERSION; b's origin main and PR branch did not move; `gh pr view`: a MERGED, b OPEN; Foreman's per-repository PR state `merged,open`.
- `approve-merge --repo-id b --head-sha <tip>` and `merge --repo-id b`: one squash commit on b's origin main, carrying the VERSION, a's main not moved again; both PRs MERGED; no unsupported `gh` invocation in real-git mode; no stray worktree or worktree directory left under `~/.foreman/worktrees`.
  (b was merged with its check still FAILURE: the fake `gh` does not enforce checks, and neither did Foreman's gate; on real GitHub only branch protection would refuse it. Not a verdict on the product.)

## Findings

1. **The Overview "Pull requests" tab shows one PR for a two-repository run** (expected 2, got 1; both attempts). `Overview.Tabs.PullRequests.rows/1` built one row per run from the primary's PR state (verified by a failing test before the change). The bead's acceptance 1 ("Overview shows both PRs") was unmet. **FIXED** in `22b5bbfe` (one row per PR; a non-primary row carries `repo_id`).
2. **A failing check on the non-primary PR is invisible once the primary PR merges** (expected the card `waiting_on_you`, got `resolved/pr_merged`; both attempts), although Foreman still watches b's PR as `failing`. Verified by failing tests before the change: `Overview.Group.classify/1` ranks `pr_state == :merged` before `ci_failing` and its input came from the primary's PR alone, and, found on the way, `Overview.MergeResolver` resolved the thread (`resolved/resolved`, as attempt 2's card actually showed) on the primary's merge, which no classifier change could undo. The bead's acceptance 3 was unmet. Severity: medium. **FIXED** in `22b5bbfe` (the card and the resolver read the run's PRs as one: `Overview.PrFold.rollup/2`; the same commit fixes a dropped first non-primary PR event in `ProjectionStore.fold_pr_state/3`).
3. **`run fix-ci --pr <b's PR>` produced no commit (cause undetermined at the time).** The command was accepted; Foreman asked the fake `gh` for the failing check's log; a fix jobsite started and completed within about 7 s; the PR row then showed `fixes.attempts.ci: 1`, `in_flight: null`, `last_outcome.ci: "no_change"`; nothing was pushed to b's branch in 600 s (both attempts), so the dependent assertions (new head has `CI_OK`, check SUCCESS, Foreman sees `passing`) failed. `no_change` only means the PR head did not move after a completed jobsite (`PrWatcher.completed_outcome/2`). Cause found by reading and a failing test: `PrFix.plan/4` resumed the run's last provider session whenever the fix would run at the repository's original worktree path, but the run's agent works in the PRIMARY's worktree, so for a non-primary repository's PR the session was bound to another directory. **FIXED** in `163ec89a` (only the primary's PR resumes the session; another repository's fix starts a fresh agent with the context in its prompt). The live fix leg passes after the change (below); the cause was not re-proven by reverting the change in a live run.

## Not proven

Real GitHub (a real PR in each repository, a real failing check, real branch protection, `gh pr create` against github.com). The self-test and the stage exercise the fake `gh`, not Foreman's behaviour against GitHub's API. The fix of finding 3 is supported by a unit test that is red before and by one green live fix leg; the live run was not repeated with the change reverted, and the kept transcript of the fix jobsite was lost when the harness server was cleaned up (the run's own assertions are the evidence).

## Re-run after the fixes (2026-10-31)

Code under test: branch `fix/multi-repo-overview-w0tnj` pushed onto `docs/live-realgit-2026-10-31`: `d712fcf0` (D3, below), `163ec89a` (finding 3), `22b5bbfe` (findings 1 and 2), `78e45c72` (the stage now also asserts the card reason after a's merge, both Pull requests rows, and the resolved end state). Command (through the shared heavy lock, inside `devbox run --`):
`FOREMAN_VFS_ALLOWED_ROOT=<parent of the checkout> E2E_STAGES=realgit E2E_KEEP=1 sh scripts/e2e/multi_repo.sh` (attempt 1 of the 2 allowed).

| Run | Result |
|---|---|
| `realgit`, after the fixes | **`56 passed, 0 failed in 46s (provider=pi, model=minimax/MiniMax-M2.7-highspeed)`**, exit 0 (before: `46 passed, 7 failed in 623s`, exit 3) |
| `sh scripts/e2e/multi_repo/fake_gh_selftest.sh` | `passed=45 failed=0` |

What the re-run showed (all asserted by the stage): with both PRs open the Pull requests tab has 2 rows and the card is `ready_for_review/pr_ready`; with b's check failing the card is `waiting_on_you/ci_failing`; after a merged alone the card is STILL `waiting_on_you/ci_failing` (was `resolved`) and the tab lists both PRs (`merged,open`); `run fix-ci --pr <b>` pushed a new commit to b's origin branch after 27 s with `CI_OK` containing `ok` (check SUCCESS on the new head, Foreman observed `passing`); b then merged with the fix (one squash commit carrying `VERSION` and `CI_OK`; a's main not moved again); with both merged the card is `resolved` and both rows read `merged`.

Finding D3 (low) was not seen by this stage: `POST /webhooks/operator/ingest` answered 202 for a 201-character `question_id` that `question.open` then refused (`{:question_id_too_long, 201, 200}` in the server log only). Fixed in `d712fcf0`: the ingest checks the id with the aggregate's own check before anything is ingested and answers 422 `{"error": "{:question_id_too_long, 201, 200}"}` (the shape of `{:answer_too_long, ...}`; since changed to `{"error": "question_id_too_long", "length": 201, "max": 200}`); exactly 200 characters is still accepted. Proven by unit tests only (red before, green after), not by this stage.

Unit and suite evidence for the fixes: the new tests were red on the parent (17 of 77 in the three files that gained tests) and green after; the whole `foreman_server` suite: `6564 passed (8 properties, 6556 tests), 10 excluded`; `mix format --check-formatted`, `mix compile --force --warnings-as-errors` (test env), `mix compile --warnings-as-errors` (dev), `mix credo --min-priority higher` and `mix doctor --raise` are clean.
