# Three tasks in one message, run in parallel: live run (bead `foreman-nb8w2.9.1`), 2026-10-23

`scripts/e2e/claude_projects_flow.sh` step 5b: one coordinator message pastes a to-do list of three distinct small tasks. The step
asserts the coordinator started exactly three threads, each delivered its file on its branch, and that at least two of the three runs
overlapped in time. Tree: `origin/main` at `a1ef92da` plus this change. Provider: `pi` on `minimax/MiniMax-M2.7-highspeed` for the
coordinator, the threads and the reviewer. Private stack: own port, own Postgres database, own scratch repo and `br` database;
no GitHub (stage 8 prints `SKIP`, counted as UNVERIFIED).

## What the step does

1. `overlap_selftest` (`claude_projects/overlap.sh`): the interval helpers must report no overlap for serial and merely touching
   intervals, find a real overlap, report the right peak and ignore an unfinished run. It is stack-free
   (`bash scripts/e2e/claude_projects/overlap.sh`) and also runs at the start of the step. Writing it caught a real defect in the first
   draft of the helper (an uninitialised awk counter dropped the first interval, so a real overlap read as none).
2. Waits until the project has no active run, so the project cap and the global slots are free.
3. Pastes (`foreman project chat -m`): "start one thread for each of the three items ... titled `e2e-<pid> todo A|B|C`", then items A, B and
   C, each "create a file `alpha|bravo|charlie-<pid>.txt` containing exactly the single word ...". `project chat` can return on the
   coordinator's answer to an earlier system report (a finished review), before the turn for this message, so the step polls the project's
   threads (up to 240 s) instead of trusting the chat output; if none appeared it sends the same paste once more and records an UNVERIFIED line.
4. Asserts: exactly three threads with three distinct titles; each reaches `completed`; each branch file equals its word exactly (one trailing
   newline allowed; the self-test probes `ALPHA-7` and `ALPHA-7\n` pass, `ALPHA -7`, `ALPHA-7\n\n extra`, `ALPHA-7 \n` and empty fail); a
   re-count after the runs still finds exactly three threads (the self-test stubs a fourth matching thread and checks it is counted).
5. Reads `RunStarted` and the first terminal event of each thread's run from the event store (`claude_projects/run_interval.exs`, evaluated
   on the server node; the run projection only keeps `started_at_ms` and a `last_event_at_ms` that any later event moves), prints the
   intervals, and asserts `start_i < finish_j and start_j < finish_i` for at least one pair, and that the peak number of simultaneous runs
   does not exceed the project cap.

How parallelism is allowed: the flow sets the project's `max_concurrent_runs` to 3 in step 1, the global RunSlots `max_concurrent_runs`
default is 3 (`config/config.exs`), and `coordinator_max_active_threads` is unset (no coordinator cap). `max_threads_per_turn` is 5.
No server configuration beyond the harness's existing one was needed.

## Result of the complete flow (stages 1-7, no GitHub stage)

`devbox run -- bash scripts/e2e/claude_projects_flow.sh` (script after the first review round; its file check still ignored spaces and newlines): `passed=67 failed=0 unverified=2`, exit 0.
UNVERIFIED: approve/deny a tool call and answer an agent question (pi has no permission or ask mechanism), and the GitHub stage (no scratch
repo configured). An earlier complete run of the pre-review script was `passed=66 failed=0 unverified=2`; a step-5b-only run
(`E2E_THREE_ONLY=1`) after the second review round (exact content with one trailing newline allowed, probes below) was `passed=31 failed=0
unverified=0`.

Step 5b, as printed (19 PASS):

| Check | Result |
|---|---|
| overlap self-test (5 assertions) | PASS |
| no run of the project active before the paste | PASS |
| coordinator chat with the three-item paste exits 0 | PASS |
| coordinator started exactly three threads | PASS |
| three distinct titles | PASS |
| each of the 3 threads reached `completed` | PASS (3) |
| each branch holds exactly its requested word (`ALPHA-`, `BRAVO-`, `CHARLIE-<pid>`) | PASS (3) |
| still exactly three threads after the runs finished | PASS |
| start and finish read for all three runs | PASS |
| at least two runs overlapped | PASS (3 pairs) |
| project cap respected (peak 3 <= 3) | PASS |

