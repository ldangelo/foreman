# Explorer Report: Unify agent status display between status and run commands

## Summary
The `foreman status` and `foreman run` commands display agent status information inconsistently. The `run` command uses rich, interactive UI functions from `watch-ui.ts`, while the `status` command reimplements similar logic with different formatting. This creates maintenance burden and inconsistent user experience.

## Relevant Files

### Primary Files (Agent Display Logic)
- **src/cli/commands/status.ts** — Displays project status including task counts and active agents (lines 89-152)
  - Current implementation: Custom agent status rendering with simpler formatting
  - Shows: seed_id, status (lowercase), elapsed time (minutes only), agent_type badge, progress details, phase info

- **src/cli/watch-ui.ts** — Reusable functions for rendering agent status cards (416 lines)
  - `renderAgentCard(run, progress, isExpanded, index)` — Full or collapsed agent card (lines 98-167)
  - `renderAgentCardSummary(run, progress, index)` — Collapsed single-line summary (lines 62-90)
  - `poll(store, runIds)` — Poll and aggregate run data (lines 182-214)
  - `renderWatchDisplay(state, showDetachHint, expandedRunIds)` — Full display with multiple agents (lines 227-290)
  - Helper functions: `elapsed()`, `shortModel()`, `shortPath()` (lines 7-26)
  - STATUS_ICONS map for status indicators (lines 28-37)
  - Helper: `statusColor()` for status-based coloring (lines 39-51)

### Test Files
- **src/cli/__tests__/status-display.test.ts** — Tests for status command display logic (202 lines)
  - Tests for `parsePipelinePhase()` logic (pipeline phase parsing from lastToolCall)
  - Tests for sub-agent count display logic
  - Note: These tests verify internal logic, not the output formatting

- **src/cli/__tests__/watch-ui.test.ts** — Comprehensive tests for watch-ui rendering (709 lines)
  - Tests for `elapsed()`, `shortModel()`, `shortPath()` helpers
  - Tests for `renderAgentCard()` and `renderAgentCardSummary()`
  - Tests for `poll()` state aggregation
  - Tests for `renderWatchDisplay()` with various expand states
  - Tests for interactive vs non-interactive mode

### Related Files
- **src/lib/store.ts** — Data model definitions (lines 18-82)
  - `Run` interface: Contains agent metadata (seed_id, agent_type, status, timestamps)
  - `RunProgress` interface: Contains execution metrics (toolCalls, turns, cost, filesChanged, currentPhase)
  - Status values: "pending" | "running" | "completed" | "failed" | "stuck" | "merged" | "conflict" | "test-failed" | "pr-created"

- **src/cli/commands/run.ts** — Dispatch and watch command (169 lines)
  - Uses `watchRunsInk()` from watch-ui.ts (lines 9, 81, 150)
  - Handles interactive agent monitoring during dispatch

- **src/cli/commands/monitor.ts** — Simple agent status checking (106 lines)
  - Displays minimal agent info (seed_id, agent_type, elapsed)
  - Separate from both status.ts and watch-ui.ts

## Architecture & Patterns

### Current Status Display (status.ts, lines 96-139)
```
Active Agents:
  [badge] [seed_id] [status] [elapsed]
    └ [Phase: X | last: Y] [details]
    └ Cost: $X.XXXX
```

**Features:**
- Agent type badge with status-specific color (claude-code→blue, pi→green, other→magenta)
- Seed ID in cyan
- Status in lowercase, no color
- Elapsed time in minutes only
- Pipeline phase display with color-coded phase names
- Tool breakdown in activity string
- Sub-agent count display (Agent tool usage)
- Cost information
- Last tool call or phase info

### Current Watch Display (watch-ui.ts)
```
(Interactive Mode - Expandable)
  ▼ ● foreman-1a RUNNING 1m 30s  sonnet-4-6
    Model     sonnet-4-6
    Cost      $0.0123
    Turns     5
    Tools     12 (last: Edit)
    [tool breakdown with bars]
    Files     2
      src/foo.ts
      src/bar.ts

(Collapsed Mode)
  ▶ ● foreman-1a RUNNING 1m 30s  sonnet-4-6  [developer]  $0.0123  5t 12 tools
```

