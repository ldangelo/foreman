# Developer Report: Event-driven status refresh via agent worker notifications

## Approach

Implemented an HTTP-based notification system where detached agent workers POST status/progress updates to a lightweight HTTP server running in the parent foreman process. The server forwards these to an `EventEmitter` (NotificationBus), which the `watchRunsInk` UI loop subscribes to. On receiving a notification for a watched run, the sleep is interrupted and the UI re-renders immediately — eliminating the full 3-second polling delay for status transitions.

Key design decisions:
- **HTTP over IPC/named pipes**: Works with detached workers and survives process restarts. Platform-agnostic.
- **Fire-and-forget in workers**: The `NotificationClient` uses 500ms timeout and silently swallows errors. Workers never block or fail due to a missing/dead server.
- **Polling fallback unchanged**: SQLite remains the source of truth. Notifications are an enhancement — if the server is unavailable, `watchRunsInk` falls back to polling every 3 seconds automatically.
- **OS-assigned port (port 0)**: Avoids port conflicts between concurrent foreman instances.

## Files Changed

- `src/orchestrator/types.ts` — Added `WorkerStatusNotification`, `WorkerProgressNotification`, and `WorkerNotification` union type.

- `src/orchestrator/notification-bus.ts` — **NEW**: `NotificationBus` class (extends `EventEmitter`) with `notify()`, `onNotification()`, `onRunNotification()`, `offRunNotification()`. Exports `notificationBus` singleton.

- `src/orchestrator/notification-server.ts` — **NEW**: `NotificationServer` class. HTTP server bound to `127.0.0.1:0` (OS assigns port). Endpoints: `POST /notify` (validates and forwards to bus), `GET /health`. Guards against oversized payloads (64KB limit).

- `src/orchestrator/agent-worker.ts` — Added `NotificationClient` class (fire-and-forget HTTP POST). Reads `FOREMAN_NOTIFY_URL` from env after worker env vars are applied. Emits status notifications on `updateRun()` calls (completed, failed, stuck) and progress notifications after each assistant turn. `runPhase()` and `runPipeline()` accept `notifyClient` parameter. `markStuck()` accepts optional `notifyClient`.

- `src/orchestrator/dispatcher.ts` — Added `notifyUrl?: string` option to `dispatch()` and `resumeRuns()`. Threads `notifyUrl` through `spawnAgent()` and `resumeAgent()`. `buildWorkerEnv()` adds `FOREMAN_NOTIFY_URL` to worker env when provided.

- `src/cli/watch-ui.ts` — Added `NotificationBus` import. `watchRunsInk()` accepts optional `opts.notificationBus`. Subscribes `onRunNotification` for each watched run ID; calls `sleepResolve()` to wake poll immediately. Unsubscribes in `finally` block to prevent listener leaks.

- `src/cli/commands/run.ts` — Imports `NotificationServer` + `notificationBus`. Starts server before dispatch (non-fatal if it fails). Passes `notifyUrl` to `dispatch()` and `resumeRuns()`. Passes `notificationBus` to `watchRunsInk()`. Stops server in `finally` block.

## Tests Added/Modified

- `src/orchestrator/__tests__/notification-bus.test.ts` — **NEW** (7 tests):
  - `notify()` emits on global and per-run channels
  - Per-run handler not called for different runId
  - `offRunNotification()` removes listener
  - Progress notifications broadcast correctly
  - Multiple listeners on same run both called
  - Singleton `notificationBus` is a `NotificationBus` instance

- `src/orchestrator/__tests__/notification-server.test.ts` — **NEW** (10 tests):
  - Server starts and exposes `http://127.0.0.1:<port>` URL
  - `GET /health` returns 200
  - `POST /notify` with valid status notification emits on bus + returns 200
  - `POST /notify` with valid progress notification emits on bus
  - Missing `type` field → 400
  - Missing `runId` field → 400
  - Invalid JSON body → 400
  - Unknown path → 404
  - `stop()` + `start()` lifecycle works
  - `stop()` on unstarted server is a no-op

All 17 new tests pass. All 83 existing tests (roles, dispatcher, watch-ui) continue to pass. TypeScript type check (`tsc --noEmit`) exits 0.

## Decisions & Trade-offs

1. **Notification URL passed via env var**: The worker reads `FOREMAN_NOTIFY_URL` from its environment (set by dispatcher via `buildWorkerEnv`). This keeps `WorkerConfig` JSON stable — no interface change needed.

2. **Progress notifications only on `assistant` turns in pipeline**: Emitted inside `runPhase()` after each tool-use batch. This avoids flooding the server with every message type while still providing meaningful progress updates.

3. **Status notifications on all terminal states**: `completed`, `failed`, `stuck` — all emit a notification immediately after `store.updateRun()` so the watch UI can react before the worker exits.

4. **`watchRunsInk` API is backwards-compatible**: The `opts` parameter is optional. Existing callers (tests, other consumers) work unchanged.

5. **No changes to `monitor.ts`**: The explorer report suggested adding event subscription there, but `monitor.ts` uses `checkAll()` in a fire-and-forget loop that already runs frequently. Adding event subscription would require refactoring its external API. Deferred to a follow-up task.

## Known Limitations

- **monitor.ts not wired up**: The monitoring process still uses its polling-only approach. Event subscription there could speed up stuck detection but is not implemented in this task.
- **No notification persistence**: If the foreman watch session exits and a worker tries to POST, the notification is dropped silently. The worker's SQLite writes remain the source of truth for recovery.
- **No deduplication**: Rapid notifications (e.g. multiple tool calls in a burst) may wake the UI loop multiple times. This is harmless — the loop re-polls from SQLite each time.
- **Budget**: Workers running after the foreman watch session exits cannot notify; they continue writing to SQLite normally.
