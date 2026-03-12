# Explorer Report: Interactive expandable agent status with summary/detail toggle

## Summary

This task adds interactive expand/collapse functionality with summary/detail view toggling to the agent status displays in Foreman. Users should be able to toggle between compact summary view (showing just essentials) and full detail view (showing all metrics) for each agent, both in the `foreman run --watch` command and the `foreman status` command.

## Relevant Files

### Core Display Files

1. **src/cli/watch-ui.ts** (251 lines)
   - **Purpose**: Renders real-time agent status during `foreman run --watch` execution
   - **Key functions**:
     - `renderAgentCard(run: Run, progress: RunProgress | null)` (lines 57-120) — Renders full details for a single agent
     - `renderWatchDisplay(state: WatchState, showDetachHint = true)` (lines 169-215) — Renders entire watch UI with all agent cards
     - `watchRunsInk(store, runIds)` (lines 219-250) — Main loop that polls store every 3s and renders display
   - **Current behavior**: Always shows full details (model, cost, turns, tools, tool breakdown, files changed)
   - **Expansion needs**: Add expand/collapse state management and render summary version when collapsed

2. **src/cli/commands/status.ts** (185 lines)
   - **Purpose**: Shows project status from seeds + SQLite (one-time display, not real-time)
   - **Key function**: `renderStatus()` (lines 15-155) — Shows task counts, active agents, and progress details
   - **Line 107-138**: Shows agent progress details including phase, last tool, stats, cost
   - **Current behavior**: Shows brief inline details for each active agent
   - **Expansion needs**: Add expandable detail pane for each agent in status display

### Data Structures

3. **src/lib/store.ts** (lines 18-75)
   - **Run interface** (lines 18-30): Contains run status and metadata
   - **RunProgress interface** (lines 64-75): Contains all progress metrics (turns, tool calls, files changed, cost, phase)
   - **WatchState interface** in watch-ui.ts (lines 124-133): Aggregates run + progress pairs and summary totals

### Test Files

4. **src/cli/__tests__/watch-ui.test.ts** (375+ lines)
   - Tests for `renderAgentCard()` at lines 114-175
   - Tests for `renderWatchDisplay()` at lines 217-375
   - Tests helper functions (`elapsed()`, `shortModel()`, `shortPath()`)
   - **No tests yet** for interactive/expand/collapse behavior

5. **src/cli/__tests__/status-display.test.ts** (100+ lines)
   - Tests parsing logic and status display format
   - Tests helper functions used by status.ts

### Entry Points

6. **src/cli/commands/run.ts**
   - Line 146: Calls `watchRunsInk(store, runIds)` in main dispatch loop
   - Provides runIds to display

7. **src/cli/commands/status.ts**
   - Lines 160-184: Implements `--watch [seconds]` option with polling loop
   - Could benefit from expand/collapse functionality in watch mode

## Architecture & Patterns

### Current Display Architecture

1. **Static Rendering Model**:
   - `renderAgentCard()` is pure function that takes run + progress, returns formatted string
   - `renderWatchDisplay()` composes multiple agent cards into full display
   - `watchRunsInk()` repeatedly clears terminal and writes new display string

2. **Polling Pattern**:
   - `watchRunsInk()` polls SQLite every 3 seconds via `poll()` function
   - `poll()` aggregates state from store into `WatchState` object
   - Full screen cleared with ANSI codes: `\x1B[2J\x1B[H`

3. **Chalk for Styling**:
   - Uses chalk for colors, icons, and formatting (no Ink/React)
   - STATUS_ICONS record (lines 28-37) maps status to Unicode symbols
   - `statusColor()` function (lines 39-51) applies appropriate colors

### Summary vs Detail Requirements

**Summary View** should show:
- Agent seed ID (e.g., "foreman-f18c")
- Status icon + status text (e.g., "● RUNNING")
- Elapsed time (e.g., "1m 30s")
- Model name (e.g., "sonnet-4-6")
- Current phase (if available) OR last tool
- Cost in green (e.g., "$0.0123")
- Expandable indicator (e.g., "▶" when collapsed, "▼" when expanded)

**Detail View** should show:
- Everything from summary
- Tool breakdown with bar chart (lines 89-101)
- Files changed list with pagination (lines 104-112)
- Full metrics (turns, tool count, detailed breakdown)
- Log hint for failed runs (lines 115-117)

### Interactive State Management

Key design consideration:
- Need to track expanded/collapsed state for each agent across poll cycles
- Could store in-memory map: `Map<run.id, isExpanded: boolean>`
- Keyboard input: likely arrow keys (up/down) to select, Enter/Space to toggle
- Or simpler: number keys (1, 2, 3) to toggle specific agent, or single key to toggle all

## Dependencies

### External Dependencies
- **chalk** — Color and formatting (already in use)
- **commander** — CLI argument parsing (already in use)
- **better-sqlite3** — Store access (already in use)
- No new dependencies required for basic expand/collapse

### Internal Dependencies
- `watch-ui.ts` imports from `store.ts` (data structures)
- `commands/run.ts` imports `watchRunsInk` from `watch-ui.ts`
- `commands/status.ts` uses `ForemanStore` directly

### Inverse Dependencies (what depends on this)
- `run.ts` calls `watchRunsInk()` — must maintain same function signature
- `status.ts` implements its own display separately — can add expand/collapse independently

## Existing Tests

