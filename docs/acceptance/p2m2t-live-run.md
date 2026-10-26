# Live run of the merged flow and failure-injection scripts (foreman-p2m2t)

One complete run of both scripts against the working tree that fixes `foreman-zmhzw`, `foreman-7nvf8` and `foreman-2onq1`
(built on `origin/main` `4c8736b1`, changes not yet committed). Real throwaway server, real Go CLI, real `pi` agent on
`minimax/MiniMax-M2.7-highspeed`, private databases (`foreman_e2e_p2m2t_flow`, `foreman_e2e_p2m2t_fi`), own ports. Stages 1-7 only: no real GitHub.

| Script | Result | Wall |
|---|---|---|
| `scripts/e2e/claude_projects_flow.sh` | passed=88 failed=0 unverified=2, exit 0 | 161 s |
| `scripts/e2e/failure_injection.sh` (all nine scenarios) | passed=45 failed=0 unverified=2, exit 0 | 283 s |

## What this run shows

- `cancel-strays` and `shutdown-strays` (`foreman-zmhzw`): after `run cancel`, after `thread stop`, after SIGTERM of the server and after
  cancelling the run that was resumed on restart, nothing is left running in the run's worktree; the server log records the shutdown sweep.
  Before the fix the same scenarios reported 4 FAILs with `sleep 300` strays at ppid 1.
- `port-closed` now asserts the `OrphanReaper` log line only when an agent outlived the exec-port. On this host the agent dies with its
  exec-port, so that assertion is reported UNVERIFIED instead of FAIL (`foreman-e01a1`); the run still failed with `port_closed` and left no agent.
- Step 5b (three tasks, three threads, exact file content on each thread branch) passed with the new polling reads and diagnostics
  (`foreman-2onq1`). The single earlier failure was not reproduced, so its cause is still unknown; this run is not evidence that it is fixed.

## UNVERIFIED

- Flow: approve/deny a tool call and answer an agent question (pi has no permission or ask mechanism); real GitHub paths
  (`FOREMAN_E2E_GITHUB_REPO` not set).
- Failure injection: `OrphanReaper` on a real orphan in `server-crash` and `port-closed` (the agent dies with the server or its exec-port on this host).

## Re-run on the final tree (after wave 2)

- `claude_projects_flow.sh`: passed=88 failed=0 unverified=2, exit 0 (234 s). The coordinator setup proposal, the notifier URL policy and the new
  coordinator actions did not disturb it.
- `failure_injection.sh`, full nine scenarios, run three times on the final tree:
  - `shutdown-strays` failed once (a tool process survived a graceful shutdown). Cause: the sweep ran in `Application.stop/1`, after the
    supervision tree was down; an executor stopped with the tree could already have killed its agent's own group, re-parenting the tool to pid 1.
    Fixed by moving the sweep to `Application.prep_stop/1`. Standalone `shutdown-strays` then passed (4 PASS); the full run after the change did not fail there.
  - `br-down` failed in two of three full runs (`no thread appeared for the br-down bead within 300s`) and `project-paused` once alongside it
    (passed alone, 10 PASS). The new diagnostics (`foreman-3ll3t`) show why: `BeadsWatcher lease_acquire failed reason=:lease_timeout` on every poll,
    so the watcher never reads the bead. `BeadsDbLease` has no expiry; a lease still held after the scenarios that kill the server blocks
    the import until it is released. This is the pre-existing failure behind `foreman-3ll3t`, not something this branch added; it is filed as
    `foreman-w29up` (stuck BeadsDbLease after a hard server kill), not fixed here.
    Update: fixed afterwards on the same branch (`foreman-w29up`: holds taken for one call carry the server incarnation, the next server
    takes them over and boot reconciliation releases them); the full nine-scenario run then passed three times, each `passed=45 failed=0
    unverified=2` (`parity-audit.md`).

## Forked continue and jobsite resume with real claude (foreman-kgqqz, foreman-cm8nv, foreman-nufr9)

Real `claude` 2.1.308 (haiku, OAuth login through the symlinked `~/.claude`), real Go CLI and HTTP API, private database/port/scratch repo per
script, no GitHub. Both scripts guard on `claude_ready` (`scripts/e2e/claude_projects/lib.sh`): without a logged-in claude the scenario is
recorded UNVERIFIED, never FAIL.

