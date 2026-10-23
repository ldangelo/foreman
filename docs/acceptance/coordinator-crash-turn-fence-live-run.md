# Coordinator worker crash: no orphaned turn (foreman-42t7a)

Defect: `ProjectWorker` ran the turn with `Task.Supervisor.async_nolink`, so killing the worker left the turn task running and the
replacement worker started a second, concurrent turn (observed once live: two identical threads for one request).

Fix: the turn task is linked to the worker (which traps exits), and each turn registers `{:turn, project_id}` in the runtime
registry; a replacement worker that finds the key taken returns `{:failed, :turn_in_flight}` and retries after `retry_backoff_ms`.

## Deterministic proof (`test/foreman_server/coordinator/runner_test.exs`, "worker crash mid-turn")

- Kill the worker (`Process.exit(pid, :kill)`) while the scripted agent holds a turn open: the held turn process must receive DOWN.
  Reverting to `async_nolink` makes this test fail; removing the registry fence makes the second test fail
  (mutation run: `Result: 16/18 passed`; fixed: `18 passed`).

## Live re-run (pi, minimax/MiniMax-M2.7-highspeed; real server, Go CLI, scratch repo/br)

`E2E_NAME=coorddup E2E_REVIEW=0 bash scripts/e2e/failure_injection.sh coordinator-crash`, three consecutive runs on this branch, each
`passed=3 failed=0 unverified=0`, exit 0. Per run: worker killed mid-turn, coordinator answers after the crash, and
"the requested thread exists exactly once after the crash (0 = request lost, 2 = duplicate actions) (= 1)".

Caveat: the original duplicate was LLM-timing dependent (1 of ~6 runs before the fix), so 3/3 clean live runs are consistent with the
fix but do not by themselves prove it; the deterministic test above is the proof.
