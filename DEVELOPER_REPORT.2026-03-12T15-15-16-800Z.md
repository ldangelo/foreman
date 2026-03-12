# Developer Report: Event-driven status refresh via agent worker notifications

## Approach

Addressed all four [NOTE] items raised in the previous code review. The core implementation (HTTP-based notification system) was already in place and had received a PASS verdict; this iteration is a focused polish pass making the defensive guards explicit, raising the EventEmitter listener cap, and documenting two acknowledged asymmetries in inline comments.

## Files Changed

- `src/orchestrator/notification-bus.ts` — Added explicit constructor that calls `this.setMaxListeners(0)`. Per-run channels each have at most 1 listener in current usage, so the default Node.js cap of 10 is never hit; the change guards against future consumers subscribing to the global `"notification"` channel from many places simultaneously. Inline comment explains the rationale.

- `src/orchestrator/notification-server.ts` — Added `let responded = false` guard flag to the POST /notify handler. The flag is set before every `res.end()` call; the `"end"` event handler checks it at entry. This makes the intent explicit and protects against future refactors inadvertently producing a second response after the 413 oversized-payload path already replied and called `req.destroy()`.

- `src/orchestrator/agent-worker.ts` — Added a block comment above the single-agent `for await` loop documenting the intentional asymmetry: single-agent mode emits only terminal status notifications, while pipeline mode (`runPhase`) emits a progress notification after every assistant turn. Explains that single-agent progress is flushed to SQLite every 2 s and the polling fallback preserves live-UI benefit.

- `src/cli/commands/run.ts` — Expanded the notification-server startup comment to note that `monitor.ts` is not yet wired to `notificationBus`, why (API refactoring needed), and that it is deferred to a follow-up task.

## Tests Added/Modified

No new tests needed — all changes are defensive guards and documentation. The 17 existing notification tests (`notification-bus.test.ts`, `notification-server.test.ts`) continue to pass, and TypeScript compiles cleanly (`tsc --noEmit` exits 0).

## Decisions & Trade-offs

1. **`setMaxListeners(0)` vs `setMaxListeners(100)`**: Used `0` (unlimited) rather than an arbitrary ceiling. The singleton `notificationBus` is shared by every watched run; the correct bound is the number of concurrent watched runs, which is not statically known. Unlimited is the safer default.

2. **`responded` flag set at every branch**: Rather than a single set-at-end pattern, the flag is set immediately before each `res.end()` call. This makes each branch self-contained and safe regardless of future additions to the handler.

3. **Comments over code changes for agent-worker asymmetry**: The asymmetry between single-agent and pipeline progress notification is intentional by design. A comment is the right tool here — changing the code to add progress notifications in single-agent mode is a separate concern deferred to a follow-up.

## Known Limitations

- **monitor.ts not wired up** (pre-existing, documented in run.ts comment): The monitoring process still uses its polling-only loop. Deferred.
- **No notification persistence** (pre-existing): Notifications dropped if the foreman watch session exits. SQLite remains source of truth.
- **No deduplication** (pre-existing): Rapid notifications may wake the UI loop multiple times; harmless since each wake re-polls SQLite.