```
run-01c7eff214982d8e437dacefb538d045 1792787315342 1792787412217 RunCompleted
run-d0314206f4f8f5eb90518c262887b121 1792787315332 1792787634565 RunCompleted
run-3d815711fd9541a0bfcaad6111ea803c 1792787315324 1792787324307 RunCompleted
run-01c7eff214982d8e437dacefb538d045  start +0.0s  finish +96.9s   (ran 96.9s)
run-d0314206f4f8f5eb90518c262887b121  start +0.0s  finish +319.2s  (ran 319.2s)
run-3d815711fd9541a0bfcaad6111ea803c  start +0.0s  finish +9.0s    (ran 9.0s)
overlapping pairs: 3 of 3 ; peak simultaneous runs: 3 ; project cap: 3
```

All three `RunStarted` events are within 18 ms of each other (epoch milliseconds above). Run lengths vary a lot with the model (an earlier
run of the pre-review script printed 22.1 s, 15.3 s and 8.6 s); the starts do not.

## The assertion can fail

- Unit-style probe: `bash scripts/e2e/claude_projects/overlap.sh` feeds serial (`1000-2000, 2000-3000, 3500-4000`), touching and
  overlapping intervals and an unfinished run to the helpers; serial and touching report no overlap, the overlap is found.
- Live, forced serial: `E2E_THREE_ONLY=1 E2E_THREE_TASK_MAX_RUNS=1` sets the project's `max_concurrent_runs` to 1 for the step. The same three
  threads were created and all completed, but the runs ran one after another (`passed=22 failed=1`, exit 3):

```
run-2f7b0e43d6ad6979af178e5abb137f36  start +0.0s   finish +8.4s    (ran 8.4s)
run-520d0e6fe9ce419208c3bd531d796179  start +8.4s   finish +37.1s   (ran 28.6s)
run-64f70b62bbd3365dafd56cf182da0352  start +37.1s  finish +121.3s  (ran 84.2s)
overlapping pairs:  ; peak simultaneous runs: 1 ; project cap: 1
FAIL  no two of the three runs overlapped: they ran serially (start_i < finish_j and start_j < finish_i never held)
PASS  the project cap was respected (peak 1 <= 1 simultaneous runs)
```

## Observations that are not defects of the product

- A run of the flow before the final prompt wording asked each task to start with `sleep 20`. One pi agent then replaced it with a
  60-iteration shell polling loop of its own and the thread stayed `in_progress` for more than 10 minutes. The prompts no longer ask for a
  sleep (overlap does not need it: the three runs start within milliseconds of each other and last 8-22 s).
