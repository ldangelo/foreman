# Claude Projects flow: live acceptance run (2026-10-21)

Honest transcript summary of one live run (bead E16-S8). Nothing below is marked PASS unless it was observed.

## Environment

- Real Foreman server (`mix phx.server`, dev env, Elixir 1.20.4) from branch `feat/cp-e16-live-acceptance` (origin/main 85259fd6 + this PR), throwaway Postgres DB `foreman_accept` (localhost:55432), port 47661, `HOME` redirected to `accept-scratch/home` (workflows, worktrees, secrets isolated from the operator's `~/.foreman`; `~/.pi` symlinked for provider auth).
- Providers: **real `pi` + `minimax/MiniMax-M2.7-highspeed`** for threads, coordinator and reviewer. Claude OAuth is expired (used as the "provider down" injector).
- Scratch repo: `foreman-wt/accept-scratch/work` (python app + unittest) with a **local bare `origin.git`**. No GitHub repo created, nothing pushed to GitHub.
- **FAKED: `gh`.** `scripts/e2e/fake-gh-for-acceptance.py` (first on the server's PATH) implements `pr create/list/view/merge` and `api graphql` against the bare repo; its "CI" really runs `python3 -m unittest` at the PR head; `pr merge` really squash-merges into the bare `main` and checks `--match-head-commit`. Every PR/CI/merge result below is therefore **UNVERIFIED against real GitHub**; Foreman's own code paths (AutoPR/PhasePR, PrMonitor, PrWatcher, auto-fix, merge gate, thread resolve) were real.
- Workflow: the bundled `fix` workflow needs `litellm-stack/smart_router` (unreachable) and an ensemble skill, so the isolated home uses a one-phase `fix.yaml` (`prompt: implement.md`, pi/minimax, `stack_pr: true`). Round 1 (bundled workflow) is recorded as failure F6.
- Notification sink: `acceptance-webhook-listener.py` on 127.0.0.1:47662 fed by `FOREMAN_NOTIFY_WEBHOOK_URL`.
- Helper scripts: `scripts/e2e/acceptance-start-server.sh` (env used), `fake-gh-for-acceptance.py`, `acceptance-webhook-listener.py`. CLI: `go build ./cmd/foreman` from this branch (`$F`), API token `accept-token`.

## Steps

| # | Step | Commands / endpoints | Observed | Result |
|---|------|----------------------|----------|--------|
| 1 | Create project, goal, instructions, memory, library | `$F project create --id accept --path <repo> --task-provider beads ...`; `project update --goal --instructions --coordinator-provider pi ... --max-concurrent-runs 3`; `project memory write --name house-style`; `project library add --name facts` | all accepted; `project get` shows settings | PASS |
| 2 | Three tasks in parallel, Overview groups | `$F project chat accept "<3 tasks>"`; `GET /api/projects/accept/overview`; LiveView `/dashboard/projects/accept?token=` (screenshots 02-04, 06) | coordinator started 3 threads; RunStarted for all three at 22:59:47Z (round 2) with completions 23:01:05/10/25 (overlapping); overview counts `working:3` for 23 consecutive 5 s samples; failed round-1 threads in Waiting on you with `Failure:` text | PASS (concurrency), per-project cap respected in step 7 |
| 3 | Steer a running thread | `$F thread steer --message ... run:<id>` | `RunPaused`/`RunSteerQueued`/`RunResumed`/`RunSteerConsumed`; the agent created `steer-marker.txt` = `STEERED-BY-OPERATOR` on the branch | PASS |
| 4a | PR opened per thread | stack_pr phase PR via fake gh | PRs #1-#10 created, branches pushed to bare origin | PASS (FAKED gh) |
| 4b | CI failure -> detection -> fix thread -> green | injector: commit breaking a function pushed to the PR branch (deterministic); PrMonitor (`FOREMAN_PR_MONITOR_ENABLED`), `pr_auto_fix` policy | PR #9: `checks_state failing` -> `PrFixRequested/Started` -> jobsite `js-730f97f208ea5d21` completed, commit `fix: restore absolute value in abs_diff` pushed, checks passing, `fixes.last_outcome.ci = pushed`. First attempts on PR #4 failed `image_missing` (docker sandbox default), see F8 | PASS (FAKED gh/CI); UNVERIFIED on real GitHub |
| 4c | Thread under Waiting on you while CI failing | - | not captured with a screenshot; PR #4 stayed in Ready for review with `checks_state failing` (Overview groups by PR gate, not CI state) | UNVERIFIED |
| 5 | Ready for review -> operator merge -> Resolved | `run approve-merge --approver ldangelo --identity github:ldangelo`, `run merge` | PR #6 squash-merged into bare `main` (`988def2`), `MergeGateApproved`, `PrMerged`, thread **Resolved** (PR merged). Before the fix (F9) no run ever reached Ready for review | PASS (FAKED gh) |
| 6 | Coordinator: status, proposal, start | `propose_before_start=true`; chat "status + propose abs_diff"; chat "go ahead" | proposal notice + `task.approve`; abs_diff thread ran. Status text was inaccurate (F7) | PASS (flow), status quality weak |
| 7a | Pause/resume | `project pause`, chat start, `project resume` | start rejected visibly `{:project_paused,"accept"}`; after resume the thread started | PASS |
| 7b | Notifications to webhook | local listener | 27 deliveries: 9 `failure`, 15 `run_update`, 3 `action_needed` (verdicts included) | PASS (webhook only; Telegram/Slack not exercised) |
| 7c | Library visible to an agent | `$FOREMAN_LIBRARY_PATH` facts file | agents wrote `7319-ZEBRA` into `notes-*.txt` (unknowable otherwise); reviewer independently confirmed | PASS |
| 7d | Memory injected into prompt | memory topic `house-style` | agents wrote `PINEAPPLE-42` into `notes-*.txt` | PASS |
| 7e | Review verdicts and usage | reviewer pi; `$F usage --project accept` | verdict MET with 4 scores recorded; usage by model 9.19M tokens, $0.9546 (per-thread cost not separately inspected) | PASS (partial) |
| 7f | LiveView page (screenshots, Library/PR/Scheduled tabs) | headless Chromium | Overview groups and PR tab render; **Library tab said "Not available yet." with a library present** (F10, fixed here) | PASS after fix |

## Failure injection

| Scenario | Expected | Actual | Result |
|----------|----------|--------|--------|
| Kill agent mid-run (`kill -9` pi of a thread) | run fails visibly | run `failed`, Waiting on you, failure notification, coordinator report; reason is opaque `{:other,:execution}` (F4) | PASS (visible), reason quality poor |
| Kill -9 server mid-run, restart | run resumes or fails visibly, no orphans | run re-attempted and failed `git_worktree_create_failed ... already exists`; orphaned pi agent kept running (F1) | FAIL (visible, not recovered) |
| Server restart with open coordinator turn | turn closed `interrupted`, re-run, no duplicate actions | UI showed "coordinator was interrupted mid-turn"; turn re-ran; task titles show only intended duplicates across rounds | PASS |
| Coordinator provider down (claude OAuth expired) | visible typed error, recovery without duplicate threads | 3 failures -> `unhealthy`, one system notice; after provider reset + `project chat --restart` it replied; no new threads | PASS |
| Exceed limits | rejected / deferred visibly | `instructions_too_long` 422, `goal_too_long` 422, `max_concurrent_runs_invalid` 422, message 413; cap=1 / daily cap 1 deferrals counted in `project settings`; daily-cap task re-admitted on settings change, **run-limit task never re-admitted** (F2) | PASS (rejections), FAIL (re-admission) |
| Denied tool | agent refused, run continues | **Not applicable: pi has no approvals/tool permission mechanism**; nothing to deny. Approval-gated path UNVERIFIED | UNVERIFIED |
| `br` unavailable for BeadSink | `bead_unresolved`, verdict still recorded | not run: coordinator tasks carry no bead id, so BeadSink is skipped (`review bead sink skipped: ... no originating bead` observed) | UNVERIFIED |

## Bugs found

Fixed in this PR (each with a regression test):

- **F9** `stack_pr` runs never got `PrAssociated`/`run.pr.ready` (`maybe_auto_pr` returned `:noop` when a phase PR existed), so the thread never reached the merge gate or PR watcher (Idle/no_pr). Fix: `RunExecutor` returns the latest phase PR; test in `run_executor_pr_ready_test.exs`.
- **F11** `GET /api/runs/:id`, `GET /api/runs` and `foreman run get` returned 500 once a worker reported usage (`%Usage{}` not Enumerable in `RunController.stringify_keys`). Test `run_controller_show_test.exs`.
- **F10** Library Overview tab never had a provider. New `Overview.Tabs.Library`; tests in `tabs_test.exs`, `project_workspace_live_test.exs`.
- Operability gaps closed with env vars (documented in `docs/user-guide.md`): `FOREMAN_HTTP_PORT`, `FOREMAN_NOTIFY_WEBHOOK_URL`, `FOREMAN_REVIEW_PROVIDER/MODEL`, `FOREMAN_PR_FIX_SANDBOX` (F8: fix threads default to a docker image `foreman-jobsite:<project>` that does not exist -> `image_missing`).

Filed as beads (no `foreman-exec` label): F1 `foreman-qxmye` (P1 crash recovery), F2 `foreman-s19h6` (run-limit deferral never re-admitted), F3 `foreman-qp5d3` (pi reviewer ignores read-only, auto-commits into project main), F4 `foreman-3r79u` (opaque `{:other,:execution}`), F5 `foreman-z4czv` (boot re-pauses finished steered runs), F6 `foreman-pv11k` (bundled workflows need litellm model), F7 `foreman-rkfxs` (coordinator status accuracy).

Open P1 defects after this run: F1, F3. Acceptance is therefore **not declared fully passed**.

## Not done

Telegram/Slack delivery, real GitHub (PR, CI, webhook, merge), `br`-down BeadSink scenario, denied-tool scenario, per-thread usage rows, full-suite run (only targeted tests: `run_controller_show_test`, `run_executor_pr_ready_test`, `overview/*`, `project_workspace_live_test`). Scripts `claude_projects_flow.sh` / `claude_projects_failures.sh` from the bead were not written; the run was driven by hand with the commands above.
