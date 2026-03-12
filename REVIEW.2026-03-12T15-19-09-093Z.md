# Code Review: Event-driven status refresh via agent worker notifications

## Verdict: PASS

## Summary
The implementation delivers a clean, well-scoped event-driven notification layer on top of the existing polling architecture. Workers POST JSON to a loopback HTTP server running in the foreman parent process; the `NotificationBus` (an `EventEmitter` wrapper) relays those notifications to `watchRunsInk`, which interrupts its 3-second sleep to re-render immediately. The design is deliberately additive: SQLite remains the source of truth, all new parameters are optional, and every code path has a polling fallback. The 17 new tests cover the happy path and important error cases thoroughly, and all existing tests continue to pass. No critical or blocking issues were found.

## Issues

- **[NOTE]** `src/orchestrator/notification-server.ts:83-90` — The oversized-payload guard sends a 413, calls `res.end()`, then calls `req.destroy()`. Node.js stream semantics guarantee that `req.on("end")` will not fire after `destroy()`, so the double-response concern is academic. However, adding a `let responded = false` guard flag (set before `res.end()` calls, checked at the top of the `end` handler) would make the intent explicit and defensive against future refactors.

- **[NOTE]** `src/orchestrator/agent-worker.ts:208-295` — Single-agent (non-pipeline) mode emits only status notifications (`completed`, `failed`, `stuck`) but never progress notifications. Pipeline mode (`runPhase`) emits a progress notification after every assistant turn. The asymmetry is intentional (progress in the single-agent path is already flushed to SQLite every 2 s), but it means the live-UI benefit is lower for `--no-pipeline` runs. Worth documenting or aligning in a follow-up.

- **[NOTE]** `src/orchestrator/notification-bus.ts:12` — `NotificationBus` extends `EventEmitter` without calling `setMaxListeners(0)` or raising the cap. Each watched run registers on its own unique `notification:<runId>` event channel, so MaxListeners warnings are not a practical concern with the current usage pattern. If a future consumer subscribes to the global `"notification"` channel from more than 10 places simultaneously, the default warning would fire. Consider `this.setMaxListeners(100)` or `0` (unlimited) as a precaution.

- **[NOTE]** `src/cli/commands/run.ts` — `monitor.ts` is not wired to `notificationBus`. This is a known, acknowledged deferral (documented in the developer report). A follow-up task should be tracked so the monitor command gains the same latency reduction as the watch UI.

## Positive Notes

- **Backwards compatibility is airtight.** Every new parameter (`notifyUrl`, `notificationBus`) is optional; existing callers compile and run without changes.
- **Security posture is correct.** The HTTP server binds exclusively to `127.0.0.1` on an OS-assigned port, accepts a 64 KB payload cap, and is only reachable from the local machine.
- **Fire-and-forget is the right default.** The 500 ms timeout and silent error suppression in `NotificationClient.send()` ensure workers are never blocked or crashed by a missing/slow parent server.
- **Lifecycle management is clean.** The `finally` block in `run.ts` unconditionally stops the notification server regardless of how the command exits, and `watchRunsInk` unsubscribes its per-run listeners in its own `finally` block, preventing listener leaks.
- **Test coverage is appropriate.** `notification-server.test.ts` validates all HTTP status codes (200, 400, 413, 404), lifecycle transitions (start → stop → restart), and edge cases (unstarted stop, oversized payload, invalid JSON). `notification-bus.test.ts` validates isolation between run channels, multiple listeners, and unsubscription.
- **Per-run event channels are a sound design choice.** Using `notification:<runId>` as the channel key (rather than a single shared channel) means listeners are scoped exactly to their run, avoiding accidental cross-run wake-ups and keeping the EventEmitter per-event listener count at 1 regardless of concurrency.
