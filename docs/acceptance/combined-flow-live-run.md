# Combined live flow: three tasks, three PRs, CI failure and fix, merge, usage, failure injection (2026-10-23)

Evidence for the acceptance text of `foreman-nb8w2.9` (E16-S8): the whole Claude-doc flow in **one stack**, GitHub stage on,
then the failure-injection pass. The earlier write-ups prove the pieces (`three-task-overlap-live-run.md`, `github-live-run.md`,
`claude-projects-acceptance-2026-10-22.md`); this one runs them together once. Everything below was observed against a real private
GitHub repository and a real, throwaway Foreman server; nothing is simulated.

## Environment

- Foreman `origin/main` at `bb939cd0` plus the script change described below. macOS arm64; devbox Elixir 1.20.4 / OTP 28,
  Go 1.27.3, git 2.56.0, `br` 0.6.0, `pi` 1.4.0, `gh` 2.103.0, `cloudflared` 2026.10.3.
- Provider: `pi` with `minimax/MiniMax-M2.7-highspeed` for every thread, fix thread, coordinator and reviewer
  (`FOREMAN_REVIEW_PROVIDER=pi`). `claude` was not used.
- **Scratch repository**: `<owner>/foreman-scratch-202610231701`, created private for this run, seeded from
  `scripts/e2e/claude_projects/github-fixture/` (tiny Python app, unit tests, `.github/workflows/ci.yml` running
  `python3 -m unittest`), kept private for its whole life (no visibility change, no branch protection), **deleted at the end of
  the run** (`gh repo delete`). The PR links below therefore no longer resolve.
- Stack: `MIX_ENV=dev`, private Postgres databases (pool size 4, dropped afterwards), random high ports, redirected `HOME`,
  `FOREMAN_PR_MONITOR_ENABLED=true`, real `cloudflared` quick tunnel with a signed webhook, local HTTP notification sink
  (`notification_preference=every_turn`).

## Commands

```bash
# the combined flow: stages 1-7 on the local scratch repo, then stage 8 with three PRs (about 6 min)
FOREMAN_E2E_GITHUB_REPO=<owner>/foreman-scratch-202610231701 E2E_GH_THREE_PRS=1 \
  devbox run -- bash scripts/e2e/claude_projects_flow.sh
# the failure injection (all scenarios, about 8 min)
devbox run -- bash scripts/e2e/failure_injection.sh
devbox run -- bash scripts/e2e/failure_injection.sh br-down        # one reproduction
```

The flow ran twice. Run 1 finished `passed=137 failed=3 unverified=2` (438 s): the three FAILs were all one defect in the **new
usage-per-thread assertion** of this change (it looked for `run:<id>` while the report prints `<id>`; the report itself listed all
three threads). The assertion was fixed and the same flow re-run on the same scratch repo (open PRs closed first): run 2 is the
reference below, `passed=141 failed=1 unverified=2` (363 s). Everything else matched between the two runs. The failure injection
ran at the same time as run 1 against its own database and port.

## What changed in the script (and nothing else)

`scripts/e2e/claude_projects_flow.sh` already covered steps 1, 2, 3, 5b, 7 and the notification sink on the local repo, and stage 8
drove **one** run-opened PR from a bead. It could not express "three threads each open a PR". The minimum change, in
`scripts/e2e/claude_projects/github.sh`, opt-in by `E2E_GH_THREE_PRS=1` (default off: stage 8 behaves exactly as before):

- `gh_stage_three_prs` replaces `gh_stage_pr_create`: sets the GitHub project to `max_concurrent_runs=3` and
  `notification_preference=every_turn`, pastes ONE coordinator message with three items (A: `subtract` plus a test in `app.py`/`test_app.py`,
  B and C: one new file each), asserts exactly three threads, a real PR per thread (open, head = the thread's branch, diff contains
  the change), three distinct PRs, and the same interval/overlap/cap assertions as step 5b. Thread A's PR is the one the later
  stages break, fix and merge.
- `gh_stage_notifications` (after the merge): the other two PRs are Ready for review, the sink received deliveries, a "PR ready for
  review" delivery exists, `foreman usage --by thread` lists all three threads, and no thread is left Working.
