# Explorer Report: Ink TUI causes iTerm hanging/freezing

## Issue Summary
The Ink-based watch UI (`watchRunsInk` in `src/cli/watch-ui.ts`) causes iTerm to hang or freeze when monitoring agent runs. This occurs when `foreman run` is called with watch mode enabled (the default), which triggers the real-time status display.

## Relevant Files

### Core Problem
- **src/cli/watch-ui.ts** — React + Ink-based TUI component that monitors agent runs. Contains the main `watchRunsInk()` function (lines 324-355) which renders a live agent status display. Uses polling every 3 seconds to update state.
  - `WatchApp` component (line 287) — Main rendered component with agent cards and summary
  - `useWatchState` hook (line 240-251) — React hook that polls database every 3 seconds via `setInterval`
  - `watchRunsInk` function (line 324-355) — Entry point that calls `render()` from Ink library and manages polling loop

### Entry Points
- **src/cli/commands/run.ts** (lines 146, 81) — Calls `watchRunsInk(store, runIds)` in two places:
  - Line 81: Resume mode when `--watch` flag enabled after resuming stuck agents
  - Line 146: Normal watch loop that dispatches batches and watches until completion

### Data Source
- **src/lib/store.ts** — SQLite database queries:
  - `getRun(id)` (line 274) — Fetches individual run by ID
  - `getRunProgress(runId)` (line 340) — Parses progress JSON from runs table
  - Called continuously in `poll()` function (line 253) every 3 seconds from both React hook AND manual polling loop

### Alternative Implementations (Non-Ink)
- **src/cli/commands/monitor.ts** — Plain chalk-based status display (no Ink/React). Shows simple colored output without re-renders. Uses `monitor.checkAll()` with single-pass reporting.
- **src/cli/commands/status.ts** — Similar chalk-based status display. Shows project status, active agents, and metrics without real-time updates.

## Architecture & Patterns

### Identified Issues

#### 1. **Double Polling Pattern** (Lines 243-246 + 342-352)
The `watchRunsInk` function has TWO concurrent polling mechanisms:
- **React hook polling** (lines 243-246): `useEffect` with `setInterval` updating state every 3000ms
- **Manual while loop polling** (lines 342-352): Separate polling loop also waiting 3000ms between cycles

This creates a race condition where state updates may collide, causing excessive re-renders and terminal flooding.

```typescript
// React hook (line 244)
const interval = setInterval(() => {
  setState(poll(store, runIds));
}, 3_000);

// Manual loop (line 343-351)
while (!detached) {
  const state = poll(store, runIds);
  if (state.runs.length === 0 || state.allDone) {
    await new Promise((resolve) => setTimeout(resolve, 500));
    unmount();
    break;
  }
  await new Promise((resolve) => setTimeout(resolve, POLL_MS));
}
```

#### 2. **Complex React Tree**
The component hierarchy is deeply nested with multiple re-rendering layers:
- `WatchApp` → maps multiple `AgentCard` components (line 307-309)
- `AgentCard` → contains conditional rendering of multiple child components (lines 140-177)
- `ToolBreakdown` → renders array of tool entries (lines 74-94)
- `FilesChanged` → renders file list with conditional pagination (lines 97-114)

Each poll cycle (every 3 seconds) triggers full re-evaluation of this entire tree, potentially generating large terminal escape code sequences.

#### 3. **Resource Cleanup Uncertainty**
- Line 327: `render()` called with `exitOnCtrlC: false` (non-standard exit behavior)
- Line 334-339: Manual SIGINT handler with `unmount()` call, but `unmount()` behavior with nested render/state updates unclear
- No explicit cleanup of the React effect's `setInterval` when `unmount()` is called

#### 4. **Terminal Escape Code Overhead**
Ink generates ANSI escape codes for colors, positioning, and clearing. With a 3-second polling interval and complex nested components rendering every poll cycle, this creates excessive terminal I/O that iTerm may struggle to handle, especially with large agent counts.

#### 5. **No Fallback Mechanism**
The watch UI is hardcoded to use Ink. No environment variable or flag to fall back to simpler chalk-based output on problematic terminals.

### Existing Patterns for Reference

**Non-Ink status display approach** (from `monitor.ts` and `status.ts`):
- Uses `chalk` for coloring only (no terminal control)
- Single-pass information gathering (no polling loops)
- Stateless output — each invocation is independent
- Simple to understand and debug

