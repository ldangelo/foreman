# QA Report: Event-driven status refresh via agent worker notifications (polish pass)

**Date:** 2026-03-12
**Branch:** foreman/foreman-29fc
**Pass:** Polish pass (post-initial implementation review)

## Verdict: PASS

## Test Results

| Metric | Count |
|---|---|
| Tests passed | 247 |
| Tests failed | 9 (all pre-existing) |
| Unhandled errors | 2 (pre-existing, from tsx-missing worktree issue) |
| Test files passed | 18 |
| Test files failed | 4 (all pre-existing) |
| TypeScript (`npx tsc --noEmit`) | Exit 0 — no errors |

### All 17 Notification Tests: PASS

| Test File | Tests | Result |
|---|---|---|
| `src/orchestrator/__tests__/notification-bus.test.ts` | 7 | PASS |
| `src/orchestrator/__tests__/notification-server.test.ts` | 10 | PASS |

### Pre-existing Failures (not caused by this change)

All 9 failures are environment-level issues in the worktree, identical to those documented in the previous QA reports (2026-03-12T17:07 and 2026-03-12T17:16):

| Test File | Failing Tests | Root Cause |
|---|---|---|
| `src/cli/__tests__/commands.test.ts` | 4 | CLI binary not built in worktree (ENOENT) |
| `src/orchestrator/__tests__/detached-spawn.test.ts` | 2 + 2 uncaught errors | `tsx` binary absent from worktree `node_modules` |
| `src/orchestrator/__tests__/worker-spawn.test.ts` | 1 | `tsx` binary absent from worktree `node_modules` |
| `src/orchestrator/__tests__/agent-worker.test.ts` | 2 | `tsx` binary absent from worktree `node_modules` |

### Related suites with no regressions

| Test File | Tests | Result |
|---|---|---|
| `src/orchestrator/__tests__/dispatcher.test.ts` | 11 | PASS |
| `src/cli/__tests__/watch-ui.test.ts` | 49 | PASS |
| `src/orchestrator/__tests__/monitor.test.ts` | 6 | PASS |
| `src/orchestrator/__tests__/roles.test.ts` | 23 | PASS |
| `src/lib/__tests__/store.test.ts` | 18 | PASS |

## Polish Pass Changes Verified

### 1. `setMaxListeners(0)` in `NotificationBus` constructor
- Confirmed present at line 20 of `notification-bus.ts`
- Comment explains rationale: precaution against future consumers subscribing to the global `"notification"` channel from many places simultaneously
- Correct: `setMaxListeners(0)` removes the cap entirely, preventing spurious MaxListenersExceededWarning

### 2. `responded` flag guard in `notification-server.ts` POST handler
- Confirmed present at lines 85–114 of `notification-server.ts`
- `let responded = false` declared before `req.on("data", ...)` handler
- Set to `true` on 413 (payload too large) before `req.destroy()`
- Checked first thing in `req.on("end", ...)` — prevents double-response after oversized payload rejection
- All other response paths also set `responded = true` (400 invalid validation, 400 invalid JSON, 200 success)
- Correct: guards against HTTP response-after-end errors on large payloads

### 3. Block comment in `agent-worker.ts` about single-agent vs pipeline notification asymmetry
- Confirmed present at lines 208–213 of `agent-worker.ts`
- Documents that single-agent mode only sends terminal notifications (`completed`, `failed`, `stuck`), while pipeline mode (`runPhase`) sends a `progress` notification after every assistant turn
- Explains the asymmetry is intentional: single-agent progress is already flushed to SQLite every 2s via `flushProgress()`, so polling fallback covers it
- Notes alignment of the two paths is deferred to a follow-up task

### 4. Expanded comment in `run.ts` about monitor not being wired to `notificationBus`
- Confirmed present at lines 43–45 of `src/cli/commands/run.ts`
- Explicitly documents that `monitor.ts` still uses polling-only, not wired to `notificationBus`
- Explains the trade-off (would speed up stuck detection but requires monitor API refactor)
- Correctly flags as deferred work

## Implementation Correctness (carried forward from prior QA passes)

All previously verified correctness properties remain intact:

- **NotificationBus**: dual-channel emission (`notification` + `notification:<runId>`), correct subscribe/unsubscribe, singleton export
- **NotificationServer**: loopback-only HTTP, OS-assigned port, 64KB payload guard, JSON validation, clean lifecycle (`start`/`stop`)
- **NotificationClient in agent-worker.ts**: fire-and-forget with 500ms timeout, silent error swallowing, reads `FOREMAN_NOTIFY_URL` env var
- **watch-ui.ts**: optional `notificationBus` parameter, per-run subscription, `sleepResolve()` wake-on-notification, cleanup in `finally` block
- **run.ts**: server started before dispatch, non-fatal on server-start failure, `notifyUrl` passed to `dispatch()` and `resumeRuns()`, server stopped in `finally`
- **dispatcher.ts**: `notifyUrl` threaded through `buildWorkerEnv()` into `FOREMAN_NOTIFY_URL`

## Issues Found

None. All 17 notification tests pass. TypeScript compiles cleanly (exit 0). No regressions in any previously passing test suite. The four polish-pass changes are correctly implemented and match the developer report description.

## Files Modified by QA

None — no test fixes were required.