| Script | Result |
|---|---|
| `scripts/e2e/fork_live.sh` (new; `E2E_PORT=4861 E2E_HOOK_PORT=4961 E2E_DB_NAME=foreman_e2e_cl`) | passed=11 failed=0 unverified=0, exit 0, 55 s |
| the same script with the `--from-source-branch` and `--add-repo` steps (`E2E_PORT=4891 E2E_HOOK_PORT=4991 E2E_DB_NAME=foreman_e2e_fk`) | passed=48 failed=0 unverified=0, exit 0, 128 s |
| `claude_projects_flow.sh` step 8, quick mode `E2E_SCHEDULE_ONLY=1` (ports 4893/4993) | passed=32 failed=0 unverified=0, exit 0, 102 s; with `FOREMAN_SCHEDULE_TICKER_ENABLED=false` the step FAILs (exit 3, negative control) |
| `claude_projects_flow.sh` full flow with step 8, run three times | passed=123 failed=2 unverified=2 (788 s), passed=120 failed=5 unverified=2 (989 s), passed=125 failed=0 unverified=2 (282 s, exit 0). The failures of the first two runs are before step 8: step 5b (three tasks in one message: a pi run still `in_progress` or its file not on the branch within the polling window) and, in run 2 only, step 6 (the webhook sink never received a request, the capture file was never created; no server log kept, cause not established). The third run passed everything, including step 6's `run_update` delivery for the first thread's own run (it also passed in run 1) and step 8 (the schedule fired after 28 s) |
| `scripts/e2e/failure_injection.sh jobsite-resume` (new scenario; ports 4862/4962), run twice | passed=17 failed=0 unverified=0 (85 s) both times |
| the same scenario with the fix disabled (session watcher off, negative control) | passed=2 failed=4, exit 3 |

### Forked continue (`project adopt --continue --fork`, foreman-kgqqz)

`fork_live.sh`: a `claudeedit` run is told a random word and writes it to `recall.txt`; its claude session `43d1146f-...` is recorded on the run
(`provider_sessions`). `foreman project adopt --kind run --id <run> --into <project> --continue --fork --prompt "What was the recall word? Create a file
named answer.txt ..."` answers `mode: forked`. The forked thread's agent (never told the word in its own prompt) wrote exactly the word to
`answer.txt` on its branch, under a session of its own (`f7e16e43-...`, not the source's). The source is untouched: its claude session file has the
same sha256 (`941cadbc...`) and 45 lines before and after, and the source run's status and `provider_sessions` are identical.

What carries it: `adopt ... --fork` resolves the source's provider session from the projections (`Projects.ForkSource`: a run's last
`WorkerSessionBound`, a task's latest run with one, a jobsite's `session_id`), the new task records `fork_provider` / `fork_session_id`
(`TaskCreated`, validated by `AgentRuntime.JidoHarness.ForkSession`), and `RunExecutor` launches phase 1 with `provider_session_id` +
`provider_options.fork_session` (claude: `--resume <id> --fork-session`; pi: `--fork <id>`). A provider other than the session's, no recorded
session, or a provider that cannot fork is a typed 422 (`fork_no_session`, `fork_provider_unsupported`, `fork_provider_mismatch`), never a silent
context-seeded thread; the launch refuses a mismatching phase provider too. Unit and integration tests: `fork_session_test.exs` (incl. the harness argv
contract for claude and pi, live-input modes included), `task_fork_session_test.exs`, `adoption_fork_test.exs`, `run_executor_fork_test.exs`,
`adoption_controller_test.exs`, Go `TestProjectAdoptBodies`.

Measured while building it (probe commands in `docs/spikes/E9-SP2.md` points 6 and 7): both `claude --resume <id> --fork-session` and `pi --fork <id>`
find the session by id from another directory and also when the directory it was created in was deleted, without a prompt. The earlier premise that
"pi prompts interactively" holds for a plain `pi --session <id>` from another directory only, so pi sessions are forkable too (the harness maps both,
`ForkSession.harness_options/2`); the pi path is covered by the argv contract test and the launch test, NOT run live through Foreman. A plain
`claude --resume` (no fork) also resumes from any directory (`scripts/e2e/claude_resume_cwd_probe.sh`, 10 PASS), so the E9-SP2 point 6 doubt is closed.

Source-branch continue (`--from-source-branch`) and `--add-repo`, same script (second run, 48 assertions): the plain fork above was cut from the project's current
branch (its branch does not contain the source branch, `recall.txt` is not on it, its PR base is `main`: the control). The forked continue with
`--from-source-branch` answers `mode: forked` and `source_branch` = the source's branch; its run's branch contains the source branch, inherits `recall.txt`
(written by the source thread, not by this one), the agent still remembered the word, and its recorded PR base is the source branch; the context-seeded continue
with the flag does the same. A second project over another repository refuses the branch (`source_branch_not_found`, no thread started) and refuses the move
(`repo_not_in_project`, nothing attached, the run stays); the same move with `--add-repo` attaches the first repository to the second project (id `repo`,
`added_by adoption:run:<run>`) and the run, with its thread, belongs to it.

### Jobsite resume after a crash in the first iteration (foreman-cm8nv)

`failure_injection.sh jobsite-resume`: a claude jobsite (`POST /api/jobsites`) is given a recall word, then holds a tool call open for 90 s. Evidence of
one run (js-5e6233caadbf3379): `JobsiteIterationStarted` 01:35:24.005, `JobsiteSessionBound` 01:35:24.772 (0.77 s later, session
`6a3f96dd-...`), still 0 completed iterations; `kill -9` of exec-port and server leaves the claude agent and its tool as orphans (ppid 1); after the
restart boot recovery pauses the jobsite as resumable (`paused/server_restart`, same session id, not `executor_lost`); `POST /api/jobsites/:id/resume`
with a prompt that does not contain the word is accepted (202), the orphans are reaped, the jobsite completes, `answer.txt` holds exactly the recall
word (the agent knew the original context), iteration 2 ran in the same session `6a3f96dd-...` (claude transcript 27 lines before the crash, 61 after).
The second run (js-709b1a1c96228052, session `b5012de1-...`) is identical. With the session watcher disabled the same scenario FAILs where it
should: no session on the running jobsite, no `JobsiteSessionBound`, and the restart fails the jobsite as `executor_lost`. Not covered by a failing
control: the recall and same-session assertions themselves (the resume prompt provably lacks the word). Observation, unchanged: a jobsite that
completes after such a resume keeps `last_error: agent_interrupted` from iteration 1.

