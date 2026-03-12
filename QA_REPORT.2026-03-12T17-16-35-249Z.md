# QA Report: Event-driven status refresh via agent worker notifications

## Verdict: PASS

## Test Results
- Test suite: 247 passed, 9 failed
- New tests added: 17 (7 in `notification-bus.test.ts`, 10 in `notification-server.test.ts`)
- All 17 new tests: PASS ✓
- TypeScript (`npx tsc --noEmit`): exit 0 ✓

### Pre-existing Failures (NOT caused by this change)

All 9 failing tests are pre-existing environment issues in the worktree — confirmed by the previous QA report (foreman-29fc at 2026-03-12T17:07) which documented the same 9 failures before this implementation landed.

| Test File | Failing Tests | Root Cause |
|---|---|---|
| `src/cli/__tests__/commands.test.ts` | 4 tests | CLI binary not built in worktree (ENOENT) |
| `src/orchestrator/__tests__/detached-spawn.test.ts` | 2 tests + 2 uncaught errors | `tsx` binary missing from worktree `node_modules` |
| `src/orchestrator/__tests__/worker-spawn.test.ts` | 1 test | `tsx` binary missing from worktree `node_modules` |
| `src/orchestrator/__tests__/agent-worker.test.ts` | 2 tests | `tsx` binary missing from worktree `node_modules` |

### Key passing test suites (related to this change)

| Test File | Tests | Status |
|---|---|---|
| `src/orchestrator/__tests__/notification-bus.test.ts` | 7 | ✓ PASS |
| `src/orchestrator/__tests__/notification-server.test.ts` | 10 | ✓ PASS |
| `src/orchestrator/__tests__/dispatcher.test.ts` | 11 | ✓ PASS (no regressions) |
| `src/cli/__tests__/watch-ui.test.ts` | 49 | ✓ PASS (no regressions) |
| `src/orchestrator/__tests__/monitor.test.ts` | 6 | ✓ PASS (no regressions) |

## Implementation Correctness

### NotificationBus (`notification-bus.ts`)
- Extends `EventEmitter` — correct use of Node.js built-in
- `notify()` emits on global `"notification"` channel AND per-run `"notification:<runId>"` channel
- `onRunNotification()` / `offRunNotification()` provide subscribe/unsubscribe API
- Singleton `notificationBus` exported for shared use
- Tests verify: global channel, per-run channel, cross-run isolation, unsubscription, multiple listeners, progress notification broadcast

### NotificationServer (`notification-server.ts`)
- HTTP server bound to `127.0.0.1:0` (OS-assigned port — no conflicts between concurrent instances)
- `POST /notify`: validates payload (checks `type` and `runId` presence), rejects oversized payloads (64KB limit), returns 400 on invalid JSON or missing fields, forwards valid notifications to bus
- `GET /health`: returns 200 `{ok: true}`
- Unknown paths: 404
- `start()` / `stop()` lifecycle properly managed (stop on unstarted server is no-op)
- `url` / `port` getters throw if not started (guard against misuse)
- Tests verify all of the above

### NotificationClient in `agent-worker.ts`
- Fire-and-forget HTTP POST with 500ms timeout
- All errors silently swallowed — worker never blocks or fails on notification failure
- Reads `FOREMAN_NOTIFY_URL` env var (set by dispatcher via `buildWorkerEnv`)
- Emits `status` notifications for `completed`, `failed`, `stuck` states
- Emits `progress` notifications after each assistant turn in pipeline mode

### `watch-ui.ts` integration
- Optional `opts.notificationBus` parameter — backwards compatible (no breaking changes)
- Subscribes `onRunNotification` per watched run ID
- `onNotification` handler calls `sleepResolve()` to wake poll immediately
- Cleanup in `finally` block via `offRunNotification` prevents listener leaks
- 49 existing watch-ui tests pass unchanged

### `run.ts` integration
- `NotificationServer` started before dispatch; `notifyUrl` passed to `dispatch()` and `resumeRuns()`
- Server start failure is non-fatal (falls back to polling silently)
- `notificationBus` passed to `watchRunsInk()` for immediate wake-on-notification
- Server stopped in `finally` block (clean shutdown)

### `dispatcher.ts` changes
- `notifyUrl?: string` option added to `dispatch()` and `resumeRuns()` — backwards compatible
- `buildWorkerEnv()` receives `notifyUrl` and adds `FOREMAN_NOTIFY_URL` to worker environment

## Issues Found

None. All new code is correct, TypeScript compiles cleanly, and all new tests pass. Existing test suites show no regressions.

## Files Modified

- `src/orchestrator/__tests__/notification-bus.test.ts` — **NEW** (7 tests)
- `src/orchestrator/__tests__/notification-server.test.ts` — **NEW** (10 tests)
