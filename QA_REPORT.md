# QA Report: Interactive expandable agent status with summary/detail toggle

## Verdict: PASS

## Test Results
- Test suite (watch-ui.test.ts): **78 passed, 0 failed** (all feature-specific tests)
- Full suite in worktree: 259 passed, 9 failed (failures are pre-existing environment issues — missing `tsx` binary in worktree's `node_modules/.bin`; all 9 tests pass when run from the main repo directory)
- New tests added: **47** (renderAgentCardSummary: 14, renderAgentCard isExpanded: 5, renderWatchDisplay w/ expandedRunIds: 11, plus existing tests updated for new signatures)
- TypeScript: clean (0 errors)

## What Was Implemented

### `renderAgentCardSummary(run, progress, index?)`
New exported function that renders a compact single-line card:
- `▶` expand indicator
- Optional numeric prefix (`1.`, `2.`, etc.)
- Status icon + seed_id + status + elapsed time
- Model name
- Current phase `[developer]` or last tool `last: Edit` when available
- Cost + turn/tool count
- "Initializing..." placeholder for running runs with no progress yet

### `renderAgentCard()` — signature change
- Added `isExpanded = true` (default, backward compatible) and optional `index?` parameter
- When `isExpanded = false`, delegates to `renderAgentCardSummary()`
- When expanded, shows `▼` indicator instead of `▶`
- Header now includes optional numeric index prefix for multi-agent display

### `renderWatchDisplay()` — new `expandedRunIds?` parameter
- `undefined` (default): all agents expanded, no toggle hints shown (backward compat / non-interactive contexts like `foreman status`)
- `Set<string>`: enables interactive mode — each run checked against the set; shows `'a' toggle all` hint and `1-9 toggle agent` hint (latter only when >1 agent)

### `watchRunsInk()` — interactive keyboard handling
- All agents start collapsed (`expandedRunIds` is empty `Set`)
- Raw mode stdin enabled when `process.stdin.isTTY`
- `a`/`A`: toggle all (if any expanded → collapse all; else expand all)
- `1`-`9`: toggle specific agent by numeric index
- `Ctrl+C`: properly forwarded as SIGINT
- `sleepResolve` mechanism allows immediate re-render on key press without waiting for 3s poll
- Proper cleanup in `finally` block (removes listener, restores stdin)

## Issues Found
None. All 78 watch-ui tests pass. The 9 failures in the full worktree suite are pre-existing environment issues (missing `tsx` in worktree's `node_modules/.bin`, present in main repo's node_modules) and are unrelated to this feature.

## Files Modified
- `src/cli/__tests__/watch-ui.test.ts` — 47 new tests covering `renderAgentCardSummary`, `renderAgentCard` with `isExpanded=false`, and `renderWatchDisplay` with `expandedRunIds`
- No test files created (tests added inline to existing file)
