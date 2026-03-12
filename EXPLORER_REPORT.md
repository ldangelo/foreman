# Explorer Report: Agent observability: dashboard command with live TUI

## Summary

The Foreman orchestrator needs a new `foreman dashboard` command that provides live Text User Interface (TUI) observability for running agents. Currently, there is:
- A `foreman monitor` command that shows static agent status (completed, stuck, active, failed)
- A `foreman run --watch` mode that uses `watchRunsInk()` to display a polling-based animation
- A `foreman status` command that shows seeds + active agents with basic progress info

The new `dashboard` command should build on these existing patterns to provide a more comprehensive, interactive, real-time TUI that displays agent metrics, status transitions, and performance data.

## Relevant Files

### Core Data & State Management
- **src/lib/store.ts** (380+ lines) — SQLite-backed ForemanStore
  - Interfaces: `Project`, `Run`, `Event`, `Cost`, `RunProgress`
  - Methods for querying runs, progress, events, costs by various filters
  - `Run.status`: "pending" | "running" | "completed" | "failed" | "stuck" | "merged" | "conflict" | "test-failed" | "pr-created"
  - `RunProgress`: tracks toolCalls, filesChanged, turns, costUsd, currentPhase, etc.

- **src/orchestrator/monitor.ts** (~120 lines) — Agent monitoring logic
  - `Monitor` class with `checkAll()` method to categorize runs (active, completed, stuck, failed)
  - `recoverStuck()` method to handle stuck agents
  - Detects stuck agents based on elapsed time vs configurable timeout (default 15m)
  - Integrates with Beads CLI to check bead status

### Existing CLI Commands & UI
- **src/cli/index.ts** — CLI entry point with command registration (no dashboard command yet)

- **src/cli/commands/monitor.ts** (~100 lines) — Static status display
  - Uses `Monitor.checkAll()` to gather data
  - Prints colored text with status categorization
  - Shows elapsed time, agent type (model), and recovery options

- **src/cli/commands/status.ts** (~150 lines) — Project status display
  - Fetches seeds from Beads, queries active runs from store
  - Shows task counts (ready, in-progress, completed, blocked)
  - Displays active agent progress (turns, tools, files, phase, cost)
  - Parses pipeline phases from `lastToolCall` (e.g., "explorer:start", "developer:start (retry 1)")

- **src/cli/commands/run.ts** (~140 lines) — Task dispatcher with watch mode
  - Calls `watchRunsInk(store, runIds)` when `--watch` flag is used
  - Demonstrates watch pattern with polling loop (3s interval)

- **src/cli/watch-ui.ts** (~250 lines) — Existing TUI rendering logic ⭐ **KEY FILE**
  - Helper functions: `elapsed()`, `shortModel()`, `shortPath()`
  - Status icons and color mapping for different run states
  - `renderAgentCard(run, progress)` — renders a single agent card with metrics
  - `renderWatchDisplay(state, showDetachHint)` — renders full display with summary bar
  - `poll(store, runIds)` — queries store and aggregates metrics
  - `watchRunsInk(store, runIds)` — main polling loop with SIGINT handling
  - Uses screen clearing: `\x1B[2J\x1B[H` (ANSI escape codes)

### Testing
- **src/cli/__tests__/watch-ui.test.ts** (~180 lines) — Tests for watch UI functions
  - Tests `elapsed()`, `shortModel()`, `shortPath()` formatting
  - Tests `renderAgentCard()` and `renderWatchDisplay()` output
  - Tests `poll()` aggregation logic

- **src/cli/__tests__/status-display.test.ts** (~150 lines) — Tests for status display
  - Tests pipeline phase parsing from `lastToolCall`
  - Tests agent activity formatting (sub-agents vs last tool)

- **src/cli/__tests__/commands.test.ts** — Integration tests for commands

### Dependencies & Libraries
- **chalk** v5.6.2 — Terminal color & styling (already in use)
- **commander** v14.0.3 — CLI parsing (already in use)
- **ink** v6.8.0 — React-based terminal UI (available but not yet used)
- **ink-spinner** v5.0.0 — Spinner component for Ink (available but not yet used)
- **ora** v9.3.0 — Elegant terminal spinner (available but not yet used)
- **better-sqlite3** v12.6.2 — SQLite database access (already in use)

## Architecture & Patterns

### Dashboard Conceptual Architecture
```
foreman dashboard
    │
    ├─→ ForemanStore (SQLite)
    │   ├─ getActiveRuns(projectId?)
    │   ├─ getRun(id)
    │   ├─ getRunProgress(runId)
    │   ├─ getRunEvents(runId, eventType?)
    │   └─ getProjectByPath(path)
    │
    ├─→ Monitor (orchestrator/monitor.ts)
    │   └─ checkAll() → MonitorReport { active, completed, stuck, failed }
    │
    └─→ TUI Renderer
        ├─ Project overview (all projects)
        ├─ Real-time agent cards (status, cost, progress)
        ├─ Event log (latest runs)
        └─ Summary metrics (total cost, tool calls, files changed)
```