## Dependencies

### Direct Dependencies
- **ink@6.8.0** — React-based TUI renderer (used for watch UI only)
- **ink-spinner@5.0.0** — Spinner component for Ink (used in watch UI)
- **react@19.2.4** — JSX/component rendering
- **chalk@5.6.2** — Terminal color library (used throughout, including in monitor/status commands)

### Data Dependencies
- **better-sqlite3** — Database queries in `poll()` function called every 3 seconds
- **ForemanStore** — Abstracts database access; performance depends on query efficiency

### Inverse Dependencies
- **src/cli/commands/run.ts** — Only place that calls `watchRunsInk()`
- **src/cli/index.ts** — CLI entry point that registers run command

## Existing Tests

### Test Files
- **src/cli/__tests__/status-display.test.ts** — Tests parsing logic and status display format (6KB file). Tests mirror logic from `status.ts` (non-Ink display), NOT from `watch-ui.ts`. This indicates the non-Ink status display is considered more stable/testable.
- **src/cli/__tests__/commands.test.ts** — General command tests (not examined in detail)

### Notable Gap
- **No tests for watch-ui.ts** — The problematic Ink TUI component has no test coverage. This is likely because testing Ink renders is complex and terminal-dependent.

## Recommended Approach

### Option 1: Replace Ink with Chalk-Based Display (Recommended)
**Pros**: Eliminates iTerm hanging, simpler code, testable, matches existing patterns in monitor.ts/status.ts
**Cons**: Loses real-time animation/spinner effects

**Implementation Steps**:
1. Refactor `watchRunsInk()` to use a simple polling loop (single, not double)
2. Output status using `chalk` for colors and Unicode symbols (matching monitor.ts style)
3. Clear terminal and print updated status each poll cycle (similar to `watch` command behavior)
4. Eliminate React/Ink dependency for this component
5. Add tests for polling logic (easier without Ink/React complications)

**Key files to modify**:
- `src/cli/watch-ui.ts` — Complete rewrite using chalk instead of React+Ink
- `src/cli/commands/run.ts` — Update import to new polling function (no behavior change needed)

### Option 2: Fix Double Polling + Add Fallback
**Pros**: Preserves Ink animations, backward compatible
**Cons**: More complex, Ink still may have terminal issues

**Implementation Steps**:
1. Eliminate the manual while loop (lines 342-352)
2. Keep only the React effect polling
3. Properly manage SIGINT handler to prevent double-fire
4. Add `--no-watch-ui` flag or `FOREMAN_NO_WATCH_UI=1` env var to fall back to chalk-based display
5. Improve cleanup of React effect when unmounting

### Option 3: Reduce Polling Frequency + Simplify Components
**Pros**: Reduces terminal I/O load while keeping Ink
**Cons**: Status updates become slower (less real-time feel)

**Implementation Steps**:
1. Increase polling interval from 3 seconds to 5-10 seconds
2. Remove unnecessary re-renders (memoize components)
3. Use Ink's built-in `staticOutput` for completed agents to reduce terminal updates

## Potential Pitfalls & Edge Cases

1. **Signal Handling**: SIGINT may fire multiple times due to the double polling. Ensure robust detach logic.

2. **Database Lock Contention**: Each poll cycle hits SQLite. With multiple agents writing progress simultaneously, this could bottleneck. Consider caching progress data in memory between polls.

3. **Large Agent Counts**: With 5-10 agents, the React component tree becomes very large. Component memoization or virtualization may be needed.

4. **Terminal Resize**: Ink handles terminal resize events. Chalk-based approach needs manual handling if we switch.

5. **MacOS vs Linux vs Windows**: iTerm is macOS-specific. Test chosen solution across all platforms to ensure no regressions.

6. **Ctrl+C Handling**: Current implementation disables `exitOnCtrlC` and manages SIGINT manually. Any refactor must preserve this behavior (allowing background agents to continue).

## Summary

The Ink TUI causes iTerm hanging due to **double polling + complex React rendering + excessive terminal I/O**. The simplest fix is **Option 1: Replace with chalk-based display** (similar to existing monitor.ts/status.ts commands), which eliminates the architectural problems entirely. Option 2 is safer if Ink aesthetics are important, but requires careful refactoring of the polling/cleanup logic.