### foreman-nufr9 / foreman-8vf0s / foreman-he4yf: what is still open

- nufr9: the resume across a crash now passes (above); every other listed Claude path already passed. PrFix claude `resume_session` was run on a real GitHub PR on 2026-10-26
  (`live-claude-prfix-resume.md`). Claude is not cwd-bound for resume or fork (measurement above), which removes the doubt E9-SP2 carried.
- he4yf: NOT run live: per-phase repo selection and an agent-driven `foreman_task_fanout`. Blocker found live: `/mcp` answers HTTP 500 on a server booted
  by the harness (`anubis_mcp` `:persistent_term.get({Anubis.Server.Supervisor, ForemanServer.MCP, :session_config})` missing), so no agent could call a
  Foreman MCP tool; `scripts/e2e/multi_repo_agent.sh` and `multi_repo/agent_probe.exs` hold the attempt (not green). Multi-repo on real GitHub stays out of scope.
- 8vf0s (closed): (1) in-container network blocking on a real docker host (OrbStack): `scripts/e2e/network_policy_flow.sh control allowlist` passed=29 failed=0:
  under an allowlist the policy network is `--internal`, the sandbox sits on it only, the allowed host answers 200 through the proxy, a name of the same host that
  answers 200 without the policy gets 403, bypass by IP and by name fail (rc 7 / 6), the host-side witness saw the allowed request once and the blocked ones never;
  mode `none` gives all `000`; cancel and pause/resume re-apply the policy; teardown leaves nothing. The in-container actor is a SIMULATED pi
  (`scripts/e2e/network_policy/fake-pi` through Foreman's own docker-exec shim); a real agent under the policy was not run. (2) The Scheduled tab in headless
  Chromium, `scripts/e2e/scheduled_tab_flow.sh` passed=30 failed=0: rows listed (next fire equal to the API and an independently computed slot), Pause and Resume
  flip the row, the API and the CLI. Defects found: `foreman-q8ufk` (a crash leaves the policy network and the sandbox container; `NetworkPolicy.sweep_orphans/1`
  removed only the sidecar, and was host-global) and `foreman-mr5b1` (hooks and `docker exec` ran without the proxy variables; reproducers
  `network_policy_flow.sh crash` and `hook-env`), both FIXED afterwards (next bullet), and `foreman-cnn1l` (`/mcp` 500, above), not fixed.
- q8ufk and mr5b1 (closed): the baseline `network_policy_flow.sh hook-env crash` on the same real docker host was passed=3 failed=3 (the hook failed with
  `curl: (6) Could not resolve host: host.docker.internal`, `hook_failed`; after the restart the policy network and the sandbox container were still up
  37 s later). Fixed: all of a policy's docker objects carry `foreman.owner` and `foreman.jobsite` labels, cleanup and the boot sweep remove the labelled
  containers (sandbox included) before the network and touch nothing else, and the sandbox's `:env` is the container's environment. After the fix the full
  script (control allowlist none cancel pause-resume hook-env scope crash) passed=137 failed=0 unverified=0 and `crash` alone passed=30 failed=0 with
  `docker ps -a` and `docker network ls` holding nothing of Foreman's afterwards; `crash` resumes the orphaned jobsite under the same network name and
  `scope` runs a sweep for another owner against an in-flight jobsite (nothing removed).

## Final tree (commit after the completion wave)

- Full Elixir suite: 6096 passed at seeds 730691, 424242 and 11 (the first run exposed a seed-dependent leak: five tests deleted the `:approvals` env instead of restoring it; fixed).
- `jido_harness`: 128 passed. `go test ./...` green. `mix format`, `credo --min-priority higher`, `--warnings-as-errors` clean.
- `claude_projects_flow.sh`: passed=125 failed=0 unverified=2 (twice). One earlier run on the same tree failed at step 3 (the first thread ended `failed`); its stack was not kept, so its cause is unknown. The next two runs did not reproduce it.
- `failure_injection.sh` (all scenarios incl. `jobsite-resume`): passed=62 failed=0 unverified=2.
- Open and not buildable here: `foreman-ksy0q` (real GitHub; merge under real branch protection was verified on 2026-10-26, `live-github-branch-protection.md`, bead closed), `foreman-2onq1` (not reproduced), plus the deferred C13 `foreman-zn7de` and `foreman-mivo7`. (`foreman-nufr9`, PrFix resume on a real PR, was run on 2026-10-26: `live-claude-prfix-resume.md`.)