**Features:**
- Status icon (●, ✓, ✗, ⚠, etc.) based on status
- Seed ID in cyan (bold)
- Status in uppercase, colored by status type
- Elapsed time formatted detailed (45s, 1m 30s, 1h 5m)
- Model name via `shortModel()` helper
- Expand/collapse indicators (▼/▶) for interactive mode
- Tool breakdown with mini bar chart
- Files changed with paths (up to 5 with "+N more" fallback)
- Log hint for failed runs
- Numeric index prefix for multiple agents
- Cost information
- Summary bar with aggregated stats

### Key Differences Table

| Feature | status.ts | watch-ui.ts |
|---------|-----------|------------|
| Status display | lowercase, no color | UPPERCASE, colored |
| Status icons | None | ●✓✗⚠⊕⊘ |
| Elapsed time | Minutes only (90m) | Detailed (1m 30s) |
| Agent type | Badge with status color | shortModel() cleaned |
| Expand/collapse | None | Yes (interactive mode) |
| Phase display | `Phase: X` with color | `[X]` in brackets |
| Tool breakdown | As text string | Mini bar chart |
| Files shown | Count + list | Up to 5 + "+N more" |
| Log hints | None | ~/.foreman/logs/run.log |
| Numeric index | None | 1. 2. 3. for multiple agents |

## Dependencies

### What Imports watch-ui.ts
- `src/cli/commands/run.ts` — imports `watchRunsInk, WatchResult`

### What Imports status.ts
- `src/cli/index.ts` — imports `statusCommand` as part of CLI commands

### watch-ui.ts Dependencies
- `chalk` — Terminal color/styling
- `src/lib/store.js` — ForemanStore, Run, RunProgress types

### status.ts Dependencies
- `chalk` — Terminal color/styling
- `commander` — CLI framework
- `execFileSync` — Run sd (seed) commands
- `src/lib/store.js` — ForemanStore, RunProgress types

## Existing Tests

### status-display.test.ts (202 lines)
Tests two internal functions not exported from status.ts:
- `parsePipelinePhase(lastToolCall)` — Extracts phase name and retry count from tool call string
  - Matches pattern: `^(explorer|developer|qa|reviewer|finalize):(\S+)(?: \(retry (\d+)\))?$`
  - Used to distinguish pipeline runs from single-agent runs
  - Tests: 18 test cases covering all phases, retry counts, edge cases

- `formatAgentActivity(progress)` — Determines display text for active agent
  - Shows sub-agent count if `toolBreakdown.Agent > 0`
  - Falls back to `last: <toolName>`
  - Tests: 8 test cases covering different sub-agent scenarios

**Note:** These tests verify business logic, not UI output. They don't test `renderStatus()`.

### watch-ui.test.ts (709 lines)
Comprehensive test coverage for all exported functions:
- `elapsed()` — 4 tests for time formatting
- `shortModel()` — 3 tests for model name cleaning
- `shortPath()` — 3 tests for path shortening
- `renderAgentCard()` — 14 tests covering expanded/collapsed modes, progress display, file lists
- `renderAgentCardSummary()` — 9 tests for single-line summary formatting
- `poll()` — 12 tests for state aggregation and counting
- `renderWatchDisplay()` — 28 tests covering interactive/non-interactive modes, hints, banners, multiple agents

**Coverage:** All exported rendering functions are well-tested.

## Recommended Approach

### Strategy: Unified Agent Display Using watch-ui.ts Functions

The goal is to make agent status display consistent between `foreman status` and `foreman run` commands by leveraging the well-tested `watch-ui.ts` functions.

### Implementation Plan

#### Phase 1: Refactor status.ts to use watch-ui.ts functions
1. **Import functions from watch-ui.ts:**
   - Import: `renderAgentCard`, `elapsed`, `shortModel`, `renderWatchDisplay`, `poll` helpers