### CLI Command Pattern (from existing commands)
All commands follow this structure:
```typescript
export const commandName = new Command("name")
  .description("description")
  .option("--flag", "description", "default")
  .action(async (opts) => {
    const projectPath = await getRepoRoot(process.cwd());
    const store = new ForemanStore();
    // ... do work ...
    store.close();
  });
```

### Watch Mode Pattern (from watch-ui.ts & run.ts)
Polling-based live update pattern:
```typescript
const POLL_MS = 3_000;  // 3 second poll interval
while (!detached) {
  const state = poll(store, runIds);  // Query current state
  const display = renderDisplay(state);  // Render to string
  process.stdout.write("\x1B[2J\x1B[H" + display + "\n");  // Clear & render

  if (allDone) break;
  await sleep(POLL_MS);
}
```

### UI Rendering Pattern
- Build display as array of strings (lines)
- Join with newlines: `lines.join("\n")`
- Use chalk for colors: `chalk.green()`, `chalk.red()`, etc.
- Use ANSI codes for screen clearing: `\x1B[2J\x1B[H` (clear + move cursor to start)
- Status icons (●, ✓, ✗, ⚠, ○) for quick visual scanning

### Data Flow
1. **Watch Loop**: Periodically call `store.getActiveRuns(projectId)` and `store.getRunProgress(runId)`
2. **Status Check**: Call `Monitor.checkAll()` to categorize runs
3. **Aggregation**: Sum metrics across runs (total cost, tool calls, files)
4. **Rendering**: Build display string and print to stdout
5. **Event Logging**: `store.logEvent()` records state transitions (dispatch, complete, fail, etc.)

## Dependencies

### Imports Dashboard Will Need
```typescript
// CLI infrastructure
import { Command } from "commander";
import chalk from "chalk";

// Core libraries
import { ForemanStore, type Run, type RunProgress, type Project } from "../lib/store.js";
import { Monitor } from "../orchestrator/monitor.js";
import { getRepoRoot } from "../lib/git.js";

// Existing UI helpers
import type { WatchState } from "../cli/watch-ui.js";
import { elapsed, shortModel, renderAgentCard } from "../cli/watch-ui.js";
```

### What Depends on Dashboard Command
- The CLI index.ts will need to import and add the command
- No existing code depends on a dashboard command (new feature)

### Store Methods Used
- `store.getProjectByPath(path)` — get current project
- `store.getActiveRuns(projectId)` — get currently running agents
- `store.getRunsByStatus(status, projectId)` — get runs in specific state
- `store.getRun(id)` — get single run details
- `store.getRunProgress(runId)` — get detailed metrics
- `store.getRunEvents(runId)` — get run event log
- `store.listProjects()` — list all projects (for global view)
- `store.getProject(id)` — get project details

## Existing Tests

### Test Files
- **src/cli/__tests__/watch-ui.test.ts** — Comprehensive tests for watch UI helpers
  - Tests elapsed time formatting, model shortening, path shortening
  - Tests agent card rendering, display rendering, polling logic
  - Provides good patterns for testing TUI components

- **src/cli/__tests__/status-display.test.ts** — Tests for status display parsing
  - Tests pipeline phase detection from `lastToolCall`
  - Tests agent activity formatting

- **src/orchestrator/__tests__/monitor.test.ts** — Tests for Monitor class
  - Tests `checkAll()` with various run states
  - Tests stuck detection and recovery logic
  - Provides patterns for mocking store and beads

### Test Patterns
- Use `vitest` for test runner
- Mock store with `vi.fn()` for method returns
- Create fixture builders (e.g., `makeRun()`, `makeProgress()`)
- Test string output with snapshots or exact comparisons

## Recommended Approach

### Phase 1: Command Structure & Basic View
1. Create **src/cli/commands/dashboard.ts**
   - Register command in src/cli/index.ts
   - Accept options: `--project`, `--interval <ms>`, `--no-auto-update` (for testing)
   - Initialize ForemanStore, Monitor, get current project

2. Extract display logic to **src/cli/dashboard-ui.ts** (parallel to watch-ui.ts)
   - `renderProjectHeader(project: Project)` — show project name, path
   - `renderAgentsList(state: DashboardState)` — use existing renderAgentCard
   - `renderProjectMetrics(state)` — show cost, tools, files totals
   - `renderEventLog(events: Event[])` — show recent status transitions
   - `renderFullDashboard(state)` — compose all sections

3. Implement polling loop in command
   - Query store every N ms (default 3000ms)
   - Clear screen and render
   - Handle SIGINT gracefully

