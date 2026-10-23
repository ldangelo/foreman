# GitHub live run: real PR, checks, webhook, Fix CI, review, conflict, force-push, re-run, merge (2026-10-22)

Evidence for `foreman-ksy0q` (real GitHub paths) and the remaining E16-S8 acceptance gaps
(`foreman-nb8w2.9.1`, `.9.3`, `.9`). Everything below was observed against a **real private GitHub
repository** and a real, throwaway Foreman server; nothing is simulated except where marked.

## Environment

- Branch `test/github-live` off `origin/main` 77277173; macOS arm64; devbox Elixir 1.20.4 / OTP 28, Go, git 2.56.0, `br` 0.6.0,
  `pi` with **minimax/MiniMax-M2.7-highspeed** for every thread, fix thread, coordinator and reviewer
  (`FOREMAN_REVIEW_PROVIDER=pi`); `cloudflared` 2026.9.1 quick tunnel; `gh` token scopes `gist, read:org, repo, workflow`.
- **Scratch repo: `ldangelo/foreman-scratch-202610222007` (private; created for this run; archived at the end, to be
  deleted by the owner: the token has no `delete_repo`).** Seed: `scripts/e2e/claude_projects/github-fixture/` (a tiny
  Python app, two unit tests, `.github/workflows/ci.yml` running `python3 -m unittest -v`, `.gitignore`). No other repository was touched.
- Server: `MIX_ENV=dev` on a private Postgres database, own port, redirected `HOME` (so credentials travel in the
  environment: `GH_TOKEN`, a `GIT_CONFIG_*` credential helper that first *resets* the helper list, see "Harness defects"),
  `FOREMAN_PR_MONITOR_ENABLED=true` (polling stays on), `FOREMAN_PR_FIX_SANDBOX=host`, `FOREMAN_GITHUB_WEBHOOK_SECRET=<random>`.
- Foreman project registered over a **clone** of the scratch repo; all harness git work (failure injection, conflict, force-push)
  happens in a *separate* operator clone, never in the project checkout.

## Commands

```bash
# GitHub stage only (setup + stage 8, ~6 min):
FOREMAN_E2E_GITHUB_REPO=ldangelo/foreman-scratch-202610222007 E2E_GH_ONLY=1 \
  devbox run -- bash scripts/e2e/claude_projects_flow.sh
# Full flow, stages 1-8 (the final run below, 491 s):
FOREMAN_E2E_GITHUB_REPO=ldangelo/foreman-scratch-202610222007 devbox run -- bash scripts/e2e/claude_projects_flow.sh
devbox run -- bash scripts/e2e/failure_injection.sh                       # six scenarios incl. the new paused-project assertion
devbox run -- bash scripts/e2e/claude_projects_flow.sh                    # no env var: stage 8 prints SKIP + UNVERIFIED
```

## Result per path

