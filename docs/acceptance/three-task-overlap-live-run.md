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
   threads (up to 240 s) instead of trusting the chat output; if none appeared it sends the same paste once more and says so.
4. Asserts: exactly three threads with three distinct titles; each reaches `completed`; each branch holds its file with its word.
5. Reads `RunStarted` and the first terminal event of each thread's run from the event store (`claude_projects/run_interval.exs`, evaluated
   on the server node; the run projection only keeps `started_at_ms` and a `last_event_at_ms` that any later event moves), prints the
   intervals, and asserts `start_i < finish_j and start_j < finish_i` for at least one pair, and that the peak number of simultaneous runs
   does not exceed the project cap.

How parallelism is allowed: the flow sets the project's `max_concurrent_runs` to 3 in step 1, the global RunSlots `max_concurrent_runs`
default is 3 (`config/config.exs`), and `coordinator_max_active_threads` is unset (no coordinator cap). `max_threads_per_turn` is 5.
No server configuration beyond the harness's existing one was needed.

## Result of the complete flow (stages 1-7, no GitHub stage)

`devbox run -- bash scripts/e2e/claude_projects_flow.sh`: `passed=66 failed=0 unverified=2`, exit 0. UNVERIFIED: approve/deny a tool call and
answer an agent question (pi has no permission or ask mechanism), and the GitHub stage (no scratch repo configured).

Step 5b, as printed:

| Check | Result |
|---|---|
| overlap self-test (5 assertions) | PASS |
| no run of the project active before the paste | PASS |
| coordinator chat with the three-item paste exits 0 | PASS |
| coordinator started exactly three threads | PASS |
| three distinct titles | PASS |
| each of the 3 threads reached `completed` and delivered its file | PASS (6 assertions) |
| start and finish read for all three runs | PASS |
| at least two runs overlapped | PASS (3 pairs) |
| project cap respected (peak 3 <= 3) | PASS |

```
run-d4ab22f3c1ac0b86f501976c444ed5c2 1792785240738 1792785262868 RunCompleted
run-0bd282ae1863ae2d85b6de3933ebdf5d 1792785240729 1792785256076 RunCompleted
run-3f969fcbe167a62ea3f071bb1255365d 1792785240748 1792785249318 RunCompleted
run-d4ab22f3c1ac0b86f501976c444ed5c2  start +0.0s  finish +22.1s  (ran 22.1s)
run-0bd282ae1863ae2d85b6de3933ebdf5d  start +0.0s  finish +15.3s  (ran 15.3s)
run-3f969fcbe167a62ea3f071bb1255365d  start +0.0s  finish +8.6s  (ran 8.6s)
overlapping pairs: 3 of 3 ; peak simultaneous runs: 3 ; project cap: 3
```

All three `RunStarted` events are within 19 ms of each other (epoch milliseconds above).

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
- In one earlier flow run the step found zero threads 250 s after the paste. The cause was not captured (the harness had cleaned up);
  the step now dumps the conversation tail when the count is not three and sends one nudge when no thread appeared.

## Not exercised

GitHub PRs and CI for the three threads (stage 8 and the CI failure injector), claude as the thread provider, concurrency above the
project's cap of 3, and a thread count other than three.
