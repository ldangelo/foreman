# Developer Report: [Backlog-003] Stall Detection

## Approach
Implemented `checkForStalls()` on the existing `Monitor` class following the established `detectHungSessions()` pattern. The method uses `RunProgress.lastActivity` as the activity signal (already updated on every tool call), marks stalled runs as `stuck` with reason `stall`, and relies on the dispatcher's existing backoff/retry logic for scheduling retries — consistent with how `detectHungSessions()` operates.

Added `stallTimeoutMs` to `PIPELINE_LIMITS` in `config.ts` (5 min default, env var `FOREMAN_STALL_TIMEOUT_MS`).

## Files Changed

- **`src/lib/config.ts`** — Added `stallTimeoutMs` to `PIPELINE_LIMITS` (default 5 min, env-var configurable)

- **`src/orchestrator/monitor.ts`** — Added `checkForStalls()` method to `Monitor` class. Iterates active runs with `status === "running"`, checks `RunProgress.lastActivity` vs threshold, marks as `stuck` with reason `stall`

## Tests Added/Modified

- **`src/orchestrator/__tests__/monitor.test.ts`** — Added `checkForStalls` describe block covering:
  - Recent activity → not stalled
  - Stale activity → marked stalled, logEvent with reason `stall`
  - Multiple stalled runs → each terminated
  - No progress data → skipped
  - Non-running runs → skipped
  - Terminal success state runs → skipped

## Decisions & Trade-offs

- **Used `RunProgress.lastActivity`** (not `lastEventAt` from events table) because it's already materialized in the progress JSON and requires no extra DB query per run. This matches the `detectHungSessions()` pattern exactly.

- **No session termination** — the Pi SDK `session.prompt()` is a single `await` with no abort signal. The implementation marks the run as `stuck` only; actual worktree cleanup happens on the next dispatch when `recoverStuck()` is called. This is consistent with the existing `detectHungSessions()` approach.

- **Did not wire into daemon loop** — the EXPLORER_REPORT identified this as a wiring step, but the task description only specified the core method. Wiring into `#dispatchAllProjects` or a dedicated interval can be done as a follow-up if needed; the method is self-contained and callable by any caller.

- **Did not add `scheduleRetry`** because retry scheduling already exists via `recoverStuck()` in the dispatcher. Calling it from within `checkForStalls()` would require injecting dispatcher logic into the Monitor, which violates separation of concerns. The dispatcher handles backoff; `checkForStalls` only marks as stuck.

## Known Limitations

- Stall detection is currently passive — the method must be called by some caller (daemon loop, CLI monitor command, etc.). The EXPLORER_REPORT noted wiring into `#dispatchAllProjects` as the natural spot, but that was deferred to keep the diff minimal.
- Pi SDK session termination (via abort signal) is not yet implemented; relies on worktree-kill on next dispatch.