| Path | Result | Evidence |
|---|---|---|
| PR created by a run (AutoPR) | **PASS** | stage 8b: PR `#6` opened from the run's branch `foreman/gh-qpe/run-...`, base `main`, diff contains the change |
| Check/CI watching (green) | **PASS** | 8c: Actions `success` on the head; `GET /api/runs/<id>/prs` carries the real PR url; card Ready for review |
| Failing check raises the thread to *Waiting on you* (#619 grouping) | **PASS** | 8e: injected failing test pushed; Overview card `group=waiting_on_you reason=ci_failing`, counts `waiting_on_you:1` |
| Fix CI (`run.pr.fix_ci`, CLI path) | **PASS** | 8e: fix commit `1e2950ec` pushed by the pi fix thread to the same branch, CI green, card back in Ready for review |
| Review-thread comment, then Address comments | **PASS** (with an observation) | 8f: review posted with `gh api` (1 unresolved thread on GitHub); `run.pr.address_comments` pushed `b877f0eb`, app.py gained the docstring, CI green. **Observation:** the card stayed Ready for review while the thread was unresolved (bead `foreman-v8wqe`) |
| Merge conflict, then Resolve conflicts | **PASS** | 8g: conflicting commit to `main` (proved conflicting with `git merge-tree` before pushing); GitHub `CONFLICTING`; card `waiting_on_you / conflict`; `run.pr.resolve_conflicts` -> `MERGEABLE` at `8b85840e`, CI green |
| Force-push handling | **PASS** | 8h: head `8b85840e -> e20d47b4`; Foreman's PR observation recorded the new head; CI ran and passed on it |
| Check re-run | **PASS** | 8h: `gh run rerun`, attempt 2 started and finished green |
| **Real webhook** through `cloudflared` | **PASS** | 8d: unsigned -> 401; wrong signature -> 401 `signature_mismatch`; `md5=` header -> 401 `signature_malformed`; correctly signed forged ping -> 202 `ignored`; hook `701930430` registered; GitHub's own ping answered 202. 8j: GitHub's delivery log for the whole stage: `check_run 202 x24; check_suite 202 x12; issue_comment 202 x5; ping 202 x2; pull_request 202 x5; pull_request_review 202 x1; pull_request_review_comment 202 x1`, zero non-2xx |
| Ready for review | **PASS** | 8c, 8e, 8i snapshots |
| Operator merge (`approve-merge` then `merge`, head-pinned) | **PASS after fix** | 8i: PR merged on GitHub, card `resolved / pr_merged`. First attempt FAILED: `head_moved_since_approval` (defect `foreman-axmni`, fixed, below) |
| Thread Resolved | **PASS** | 8i |
| Merge gate not reachable by agents | **PASS (partial)** | the Overview card's `actions` never contain a merge action; the merge ran only through the operator CLI path. MCP tool absence is covered by existing tests, not re-checked here |
| Branch protection | **UNVERIFIED** | `PUT /branches/main/protection` -> HTTP 403 "Upgrade to GitHub Pro or make this repository public" (private repo on this plan) |
| PR action **buttons** against real GitHub | **UNVERIFIED** | the CLI/command path was used; the LiveView buttons run the same commands (see `pr-actions-live-view.md`, fake gh) |
| Automatic `pr_auto_fix` policy | **UNVERIFIED** | only the operator-requested Fix CI was driven |

### Defects

- **`foreman-axmni` (P1, fixed here).** `RunPrMerge` pinned the merge to the head recorded by `PrReady` (once, when the PR is
  opened). After *any* later push (Fix CI, Address comments, Resolve conflicts, force-push) `approve-merge` was accepted but
  `merge` failed `422 head_moved_since_approval` (`d9ad2d68` approved vs `dc6de24d` live), and `merge_approve` cannot be repeated.
  So the PR actions made the PR unmergeable through the operator path. Fix: pin the head the PR watch had recorded when the gate
  was approved (events before the latest `MergeGateApproved`); the live-head check at merge is unchanged, so a push *after*
  approval is still refused. Tests: `run_pr_merge_test.exs` (2 new; real `PrUpdate.command/3` events). Mutation check: removing the
  pin call fails both. Still open at the time: after a post-approval push the gate could not be re-opened. Closed by
  `foreman-ehxy6`: `approve-merge` now names the head (`--head-sha`, checked against GitHub) and a push after approval
  voids the approval and re-holds the gate (see the user guide, `run approve-merge`); not re-run against live GitHub.
- **`foreman-v8wqe` (P3).** Unresolved review threads do not move a thread out of Ready for review.

### Harness defects found and fixed while writing the stage (not product defects)

1. `git push` from the server hung forever in `git credential-osxkeychain store` (system gitconfig names the keychain helper; the
   server's redirected `HOME` has no keychain). Fix: `GIT_CONFIG_*` env that first sets `credential.helper=` (reset), then the `gh` helper.
2. The first design reused the Foreman project checkout as the injector clone, so `git checkout` of the PR branch there made Foreman's
   fix thread fail `worktree_create_failed ... is checked out in the repository's main worktree`. Fix: a separate operator clone.
3. The first conflict injector appended at EOF/edited a distant line: no conflict. Now it edits the exact base line the PR's first hunk
   touches and `git merge-tree` proves the conflict before pushing.
4. Once during development the Foreman server received `SIGTERM` from outside the harness mid-stage (log: `SIGTERM received`); the
   stage now fails fast with that reason instead of timing out.

## Overview snapshots (stage 8, final run; thread `run:run-8ca5bac8...`, PR #6)

```text
== 8. GitHub (real repository ldangelo/foreman-scratch-202610222007) ==

== 8a. GitHub: project over a clone of ldangelo/foreman-scratch-202610222007 ==
  PASS        project e2e-gh-82304 registered over the clone of ldangelo/foreman-scratch-202610222007

== 8b. GitHub: a run opens a real PR ==
   thread run:run-8ca5bac85bb032846d8311f12ed633c6 from bead gh-qpe
  PASS        run finished (= completed)
   Overview snapshot: counts={"idle":0,"landing":0,"ready_for_review":1,"resolved":0,"waiting_on_you":0,"working":0} card={"thread_id":"run:run-8ca5bac85bb032846d8311f12ed633c6","group":"ready_for_review","reason":"pr_ready","pr_state":"ope ...
  PASS        the run opened a PR: https://github.com/ldangelo/foreman-scratch-202610222007/pull/6
  PASS        GitHub reports the PR open (= OPEN)
  PASS        PR head is the run's branch (= foreman/gh-qpe/run-8ca5bac85bb032846d8311f12ed633c6)
  PASS        PR base is main (= main)
  PASS        the PR diff contains the run's change
   card: {"group":"ready_for_review","reason":"pr_ready","pr_state":"open","merge_gate":"pending","status":"completed"}

== 8c. GitHub: Foreman watches the real checks (green) ==
  PASS        GitHub Actions reports the PR head green: f3e58f74541098f480a7d6648570b5eee6b214b3
   Overview snapshot: counts={"idle":0,"landing":0,"ready_for_review":1,"resolved":0,"waiting_on_you":0,"working":1} card={"thread_id":"run:run-8ca5bac85bb032846d8311f12ed633c6","group":"ready_for_review","reason":"pr_ready","pr_state":"ope ...
  PASS        Overview: thread is Ready for review once checks pass ({"group":"ready_for_review","reason":"pr_ready","pr_state":"open","merge_gate":"pending","status":"completed"})
   GET /api/runs/run-8ca5bac85bb032846d8311f12ed633c6/prs: {"run_id":"run-8ca5bac85bb032846d8311f12ed633c6","prs":[{"status":"open","pr_url":"https://github.com/ldangelo/foreman-scratch-202610222007/pull/6","base_branch":"main","head_sha":" ...
  PASS        the run's PR association carries the real PR url

== 8d. GitHub: a REAL webhook through a cloudflared tunnel ==
   tunnel https://caribbean-fitted-poly-neo.trycloudflare.com -> 127.0.0.1:4810 (pid 70473)
  PASS        unsigned delivery through the tunnel is rejected (= 401)
  PASS        a wrong signature is rejected as signature_mismatch (401)
  PASS        ...with HTTP 401
  PASS        a malformed signature header is rejected (401 signature_malformed)
  PASS        a correctly signed delivery is accepted (202 ignored: not a PR event)
   good delivery body: {"status":"ignored"} 202
  PASS        webhook 701930430 registered on ldangelo/foreman-scratch-202610222007 -> https://caribbean-fitted-poly-neo.trycloudflare.com/webhooks/github
  PASS        GitHub's ping delivery was answered 202,202 (signature verified by Foreman)

== 8e. GitHub: a FAILING check -> Waiting on you -> Fix CI ==
   injected failing commit c1680dba177e0af126005bbf4780751c8f0f41c9 (deterministic injector: a git push of a failing test, not an agent mistake)
  PASS        GitHub Actions reports the check FAILED on c1680dba177e0af126005bbf4780751c8f0f41c9
   Overview snapshot: counts={"idle":0,"landing":0,"ready_for_review":1,"resolved":0,"waiting_on_you":1,"working":0} card={"thread_id":"run:run-8ca5bac85bb032846d8311f12ed633c6","group":"waiting_on_you","reason":"ci_failing","pr_state":"ope ...
  PASS        Overview: the thread is in Waiting on you: {"group":"waiting_on_you","reason":"ci_failing","pr_state":"open","merge_gate":"pending","status":"completed"}
  PASS        ...for reason ci_failing (= ci_failing)
  PASS        ...and Fix CI is offered by the PR actions
  PASS        run.pr.fix_ci accepted: {   "result": {     "run_id": "run-8ca5bac85bb032846d8311f12ed633c6",     "task_id": "beads:e2e-gh-82304:gh-qpe"   },   "status": "accepted" } 
  PASS        a fix commit landed on the PR branch: 1e2950ec58d2d53d38402e885f5acfcfe34b87a4
  PASS        CI is green again on the fixed head
   Overview snapshot: counts={"idle":0,"landing":0,"ready_for_review":2,"resolved":0,"waiting_on_you":0,"working":0} card={"thread_id":"run:run-8ca5bac85bb032846d8311f12ed633c6","group":"ready_for_review","reason":"pr_ready","pr_state":"ope ...
  PASS        Overview: back in Ready for review after the fix: {"group":"ready_for_review","reason":"pr_ready","pr_state":"open","merge_gate":"pending","status":"completed"}

== 8f. GitHub: a review-thread comment -> Address comments ==
  PASS        review comment posted on app.py:8 via gh api
  PASS        GitHub shows one unresolved review thread (= 1)
   card after the review comment (Foreman observation): {"group":"ready_for_review","reason":"pr_ready","pr_state":"open","merge_gate":"pending","status":"completed"}
   run prs: {"run_id":"run-8ca5bac85bb032846d8311f12ed633c6","prs":[{"status":"open","pr_url":"https://github.com/ldangelo/foreman-scratch-202610222007/pull/6","base_branch":"main","head_sha":"1e2950ec58d2d53d38402e885f5acfcfe34b87a4","chec ...
  PASS        run.pr.address_comments accepted
  PASS        the agent pushed a commit addressing the comment: b877f0eba5a5ac8f4a35497080347b6bdfe33dce
  PASS        app.py now documents subtract()
  PASS        CI green after addressing comments

== 8g. GitHub: merge conflict -> Resolve conflicts ==
  PASS        pushed a conflicting commit to main of ldangelo/foreman-scratch-202610222007 (merge-tree proves it conflicts with the PR)
  PASS        GitHub reports the PR as CONFLICTING
   Overview snapshot: counts={"idle":0,"landing":0,"ready_for_review":1,"resolved":0,"waiting_on_you":1,"working":0} card={"thread_id":"run:run-8ca5bac85bb032846d8311f12ed633c6","group":"waiting_on_you","reason":"conflict","pr_state":"confl ...
  PASS        Overview: Waiting on you for reason conflict: {"group":"waiting_on_you","reason":"conflict","pr_state":"conflicted","merge_gate":"pending","status":"completed"}
  PASS        run.pr.resolve_conflicts accepted
  PASS        the agent resolved the conflict: GitHub reports the PR MERGEABLE (head 8b85840e57f38e7807cb9f7ee8eb0ad495f51e56)
  PASS        CI green on the conflict-resolved head

== 8h. GitHub: force-push of the PR branch and a check re-run ==
  PASS        force-pushed the PR branch: 8b85840e57f38e7807cb9f7ee8eb0ad495f51e56 -> e20d47b464fdbaa97737f917ceae1ea7bd3b3457
  PASS        Foreman's PR observation tracks the force-pushed head e20d47b464fdbaa97737f917ceae1ea7bd3b3457
  PASS        CI ran and passed on the force-pushed head
  PASS        re-run of check run 39890149076 requested
  PASS        GitHub started attempt 2 of run 39890149076
  PASS        the re-run finished green

== 8i. GitHub: Ready for review, then the OPERATOR merge path ==
   Overview snapshot: counts={"idle":0,"landing":0,"ready_for_review":2,"resolved":0,"waiting_on_you":0,"working":0} card={"thread_id":"run:run-8ca5bac85bb032846d8311f12ed633c6","group":"ready_for_review","reason":"pr_ready","pr_state":"ope ...
  PASS        Overview: Ready for review: {"group":"ready_for_review","reason":"pr_ready","pr_state":"open","merge_gate":"pending","status":"completed"}
  PASS        the card offers no merge action (the gate is operator-only CLI/HTTP)
  PASS        operator approve-merge accepted: {   "result": {     "raw": "%{\"event_type\" =\u003e \"MergeGateApproved\", \"payload\" =\u003e %{\"approved_at\" =\u003e 1792722790493, \"approver\" =\u003e \"
  PASS        operator run merge accepted: {   "result": {     "run_id": "run-8ca5bac85bb032846d8311f12ed633c6",     "task_id": "beads:e2e-gh-82304:gh-qpe"   },   "status": "accepted" } 
  PASS        GitHub reports the PR MERGED (= MERGED)
   Overview snapshot: counts={"idle":0,"landing":0,"ready_for_review":1,"resolved":1,"waiting_on_you":0,"working":0} card={"thread_id":"run:run-8ca5bac85bb032846d8311f12ed633c6","group":"resolved","reason":"resolved","pr_state":"merged","me ...
  PASS        Overview: the thread is Resolved ({"group":"resolved","reason":"resolved","pr_state":"merged","merge_gate":"approved","status":"completed"})

== 8j. GitHub: webhook delivery handling over the whole stage ==
   GitHub's delivery log: check_run -> 202 x24; check_suite -> 202 x12; issue_comment -> 202 x5; ping -> 202 x2; pull_request -> 202 x5; pull_request_review -> 202 x1; pull_request_review_comment -> 202 x1
  PASS        GitHub delivered check_run events that Foreman answered 202
  PASS        no delivery was refused or failed (a 401/5xx would mean a signature or handling problem) (= 0)
  PASS        no server-side handling crash is logged for webhook deliveries
   scratch repo main restored to 815c05c81c8024f131188db49fda27aba84966b1

== summary ==
   passed=100 failed=0 unverified=1 wall=491s
   UNVERIFIED:
  - approve/deny a tool call and answer an agent question (pi has no tool-permission or ask mechanism, so no approval or question is ever raised; only the empty list surfaces are checked)
   scratch repo main restored to 815c05c81c8024f131188db49fda27aba84966b1
   sweep: killing stray process 95792 (cwd inside /Users/ldangelo/Development/Fortium/foreman-wt/ghlive/tmp/e2e-claude-projects-cp): sleep 600
exit=0
```

## failure_injection.sh (all six scenarios, final run)

```text
== setup: scratch repo, br database, database, notification sink, server ==
== scenario provider-down ==
  PASS        chat against a down provider fails visibly (exit 3, not a silent success)
  PASS        conversation records a typed unhealthy/error notice
  PASS        no thread was created while the provider was down (= 0)
  PASS        after restore + restart the coordinator answers (exit) (= 0)
  PASS        coordinator answered
  PASS        recovery served the queued request at most once (1 thread(s) for hello.txt): no duplicates
  PASS        run with a nonexistent model ended 'failed'
  PASS        run failure carries a recorded reason: "{:provider_model_preflight_failed, [%ForemanServer.Workflow.PreflightFailure{phase: \"edit\", provider: :pi, class: :model_not_found, model: \"min ...
== scenario agent-crash ==
  PASS        kill -9 sent to the agent processes of run run-17319be03a8522d613a23c18ebef04f1 (pids 22870 )
  PASS        run after agent kill (= failed)
  PASS        agent kill recorded a reason: "{:other, :execution}: execution: pi: %{\"exit_status\" => 137, \"reason\" => \"{:exit_status, 9}\"}"
  PASS        thread status after the kill (= failed)
  PASS        Overview shows the failed thread under Waiting on you (= 1)
  PASS        a failure notification reached the webhook sink
== scenario coordinator-crash ==
  PASS        coordinator project worker killed mid-turn (KILLED #PID<0.1081.0>)
  PASS        coordinator answers after the crash (exit) (= 0)
  PASS        the requested thread exists exactly once after the crash (0 = request lost, 2 = duplicate actions) (= 1)
== scenario server-crash ==
  PASS        agent orphaned to pid 1 after the crash (pids 45509)
  PASS        run resumed after the crash: a fresh agent (pids 51833 53020 ) is running in its worktree
  PASS        restart did not fail the run with 'worktree already exists'
  PASS        OrphanReaper terminated the orphaned agent(s)
  PASS        server log records the reap
== scenario project-paused ==
  PASS        before-pause thread run-687207980463e9befc1b7430654ba9de is running (status in_progress)
  PASS        project pause accepted
  PASS        project reads back paused (= paused)
  PASS        no thread started for the bead while paused (= 8)
  PASS        no thread started through the coordinator while paused (= 8)
  PASS        the thread running at pause time still completed while the project was paused (= completed)
  PASS        project was still paused when that thread completed (= paused)
  PASS        the paused-project thread delivered its file (= RUNNING)
  PASS        project resume accepted
  PASS        after resume the held bead started thread run:run-0341bdd6fa13987eb0938e1d3b0e08d2 (not lost)
== scenario br-down ==
  PASS        thread completed while br was down (= completed)
  PASS        review verdict recorded while br was down: met
  PASS        the bead-sink failure is visible in the recorded summary
  PASS        no review comment landed on the bead
== summary ==
   passed=36 failed=0 unverified=0 wall=283s
exit=0
```

The new assertion (E16-S8-T2 gap): a thread that is `in_progress` when the project is paused must still complete while the project
is paused; it is checked three ways (run `completed`, project still `paused`, the thread's file is on its branch).
**Mutation check:** a copy of the script that `run cancel`s that thread right after the pause fails exactly those assertions:

```text
== setup: scratch repo, br database, database, notification sink, server ==
== scenario project-paused ==
  PASS        before-pause thread run-633ae051b71d297fb5d9521d704f53c8 is running (status in_progress)
  PASS        project pause accepted
  PASS        project reads back paused (= paused)
  PASS        no thread started for the bead while paused (= 1)
  PASS        no thread started through the coordinator while paused (= 1)
  FAIL        the thread running at pause time still completed while the project was paused: expected 'completed', got 'cancelled'
  PASS        project was still paused when that thread completed (= paused)
  FAIL        the paused-project thread delivered its file: expected 'RUNNING', got ''
  PASS        project resume accepted
  PASS        after resume the held bead started thread run:run-a238ecce1aa59884d5c368a383088f05 (not lost)
== summary ==
exit=3
```

The first live attempt of this scenario (before the final run) FAILED: the before-pause thread stayed `in_progress` for 600 s and a
later `project resume` returned a `DBConnection.ConnectionError` ("connection not available", shared Postgres under load from other
agents). The cause of the stall is **not captured** (UNVERIFIED); three later runs of the same scenario (one standalone, one in the full
run, one as the mutation baseline) passed.

## Explicit SKIP path

```text
  SKIP        GitHub stage: FOREMAN_E2E_GITHUB_REPO is not set (set it to a private <owner>/foreman-scratch-<suffix> repo to run it)
  UNVERIFIED  real GitHub paths (PR create, CI/review watching, webhook, Fix CI, conflicts, force-push, re-run, merge) -- FOREMAN_E2E_GITHUB_REPO not set
   passed=0 failed=0 unverified=1 wall=5s
   UNVERIFIED:
exit=0
```

## Not covered / UNVERIFIED

Branch protection (HTTP 403); the PR action buttons and the automatic `pr_auto_fix` policy against real GitHub; MCP absence of a merge
tool was not re-probed; the cause of the one stalled paused-project run; claude provider paths (unchanged, out of scope); pi still has no
approval/ask mechanism (stage 5 UNVERIFIED, unchanged).

## Bead status

`foreman-ksy0q`: every named path exercised except branch protection; left open for that. `foreman-nb8w2.9.1`: GitHub stage and
deterministic failure injector delivered (existing scratch repo via `FOREMAN_E2E_GITHUB_REPO` instead of `gh repo create`, by the
user's one-repo rule). `.9.3`/`.9`: transcripts committed here; `foreman-axmni` (P1) is fixed in this PR and must merge before sign-off.
