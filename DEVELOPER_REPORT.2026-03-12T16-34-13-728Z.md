# Developer Report: Unify agent status display between status and run commands

## Approach

Replaced the custom agent rendering loop in `status.ts` with calls to `renderAgentCard()` from `watch-ui.ts`. This was a minimal, focused change: instead of reimplementing formatting logic, the status command now delegates to the same battle-tested rendering functions that `foreman run` uses.

The key insight is that `watch-ui.ts` already exports `renderAgentCard(run, progress)` as a pure function — it takes a `Run` and optional `RunProgress` and returns a formatted string. `status.ts` already has the `ForemanStore` instance available, so calling `store.getRunProgress(run.id)` to get the progress object was straightforward.

## Files Changed

- **src/cli/commands/status.ts** — Replaced the 40-line custom agent rendering block (manual elapsed calculation, custom badges, phase/tool/cost formatting) with a 3-line loop using `renderAgentCard()`. Added import for `renderAgentCard` from `watch-ui.ts`. Removed the now-unused `RunProgress` type import from `store.ts`.

## Tests Added/Modified

- **src/cli/__tests__/watch-ui.test.ts** — Added 9 new tests covering non-interactive mode (the mode used by `foreman status`):
  - Verifies no Ctrl+C/detach hint shown when `showDetachHint=false`
  - Verifies status icons (●, ○) appear in non-interactive output
  - Verifies uppercase status text (RUNNING, COMPLETED, PENDING)
  - Verifies detailed elapsed time format (`1m 30s`, not minutes-only)
  - Verifies short model name display (`sonnet-4-6` not `claude-sonnet-4-6`)
  - Verifies tool breakdown displayed when progress is available
  - Verifies file list displayed when progress is available
  - Verifies log hint shown for failed runs
  - Verifies pending agent display

## Decisions & Trade-offs

- **Used `renderAgentCard` directly rather than `renderWatchDisplay`**: `renderWatchDisplay` adds a "Foreman — agent monitor" header and summary bar that would clash with the existing `status.ts` output structure (which has its own "Active Agents" header and cost summary). Using `renderAgentCard` per run is cleaner and keeps the status command's existing structure intact.

- **Kept existing tests in `status-display.test.ts`**: The `parsePipelinePhase()` and `formatAgentActivity()` logic tests remain valid as documentation of the original behavior. They don't block on the refactored rendering code.

- **No changes to `watch-ui.ts`**: The functions were already general-purpose; no modifications needed.

## Known Limitations

- The `status-display.test.ts` tests now test logic that is no longer used in production code (the `parsePipelinePhase` and `formatAgentActivity` functions they mirror were removed from `status.ts`). These could be cleaned up in a future refactor, but are harmless to keep as behavioral documentation.
- Phase display (pipeline phase info) is now handled by `renderAgentCard`'s standard display, which shows `currentPhase` as part of the progress section. The previous custom colored phase display (`Phase: explorer  last: Bash`) is replaced with `watch-ui`'s consistent formatting.