### Test Coverage for watch-ui.ts

1. **renderAgentCard tests** (src/cli/__tests__/watch-ui.test.ts:114-175)
   - Tests basic output contains seed_id, status, model
   - Tests "Initializing..." message for running runs
   - Tests cost, turns, tools display
   - **No tests** for expanded/collapsed states

2. **renderWatchDisplay tests** (src/cli/__tests__/watch-ui.test.ts:217-375)
   - Tests header, agent cards, summary bar
   - Tests completion banner
   - Tests empty state, multi-agent scenarios
   - **No tests** for interactive toggles

3. **Helper function tests** (lines 57-110)
   - Tests for `elapsed()`, `shortModel()`, `shortPath()`
   - Should continue to work unchanged

### Test Coverage for status.ts
- Minimal test coverage; `status-display.test.ts` focuses on parsing logic
- Tests don't cover agent detail rendering specifically

## Recommended Approach

### Phase 1: Add Expand/Collapse State to watch-ui.ts

1. **Create ExpandState management**:
   - Add interface: `interface WatchUIState { expandedRunIds: Set<string> }`
   - Modify `watchRunsInk()` to maintain this state across poll cycles
   - Track which agents are expanded (use `run.id` as key)

2. **Implement summary rendering function**:
   - Extract summary-only rendering into separate function: `renderAgentCardSummary(run, progress)`
   - Shows: status icon, seed_id, status, elapsed, model, last phase/tool, cost, expand indicator
   - Approximately 2-3 lines of output

3. **Modify renderAgentCard()**:
   - Add parameter: `isExpanded: boolean` (default true for backward compat during first iteration)
   - Conditionally render full details only if `isExpanded === true`
   - Otherwise render summary view

4. **Add keyboard input handling**:
   - Detect 'a' key to toggle all agents (simplest interactive feature)
   - Or: number keys (1, 2, etc.) to toggle specific agent
   - Or: arrow keys + Enter for selection (more complex)
   - Start with simple 'a' key toggle for MVP

5. **Update renderWatchDisplay()**:
   - Receive expanded state from main loop
   - Pass `isExpanded` flag to `renderAgentCard()` calls
   - Update Ctrl+C hint to mention toggle key

### Phase 2: Add similar interactivity to status.ts

1. **Add --detailed/-d flag** to `foreman status` command
   - Default: shows summary (matching current inline display)
   - With flag: shows full expanded details

2. **Or: interactive mode with --watch**
   - When status --watch enabled, detect keyboard input
   - Toggle between summary and detail views

### Phase 3: Testing

1. **Update existing tests**:
   - Adjust `renderAgentCard()` tests to check for summary output when `isExpanded=false`
   - Add tests for `renderAgentCardSummary()` function

2. **Add new tests**:
   - Test expand/collapse state management
   - Test keyboard input detection
   - Test toggle behavior (summary ↔ detail)

### Phase 4: Polish

1. **Document** the new keyboard shortcut in help text and Ctrl+C hint
2. **Consider UX**:
   - Should agents start expanded or collapsed? (recommend: collapsed for clean view)
   - Make expand indicator very visible (▼/▶ unicode chars)
3. **Edge cases**:
   - What if agent count changes during watch? (set remains valid, just new agents default to collapsed)
   - Handle terminal resize gracefully (already managed by simple string rendering)

## Potential Pitfalls & Edge Cases

1. **Keyboard Input in Node.js**
   - Detecting keyboard in Node CLI without external library is complex
   - Consider using `keypress` library or `readline` with `getRawMode()`
   - Or simpler: use standard input with typed characters (watch for 'a' key)
   - Test across platforms (macOS iTerm, Linux, Windows)

2. **State Persistence**
   - Expand/collapse state resets when terminal resized or display refreshes
   - Consider storing in instance variable that persists across poll cycles

3. **Performance with Many Agents**
   - With 5-10 agents, toggling to summary view significantly reduces terminal I/O
   - May help with previous iTerm hanging issues (watch-ui.ts line 1 comment)

4. **Backward Compatibility**
   - Changing `renderAgentCard()` signature breaks existing tests
   - Add optional parameter with default value: `isExpanded = true` for now
   - Plan to change default to `false` in next phase if summary view becomes primary

5. **Watch Mode in status.ts**
   - The --watch flag was recently added (commit af2d6d7)
   - Keyboard handling must work in both commands' polling loops

6. **Signal Handling**
   - Current code handles SIGINT (Ctrl+C) to detach agents
   - Keyboard input handling must not interfere with signal handlers
   - Use process.stdin event listeners carefully

## Next Steps for Developer

1. **Start with watch-ui.ts summary rendering**
   - Create `renderAgentCardSummary()` function
   - Add `isExpanded` parameter to `renderAgentCard()`
   - Add simple 'a' key toggle in `watchRunsInk()`

2. **Implement state management**
   - Add `expandedRunIds` Set to track expanded agents
   - Update on 'a' key press
   - Persist across poll cycles

3. **Write tests**
   - Test `renderAgentCardSummary()` output
   - Test toggle behavior
   - Test rendering with `isExpanded=false`

4. **Test with real agent runs**
   - Run `foreman run` with multiple agents
   - Verify toggle works smoothly
   - Check for any performance improvements

5. **Later: apply to status.ts**
   - Add --detailed flag
   - Or add keyboard handling in watch mode
