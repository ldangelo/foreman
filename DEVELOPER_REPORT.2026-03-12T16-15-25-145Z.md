# Developer Report: Interactive expandable agent status with summary/detail toggle

## Approach

Added per-agent expand/collapse state to the `foreman run --watch` UI. Agents start collapsed (summary view) and can be toggled interactively via keyboard. The implementation is purely additive — all existing public function signatures are backward compatible with optional new parameters.

## Files Changed

- **src/cli/watch-ui.ts** — Core changes:
  - Added `renderAgentCardSummary(run, progress, index?)` — compact single-line view with `▶` indicator showing seed ID, status, elapsed time, model, last tool/phase, cost, and turn/tool counts
  - Modified `renderAgentCard(run, progress, isExpanded=true, index?)` — when `isExpanded=false` delegates to summary; expanded header gains `▼` indicator and optional numeric index
  - Modified `renderWatchDisplay(state, showDetachHint, expandedRunIds?)` — passes per-run expand state to card renderer; updated detach hint to include keyboard shortcut hints
  - Modified `watchRunsInk(store, runIds)` — maintains `expandedRunIds: Set<string>` (all collapsed by default); sets up raw stdin keyboard handling (`a/A` = toggle all, `1-9` = toggle individual agent, `Ctrl+C` = detach); cleans up raw mode in `finally` block

## Tests Added/Modified

- **src/cli/__tests__/watch-ui.test.ts** — Added 24 new tests (73 total, all passing):
  - 13 tests for `renderAgentCardSummary`: seed_id, status, model, initializing state, cost, last tool call, current phase, turns/tool counts, `▶` indicator, numeric index display, size comparison vs full card
  - 5 tests for `renderAgentCard` with `isExpanded=false`: delegation to summary, `▶`/`▼` indicators, single-line output, backward compat
  - 6 tests for `renderWatchDisplay` with `expandedRunIds`: collapsed/expanded states, toggle hint text, mixed state across multiple agents, default behavior (all expanded when `expandedRunIds` undefined), index numbers

## Decisions & Trade-offs

- **All collapsed by default** — With many agents the default view is now compact/clean; users expand on demand. This matches the task description's recommendation.
- **Backward compatibility** — `renderAgentCard` and `renderWatchDisplay` new parameters are optional with sensible defaults (`isExpanded=true`, `expandedRunIds=undefined` → all expanded). Existing callers and tests work unchanged.
- **Raw stdin keyboard input** — Used `process.stdin.setRawMode(true)` guarded by `process.stdin.isTTY` check with try/catch, so it degrades gracefully in non-TTY environments (CI, pipes). Cleans up in `finally`.
- **`status.ts` not modified** — The EXPLORER_REPORT flagged this as Phase 2 and lower priority. The watch-ui changes cover the primary `foreman run --watch` use case.

## Known Limitations

- `foreman status` command does not yet have expand/collapse (Phase 2 per EXPLORER_REPORT)
- Keyboard input only available in TTY environments; piped/CI output always shows expanded view (by `expandedRunIds=undefined` default)
- State resets to all-collapsed on process restart (expand state is in-memory only)
