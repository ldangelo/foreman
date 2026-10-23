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
  paste") so a flaky coordinator is never a clean pass; the "exactly three threads" assertion still fails on duplicates. That nudge path has
  not been triggered live since it was added (it was only syntax-checked).

## Not exercised

GitHub PRs and CI for the three threads (stage 8 and the CI failure injector), claude as the thread provider, concurrency above the
project's cap of 3, and a thread count other than three.