### Phase 2: Enhanced Metrics & Events
1. Extend RunProgress interface (if needed)
   - Ensure `currentPhase` is populated by agent-worker.ts
   - Add phase start/end timestamps

2. Create event visualization
   - Show recent events (last 10-20): dispatch, complete, fail, recover, merge
   - Color-code by event type
   - Show elapsed time since event

3. Implement run state transitions
   - Highlight runs that changed status since last poll
   - Show brief animation (status change marker)

### Phase 3: Multiple Views (Optional)
1. **Overview tab** — All projects, agent counts, total costs
2. **Project tab** — Single project detail (current behavior)
3. **Metrics tab** — Cost breakdown, token usage, performance charts
4. **Event tab** — Chronological feed of all events

### Phase 4: Testing & Documentation
1. Write tests in **src/cli/__tests__/dashboard.test.ts**
   - Mock store and monitor
   - Test state aggregation and rendering
   - Test event log display
   - Test polling loop behavior

2. Update README with new command docs
3. Document data model and architecture

## Key Implementation Details

### Screen Clearing & Rendering
```typescript
// Clear screen and move cursor to top-left
process.stdout.write("\x1B[2J\x1B[H");
// Render display
process.stdout.write(displayString + "\n");
```

### Color & Status Pattern
```typescript
const STATUS_ICONS: Record<string, string> = {
  running: chalk.blue("●"),
  completed: chalk.green("✓"),
  failed: chalk.red("✗"),
  stuck: chalk.yellow("⚠"),
};
```

### Polling with Graceful Shutdown
```typescript
const onSigint = () => {
  if (detached) return;
  detached = true;
  process.stdout.write("\n");
  console.log("Detached — agents continue in background");
};
process.on("SIGINT", onSigint);
```

### State Aggregation Pattern
```typescript
interface DashboardState {
  project: Project;
  runs: Array<{ run: Run; progress: RunProgress | null }>;
  summary: {
    totalCost: number;
    totalTools: number;
    totalFiles: number;
    completedCount: number;
    failedCount: number;
  };
  recentEvents: Event[];
}
```

## Potential Pitfalls & Edge Cases

1. **Project Context**
   - Dashboard should work in any foreman-initialized project (detect via `getRepoRoot()` & store)
   - Or allow `--project` flag to view any registered project
   - Edge case: No active runs → show "no agents running" message

2. **Polling Frequency**
   - Too fast: High CPU usage, database contention
   - Too slow: Stale display, missed state changes
   - Recommend: 3s default with `--interval` option for override

3. **Event Log Retention**
   - Store has all events, but displaying 100+ events will be unwieldy
   - Recommendation: Show only recent 20 events, with scrollable option (future)

4. **Cost Display Accuracy**
   - Costs may be updated mid-run by agent-worker (updateRunProgress)
   - May see "cost jumped" in display if agent pushed new progress between polls
   - This is normal; consider caching last total for delta display

5. **Multi-Project Scenarios**
   - If user runs agents in multiple projects simultaneously, dashboard needs project filter
   - Default to current directory's project, or allow `--project` flag

6. **Terminal Size**
   - Many agents won't fit on screen (80x24 default)
   - Truncate agent cards or implement scrolling (future)
   - Use dynamic sizing if possible

7. **Stuck Agent Detection**
   - Monitor.checkAll() uses configurable timeout (default 15m)
   - Dashboard may want to highlight stuck agents differently
   - Consider `--warn-stuck-after <minutes>` option

8. **ANSI Escape Code Compatibility**
   - ANSI codes work on most modern terminals (macOS, Linux, Windows 11+)
   - May need fallback for older terminals (non-interactive output)
   - chalk handles this automatically in most cases

## Files to Create/Modify

### New Files
- `src/cli/commands/dashboard.ts` — Main command implementation
- `src/cli/dashboard-ui.ts` — TUI rendering logic (may reuse/extend watch-ui.ts)
- `src/cli/__tests__/dashboard.test.ts` — Test suite

### Modified Files
- `src/cli/index.ts` — Add dashboard command import and registration

### Potentially Reusable
- `src/cli/watch-ui.ts` — Extract common UI building blocks
  - Helper functions can be moved to shared utils if needed
  - `renderAgentCard()` can be reused as-is

## Summary

The dashboard command builds on existing infrastructure (store, monitor, watch-ui patterns). The main work is:
1. **Command structure** — Standard foreman command with CLI options
2. **UI composition** — Combine existing card renderer with new sections (metrics, events)
3. **Polling loop** — Adapt the watch-ui.ts polling pattern for the new display
4. **State aggregation** — Query store and monitor, aggregate metrics across runs
5. **Testing** — Follow existing test patterns (mock store, test rendering)

The implementation can be incremental: start with a basic view (agents + summary), add metrics, then add event log and multiple views.
