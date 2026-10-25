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