2. **Replace custom rendering in status.ts (lines 96-139):**
   - Replace the custom agent loop with `renderWatchDisplay()` or individual `renderAgentCard()` calls
   - Use `elapsed()` helper instead of manual elapsed calculation
   - Use `shortModel()` instead of direct agent_type display
   - Use status icons and colored status from watch-ui.ts

3. **Handle differences:**
   - **Phase display:** Watch-ui.ts uses `currentPhase` directly, but status.ts parses pipeline info from `lastToolCall`
     - Solution: Ensure `RunProgress.currentPhase` is always set correctly (check agent-worker.ts implementation)
   - **Non-interactive mode:** status.ts is non-interactive (no keyboard handling)
     - Solution: Call `renderWatchDisplay(state, showDetachHint=false)` (see line 584 in watch-ui.test.ts)
   - **Sub-agent count:** Watch-ui.ts already shows this in activity string via `progress.toolBreakdown["Agent"]`
     - Verify current implementation handles this correctly

#### Phase 2: Update tests
1. **Extend watch-ui.test.ts:**
   - Add tests for non-interactive `renderWatchDisplay()` with `expandedRunIds=undefined`
   - Verify all features (phase display, sub-agent count, etc.) work in non-interactive mode

2. **Keep status-display.test.ts logic:**
   - If `parsePipelinePhase()` is still needed for backward compatibility or other code paths, keep those tests
   - Remove duplicated agent rendering logic tests (migrate to watch-ui.test.ts)

#### Phase 3: Simplify monitor.ts (optional enhancement)
- Consider using `renderAgentCardSummary()` instead of custom formatting
- Would give consistent single-line display across all commands

### Potential Pitfalls & Edge Cases

1. **Pipeline Phase Detection**
   - **Issue:** status.ts detects phase from `lastToolCall` string parsing, watch-ui.ts uses `currentPhase` field
   - **Solution:** Ensure `agent-worker.ts` sets `currentPhase` consistently, then trust that field
   - **Test:** Verify pipeline run display in status command matches run command

2. **Non-Interactive Mode Behavior**
   - **Issue:** watch-ui.ts is designed for interactive mode with expand/collapse
   - **Solution:** Pass `expandedRunIds=undefined` to force all cards expanded, and `showDetachHint=false`
   - **Test:** Ensure status command doesn't show "Ctrl+C" or toggle hints

3. **Project Not Registered**
   - **Issue:** status.ts handles case where project isn't in ForemanStore (line 150)
   - **Solution:** Keep that check; only use watch-ui functions when runs exist
   - **Test:** `foreman status` on new project should still show "no agents running" message

4. **Empty Progress Data**
   - **Issue:** Both commands handle runs with `progress=null`
   - **Solution:** watch-ui functions already handle this (see watch-ui.test.ts line 443-451)
   - **Test:** Verify pending/initializing agents display correctly

5. **Backward Compatibility**
   - **Issue:** Existing code may depend on status.ts output format
   - **Solution:** This is a bug fix/feature improvement, not a breaking change to API
   - **Test:** Manual testing of `foreman status` and `foreman run` output

### Code Location Summary
- **Main changes:** `src/cli/commands/status.ts` (lines 96-139, and imports at top)
- **Test updates:** `src/cli/__tests__/watch-ui.test.ts` (verify non-interactive mode coverage)
- **No changes needed:** `src/cli/watch-ui.ts` (functions are general-purpose)
- **Optional:** `src/cli/commands/monitor.ts` (use for consistent summary display)

### Success Criteria
1. ✓ Agent status display in `foreman status` uses same formatting as `foreman run`
2. ✓ Shows status icons, uppercase status text, detailed elapsed time
3. ✓ Shows phase info for pipeline runs (currently from `currentPhase` field)
4. ✓ Shows file lists and tool breakdowns when available
5. ✓ All existing tests pass
6. ✓ New test coverage for status.ts agent display via watch-ui functions
7. ✓ Non-interactive mode works correctly (no interactive hints in status command)