- With `E2E_GH_THREE_PRS=1` the optional stages 8f-8h (address comments, resolve conflicts, force-push and re-run) are recorded
  `UNVERIFIED` instead of run: they are not part of the acceptance text and have their own run (`github-live-run.md`).

## Result per step of the acceptance text

| # | Step | Result | Evidence (run 2) |
|---|---|---|---|
| 1 | Scratch repo with a CI workflow that can fail | **PASS** | private repo seeded from the fixture; Actions `success` on every PR head, then `failure` on the injected failing test |
| 2 | `project create` + instructions + memory note (+ library) | **PASS** | goal/instructions/`max_concurrent_runs` read back; memory topic and library file written and listed; a thread from a bead produced `notes.txt` carrying the memory token, the library token and the instruction token |
| 3 | Three tasks pasted in ONE coordinator message: three threads, overlapping runs, cap respected | **PASS** (twice: local repo and GitHub project) | exactly three threads with the three requested titles; local intervals below; peak 3 simultaneous runs, cap 3 |
| 4a | EACH of the three threads opens a PR | **PASS** | three distinct PRs from three run branches, each open, head = the thread's branch, diff contains that thread's change |
| 4b | One PR gets a CI failure, PrWatcher detects it, Overview shows Waiting on you | **PASS** | failing test pushed to PR A's branch; Actions `failure`; Overview card `group=waiting_on_you reason=ci_failing`; counts `ready_for_review:2 waiting_on_you:1` |
| 4c | A fix thread runs on the same branch (bounded), CI goes green | **PASS** | `fm run fix-ci` accepted; one fix attempt (`PrFixRequested kind=ci attempt=1`, `PrFixStarted`, `PrFixFinished outcome=pushed`) pushed `41b04818` to the same branch; Actions `success`; card back to Ready for review |
| 5a | Thread reaches Ready for review | **PASS** | all three cards `group=ready_for_review reason=pr_ready merge_gate=pending` with green checks |
| 5b | Notification sink fires | **PASS (partial, see 5c)** | the sink received 10 deliveries on the local-repo part (flow step 6: 9 `run_update`, 1 `action_needed`) and 10 more during stage 8 (review verdicts of the runs and of the fix thread, two CI-failed deliveries) |
| 5c | A "PR ready for review" notification | **FAIL** | none delivered: an auto-PR run's stream is `RunStarted, PrReady, RunCompleted, PrUpdated, PrChecksChanged`; the notifier row "PR ready for review" is keyed on `PrCreated`, which only `run.pr.create` emits. Bead `foreman-ehz7l` |
| 6 | Operator `approve-merge --head-sha <live head>` then `merge` -> Resolved | **PASS** | head read from GitHub (`41b0481835d9...`), `MergeGateApproved`, then `PrMerged`; GitHub reports MERGED; card `group=resolved reason=resolved merge_gate=approved`; the card offered no merge action before |
| 7 | Usage per thread | **PASS** | `foreman usage --project <gh project> --by thread --format json` lists all three threads (two events each, tokens and cost per thread); the local project's `by_model` report exits 0 |
| - | Review archive and verdict (flow step 7) | **PASS** | seven archive files; verdict `met` (correctness 4, documentation 3, robustness 4, tests 3); verdict posted as a bead comment |
| - | Real webhook through the tunnel | **PASS** | unsigned 401, wrong signature 401, malformed 401, signed 202, GitHub ping 202 x2; deliveries `check_run -> 202 x8`, `check_suite x4`, `issue_comment x2`, `pull_request x3`, none refused |
| - | Approvals/questions surfaces | **UNVERIFIED** | pi has no tool-permission or ask mechanism; only the empty list surfaces are checked (unchanged) |
| - | Address comments, resolve conflicts, force-push, check re-run | **UNVERIFIED here** | skipped by `E2E_GH_THREE_PRS=1`; verified in `github-live-run.md` |

Overall run 2: `passed=141 failed=1 unverified=2`; the one FAIL is 5c (a product gap, left in the script on purpose).