- In one earlier flow run the step found zero threads 250 s after the paste. The cause was not captured (the harness had cleaned up) and is
  tracked in `foreman-ig27o`. The step now prints the coordinator reply, dumps the conversation tail when the count is not three, and when
  no thread appeared sends the same paste once more, prints both replies and records an UNVERIFIED tally line ("coordinator needed a second
  paste") so a flaky coordinator is never a clean pass; the "exactly three threads" assertion still fails on duplicates. The nudge branch is
  driven against a stubbed coordinator by the self-test (see the follow-up section); it has not been triggered by the real coordinator.

## Follow-up: exact content everywhere, the nudge net exercised, one complete pass and the failure injection

Script version: `origin/main` `8ea50a1e` (#658) plus this change (`scripts/e2e/exact_content.sh`).

- Every file-content comparison that went through `tr -d ' \n\r'` (it accepts `ALPHA -7` for `ALPHA-7`) now uses `assert_content_exactly`
  from `scripts/e2e/exact_content.sh`: only trailing newlines may differ. Sites: `claude_projects_flow.sh` (steer marker and the three
  step 5b files), `failure_injection.sh` (`before-pause.txt`), `multi_repo.sh` (three `VERSION` checks). The helper is sourced by
  `claude_projects/lib.sh` (the flow and the failure injection) and by `multi_repo.sh` (POSIX sh). Left alone on purpose: `tr -d ' '` on
  `wc` counts and `ps` pids, `tr -d ' \n'` on `od` output that builds a random webhook secret (`github.sh`), and the UI text trimming in the
  `.mjs` drivers; none compares file content.
- Self-test (`bash scripts/e2e/claude_projects/overlap.sh`, `passed=21 failed=0`): 11 probes of the comparison (`ALPHA-7`, `ALPHA-7\n`,
  `ALPHA-7\n\n` accepted; `ALPHA -7`, ` ALPHA-7`, `ALPHA-7 \n`, `ALPHA-7\r\n`, `ALPHA-7\n\n extra`, `ALPHA-7\nB`, empty, other word rejected;
  `sh scripts/e2e/exact_content.sh` alone: `passed=11`, also under `dash`), the four-thread count, and `paste_three_tasks` against a
  stubbed coordinator in a subshell with counters (nothing leaks into the real tally):

  | Stub | pastes | pass | fail | unverified |
  |---|---|---|---|---|
  | threads appear after the first paste | 1 | 2 | 0 | 0 |
  | threads appear only after the second paste | 2 | 2 | 0 | 1 |
  | no thread ever appears | 2 | 1 | 1 ("exactly three threads") | 1 |
  | four threads appear | 1 | 1 | 1 ("exactly three threads") | 0 |

  Mutation check: replacing the `unverified` call by a no-op makes the second and third rows fail.
- Complete flow, stages 1-7, GitHub stage off, pi/MiniMax, private stack:
  - First run (script before the diagnostics below): `passed=80 failed=3 unverified=2`, exit 3. The three failures are step 5b's file checks:
    all three threads completed and the overlap, cap and three-thread assertions passed, but `git show <branch>:<file>` returned nothing
    for each. Not reproduced (below); filed as `foreman-2onq1`.
  - Second run (adds diagnostics on a failed content check): `passed=83 failed=0 unverified=2`, exit 0.
  - Step 5b alone: `passed=40 failed=0` (and `passed=31` earlier in this PR's history).

  | Stage | PASS | FAIL | UNVERIFIED (second run) |
  |---|---|---|---|
  | 1 project | 5 | 0 | 0 |
  | 2 memory and library | 6 | 0 | 0 |
  | 3 bead to thread | 5 | 0 | 0 |
  | 4 steer / stop / resolve | 13 | 0 | 0 |
  | 5 Overview, chat, approvals | 6 | 0 | 1 (pi has no approvals) |
  | 5b three tasks, overlap, self-test | 35 | 0 | 0 |
  | 6 notifications and usage | 2 | 0 | 0 |
  | 7 review archive and verdict | 11 | 0 | 0 |
  | 8 GitHub | 0 | 0 | 1 (SKIP, no scratch repo) |

  In the second run the runs of step 5b took 4.7 s, 7.7 s and 425.3 s (one pi agent was slow); all three started within milliseconds.
- `failure_injection.sh`, all seven scenarios: `passed=35 failed=1 unverified=1`, exit 3.

  | Scenario | PASS | FAIL | UNVERIFIED |
  |---|---|---|---|
  | provider-down | 8 | 0 | 0 |
  | agent-crash | 6 | 0 | 0 |
  | coordinator-crash | 3 | 0 | 0 |
  | server-crash | 2 | 0 | 1 (no orphan was produced in 3 attempts) |
  | port-closed | 2 | 1 | 0 |
  | project-paused (includes the changed `before-pause.txt` check: PASS, exact content) | 10 | 0 | 0 |
  | br-down | 4 | 0 | 0 |

  The one FAIL is `port-closed`: `server log records the reap: 'OrphanReaper: terminating' not found`, reproduced 3 of 3 (once in this run,
  twice alone). The run does fail with `port_closed` and no agent is left running, but the agent exits together with its exec-port, so the
  reaper has nothing to log; the scenario asserts the log line unconditionally. The same host fact is why `server-crash` finds no orphan.
  Not caused by this change (different scenario); filed as `foreman-e01a1`, not fixed here. Consequence: the OrphanReaper path of
  `foreman-zmhzw` is currently not exercised live by either scenario.

## Not exercised

GitHub PRs and CI for the three threads (stage 8 and the CI failure injector), claude as the thread provider, concurrency above the
project's cap of 3, and a thread count other than three.
