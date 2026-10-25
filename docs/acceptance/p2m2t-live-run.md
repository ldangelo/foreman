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