## The runs' intervals

Event-store `RunStarted` to first terminal event (`scripts/e2e/claude_projects/run_interval.exs`); two runs overlap when
`start_i < finish_j and start_j < finish_i`.

Step 5b, local repo (coordinator paste of three tasks):

| Thread | Start | Finish | Ran |
|---|---|---|---|
| `todo A` | +0.0 s | +43.2 s | 43.2 s |
| `todo B` | +0.0 s | +10.7 s | 10.7 s |
| `todo C` | +0.0 s | +10.7 s | 10.7 s |

3 overlapping pairs, peak 3 simultaneous runs, project cap 3. Each thread's file was compared exactly with its expected word on
its own branch.

Stage 8b, GitHub project (three PRs):

| Thread / PR | Start | Finish | Ran |
|---|---|---|---|
| `prs A` (`subtract`), PR #6 | +0.0 s | +11.2 s | 11.2 s |
| `prs C` (new file), PR #5 | +0.0 s | +8.5 s | 8.5 s |
| `prs B` (new file), PR #4 | +0.0 s | +8.2 s | 8.2 s |

3 overlapping pairs, peak 3, cap 3. All three runs started within one second (the first run's raw start stamps were within 18 ms).
The runs are short because the tasks are tiny; overlap is therefore proven by the common start, not by long durations.

Run 1 (same flow, assertion defect) gave the same shapes: local 94.2 / 88.5 / 9.9 s and GitHub 14.8 / 8.7 / 8.5 s, peak 3 both times,
PRs #1-#3 (two closed unmerged, one merged).

## Failure injection

`scripts/e2e/failure_injection.sh`, all seven scenarios, `passed=31 failed=2 unverified=1` (456 s):

| Scenario | Result | Actual |
|---|---|---|
| provider-down | **PASS** | typed error in the conversation, no thread, recovery after the provider returns, no duplicate |
| agent-crash | **PASS** | `kill -9` of the agent mid-run: run failed with a typed reason, no worktree left claiming to run |
| coordinator-crash | **PASS** | next message answered, one set of actions |
| server-crash | **PASS** + **UNVERIFIED** | restart resumes or fails visibly, no "worktree already exists"; "OrphanReaper on a real orphan" UNVERIFIED because the agent died with the server on this host (no orphan to reap), as in `foreman-e01a1` |
| port-closed | **FAIL** (1 assertion) | the run failed `:port_closed` and no agent was left running (PASS), but the assertion "server log records the reap" fails: the agent dies with its exec-port, so the reaper has nothing to log. Pre-existing: `foreman-e01a1` (commented) |
| project-paused | **PASS** | typed rejection while paused, the running thread finished, resume restores admissions |
| br-down | **FAIL** once, then **PASS** | in the all-scenarios run: "no thread appeared for the br-down bead". The same scenario re-run alone: 4/4 PASS (thread completed, verdict `met` recorded, bead-sink failure visible, no comment on the bead). Not root-caused: `foreman-3ll3t` |

The failure injection ran concurrently with the flow (separate database, port and work dir); that load is a possible, unproven factor
in the single br-down failure.

## Known flaky points

Neither occurred in these two runs: `foreman-2onq1` (empty branch files once in step 5b) and `foreman-ig27o` (no threads after the
paste once; the paste helper's second-paste nudge did not trigger).

## Defects and beads

| Finding | Bead |
|---|---|
| No "PR ready for review" notification on the auto-PR path (`PrReady` unmapped) | `foreman-ehz7l` (new) |
| `br-down` scenario: no thread appeared once, not reproduced | `foreman-3ll3t` (new) |
| `port-closed` assertion fails (no orphan to reap), `server-crash` orphan UNVERIFIED | `foreman-e01a1` (existing, commented) |
| Usage-by-thread assertion looked for `run:<id>` | not a product defect; fixed in this change |

## Not exercised

Address comments, resolve conflicts, force-push and re-run in the combined run; merge under branch protection (`foreman-ksy0q`, the
repository stayed unprotected by decision); claude as provider; Telegram/Slack; the Foreman server restarting during the GitHub stage.
