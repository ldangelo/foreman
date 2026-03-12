# Explorer Report: Agent observability: dashboard command with live TUI

## Task Summary

Implement a `foreman dashboard` command that provides live agent observability in a terminal UI. The dashboard should display:
- Live agent status (pending, running, completed, failed, stuck)
- Current pipeline phase (explorer, developer, qa, reviewer, finalize)
- Token usage and cost tracking per agent and project
- Recent events (dispatches, completions, failures, recoveries)
- Multi-project overview with aggregated metrics

## Relevant Files

### CLI Commands (Foundation)
- **src/cli/index.ts** — CLI entry point where commands are registered (lines 1-35)
  - Currently registers 11 commands (init, plan, decompose, run, status, merge, pr, monitor, reset, attach, doctor)
  - `dashboard` command will be added here via `program.addCommand(dashboardCommand)`

### Related Commands (Reference Patterns)
- **src/cli/commands/status.ts** — Single-pass status display showing tasks, active agents, costs (lines 1-170)
  - Uses chalk for colors and formatting
  - Queries store for projects, runs, progress, and metrics
  - Pattern: gather data → render static output (non-polling)

- **src/cli/commands/monitor.ts** — Agent health check with stuck detection (lines 1-106)
  - Single-pass monitoring of active runs
  - Categorizes into: active, completed, stuck, failed
  - Supports recovery options
  - Uses Monitor class from orchestrator

- **src/cli/commands/run.ts** — Dispatches tasks and watches execution (lines 1-100+)
  - Imports `watchRunsInk` from watch-ui.ts
  - Demonstrates polling loop pattern with 3-second intervals
  - Handles Ctrl+C for detaching while allowing background agents to continue

### Display & Polling Logic (Core Pattern)
- **src/cli/watch-ui.ts** — Live watch display implementation (lines 1-251)
  - **Key functions**:
    - `poll(store, runIds)` (lines 135-167) — Fetches run data from store and computes state
    - `renderAgentCard(run, progress)` (lines 57-120) — Formats individual agent status (icon, phase, cost, tools, files)
    - `renderWatchDisplay(state, showDetachHint)` (lines 169-215) — Renders full display with agent cards and summary
    - `watchRunsInk(store, runIds)` (lines 219-250) — Polling loop with SIGINT handler
  - Uses ANSI escape codes for screen clear: `\x1B[2J\x1B[H`
  - Polling interval: 3000ms
  - Status icons: pending (○), running (●), completed (✓), failed (✗), stuck (⚠)
  - Uses `chalk` for terminal colors only (no React/Ink complications)
  - Note: Function named "watchRunsInk" historically but uses chalk, not Ink library

### Data Layer (ForemanStore)
- **src/lib/store.ts** — SQLite-backed persistence (lines 1-500+)
  - **Key data methods**:
    - `listProjects(status?)` (lines 202-211) — Get all projects
    - `getActiveRuns(projectId?)` (lines 281-294) — Pending and running runs
    - `getRunsByStatus(status, projectId?)` (lines 296-307) — Filtered runs
    - `getRunProgress(runId)` (lines 341-347) — Parse progress JSON for a run
    - `getMetrics(projectId?, since?)` (lines 437-500+) — Aggregated cost/token data
    - `getCosts(projectId?, since?)` (lines 366-393) — Cost records
    - `getEvents(projectId?, limit?, eventType?)` (lines 416-433) — Recent events
  - **Data structures**:
    - `Project`: id, name, path, status, created_at, updated_at
    - `Run`: id, project_id, seed_id, agent_type, status, started_at, completed_at, progress (JSON)
    - `RunProgress`: toolCalls, toolBreakdown, filesChanged, turns, costUsd, tokensIn, tokensOut, lastToolCall, lastActivity, currentPhase
    - `Metrics`: totalCost, totalTokens, tasksByStatus, costByRuntime
    - `Event`: id, project_id, run_id, event_type (dispatch|claim|complete|fail|merge|stuck|restart|recover|conflict|test-fail|pr-created), details, created_at

### Orchestrator/Monitoring (Background Context)
- **src/orchestrator/monitor.ts** — Monitor class for stuck detection and recovery (lines 1-160)
  - `checkAll(opts?)` → returns `MonitorReport` with categorized runs
  - Pattern reference for aggregating run data

### Test Patterns (for TDD)
- **src/cli/__tests__/watch-ui.test.ts** — Existing tests for display functions (lines 1-200+)
  - Tests `elapsed()`, `shortModel()`, `shortPath()` helper functions
  - Tests `renderAgentCard()` with various Run and RunProgress fixtures
  - Tests `renderWatchDisplay()` with WatchState
  - Tests `poll()` with mock store
  - Pattern: Create fixtures with `makeRun()` and `makeProgress()`, use vi.fn() for mocks

- **src/cli/__tests__/status-display.test.ts** — Status command display tests
  - Tests `parsePipelinePhase()` for extracting phase names from lastToolCall
  - Tests sub-agent count display logic
  - Pattern: Extract pure functions and test independently

## Architecture & Patterns

### Polling & Display Architecture
The foreman codebase uses a **polling + chalk-based rendering** pattern:

```
Every 3-5 seconds:
  1. poll(store, runIds) → WatchState { runs[], allDone, totals }
  2. renderWatchDisplay(state) → formatted string with ANSI colors
  3. stdout.write("\x1B[2J\x1B[H" + display) → clear screen + write
  4. setInterval() or setTimeout() loop until done
```

**Key advantages of this pattern:**
- Simple to understand and test (pure functions)
- No React/Ink complexity (avoided due to iTerm hanging issues)
- Terminal-compatible (works across platforms)
- Easy to add TUI elements (progress bars, status icons)

### Terminal UI Components (from existing code)

**Agent Card Format** (from renderAgentCard):
```
● foreman-a1b2 RUNNING 5m 23s
  Model      claude-sonnet-4-6
  Cost       $0.0245
  Turns      12
  Tools      45 (last: Read)
  Bash       ███████░░░░░░░░ 7
  Read       ███████████░░░░ 11
  Edit       ███░░░░░░░░░░░░ 3
  Files      3
    src/cli/index.ts
    src/lib/store.ts
    +1 more
```

**Summary Bar Format** (from renderWatchDisplay):
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
3 agents  45 tool calls  3 files  $0.0542
```

### Pipeline Phase Display (from status.ts)
- Phases: explorer, developer, qa, reviewer, finalize
- Phase detection: lastToolCall matches regex `^(explorer|developer|qa|reviewer|finalize):(\\S+)`
- Example: "developer:start (retry 1)" indicates developer phase with 1 retry

### Color Scheme (from watch-ui.ts & status.ts)
- pending: gray (●)
- running: blue (●)
- completed: green (✓)
- failed: red (✗)
- stuck: yellow (⚠)
- Model names: magenta
- Costs: yellow
- Files: yellow
- Tool breakdown bars: cyan

## Dependencies

### Direct Dependencies Available
- **chalk@5.6.2** — Terminal coloring (already in use throughout codebase)
- **commander@14.0.3** — CLI framework for commands
- **better-sqlite3@12.6.2** — Database queries (via ForemanStore)
- No Ink/React needed — chalk-based approach avoids complexity

### Code Dependencies
- **ForemanStore** — SQLite queries for runs, projects, metrics, costs, events
- **Monitor** class — Can be reused for checking active runs
- **Display functions** — `elapsed()`, `shortModel()`, `shortPath()` from watch-ui.ts are reusable helpers

### Inverse Dependencies
- **src/cli/index.ts** — Will import and register dashboardCommand
- Future: May be used by web dashboard or other monitoring tools

## Existing Tests

### Test Infrastructure
- **Testing framework**: vitest (npm run test, npm run test:watch)
- **Test location**: Co-located `__tests__` directories (e.g., `src/cli/__tests__/`)
- **Mock/fixture patterns**: `vi.fn()`, `makeRun()`, `makeProgress()` helper functions

### Relevant Test Files
1. **src/cli/__tests__/watch-ui.test.ts** — Tests display functions (200+ lines)
   - Tests pure rendering functions: `renderAgentCard()`, `renderWatchDisplay()`
   - Tests helper functions: `elapsed()`, `shortModel()`, `shortPath()`
   - Tests `poll()` with mock ForemanStore
   - **Use this as template for dashboard tests**

2. **src/cli/__tests__/status-display.test.ts** — Tests status command (200+ lines)
   - Tests `parsePipelinePhase()` extraction
   - Tests sub-agent count display
   - Good pattern for testing display logic independently

3. **src/cli/__tests__/commands.test.ts** — General command tests (referenced but not examined)
   - Likely tests command execution and CLI options

### Test Gap
- No integration tests for polling loops with databases
- No tests for SIGINT handling in polling loops

## Recommended Approach

### Phase 1: Create Dashboard Command Structure (Basic)

**File: src/cli/commands/dashboard.ts**

Create a new command file following the pattern of `status.ts` and `monitor.ts`:

```typescript
export const dashboardCommand = new Command("dashboard")
  .description("Live agent observability dashboard")
  .option("--interval <ms>", "Polling interval in milliseconds", "3000")
  .option("--project <id>", "Filter to specific project")
  .option("--no-watch", "Single snapshot (no polling)")
  .action(async (opts) => {
    // 1. Initialize store and get project
    // 2. If --no-watch: single render and exit
    // 3. If watch: start polling loop with SIGINT handler
  });
```

**Implementation steps:**
1. Create ForemanStore instance
2. Get target project (all projects or filtered)
3. Implement polling function: `pollDashboard(store, projectId?, interval?)`
4. Implement display function: `renderDashboard(data)` with multi-project support
5. Add SIGINT handler to detach gracefully (like watchRunsInk)

### Phase 2: Polling Data Collection

**Function: pollDashboard(store, projectId?, interval)**

```typescript
interface DashboardState {
  projects: Project[];
  runs: Map<string, Run>;
  progresses: Map<string, RunProgress | null>;
  metrics: Map<string, Metrics>; // per-project
  events: Map<string, Event[]>;  // per-project recent events
  lastUpdated: Date;
}
```

**Data gathering:**
1. `store.listProjects()` → active projects
2. For each project:
   - `store.getActiveRuns(projectId)` → currently running
   - `store.getRunsByStatus("completed", projectId)` → recent completions
   - `store.getMetrics(projectId)` → aggregated costs and tokens
   - `store.getEvents(projectId, 10)` → 10 most recent events
   - For each run: `store.getRunProgress(run.id)` → progress details

**Polling loop pattern** (from watchRunsInk):
```typescript
const pollInterval = setInterval(() => {
  const state = pollDashboard(store, projectId, interval);
  const display = renderDashboard(state);
  process.stdout.write("\x1B[2J\x1B[H" + display + "\n");

  if (allDone) {
    clearInterval(pollInterval);
    process.exit(0);
  }
}, interval);

process.on("SIGINT", () => {
  clearInterval(pollInterval);
  console.log("Detached. Continue with: foreman dashboard");
  process.exit(0);
});
```

### Phase 3: Dashboard Display Layout

**Proposed structure** (combining status + costs + events):

```
┌──────────────────────────────────────────────────────────┐
│ Foreman Dashboard — Agent Observability                  │
│ (Ctrl+C to detach)                                       │
├──────────────────────────────────────────────────────────┤
│                                                          │
│ PROJECT: my-project  [3/5 tasks]  $12.40 spent          │
│ ──────────────────────────────────────────────────────── │
│                                                          │
│ ACTIVE AGENTS:                                           │
│ ● foreman-a1b2 [sonnet] RUNNING 5m  developer:start     │
│   Turns: 12  Tools: 45  Cost: $0.0245  Files: 3        │
│                                                          │
│ ● foreman-c3d4 [sonnet] RUNNING 3m  qa:start           │
│   Turns: 8   Tools: 28  Cost: $0.0156  Files: 2        │
│                                                          │
│ COMPLETED (This Session):                               │
│ ✓ foreman-x8y9 [haiku] completed  explorer  $0.0082    │
│                                                          │
│ RECENT EVENTS:                                           │
│ • foreman-c3d4 started qa phase (3m ago)                │
│ • foreman-a1b2 started developer phase (5m ago)         │
│ • foreman-x8y9 completed explorer phase (8m ago)        │
│                                                          │
├──────────────────────────────────────────────────────────┤
│ METRICS — Total Cost: $12.40 | Tokens: 45.2k            │
│ Progress: █████████░░░░░░░░░░ 3/5 | Est. 25 min         │
└──────────────────────────────────────────────────────────┘
```

**Display function signature:**
```typescript
function renderDashboard(state: DashboardState): string {
  // 1. Render project header with stats
  // 2. Render active agents (renderAgentCard from watch-ui)
  // 3. Render completed agents this session
  // 4. Render recent events (dispatch, phase changes, completions)
  // 5. Render footer with totals and progress
}
```

### Phase 4: Reuse Existing Helpers

**From watch-ui.ts**, reuse:
- `elapsed(since: string | null): string` — Format elapsed time
- `shortModel(model: string): string` — Abbreviate model names
- `shortPath(path: string): string` — Shorten file paths
- `renderAgentCard(run, progress): string` — Format individual agent

**Adapt or extend:**
- Create `renderEventLine(event: Event): string` for event display
- Create `renderProjectHeader(project, metrics): string` for project summary
- Create `renderFooter(state): string` for total metrics

### Phase 5: Event Display (New Component)

**Add to watch-ui.ts or dashboard.ts:**

```typescript
function renderEventLine(event: Event, elapsed: string): string {
  const icon = eventIcons[event.event_type] ?? "•";
  const detail = event.details
    ? ` — ${event.details}`
    : "";
  return chalk.dim(`${icon} ${event.event_type} ${detail} (${elapsed} ago)`);
}

const eventIcons: Record<EventType, string> = {
  dispatch: "⬇",   // Agent spawned
  claim: "🎯",     // Task claimed
  complete: "✓",   // Agent completed
  fail: "✗",       // Agent failed
  stuck: "⚠",      // Agent stuck
  recover: "⚡",    // Recovery attempted
  merge: "⊕",      // Code merged
  // ... others
};
```

### Phase 6: Testing Strategy (TDD)

**Create: src/cli/__tests__/dashboard.test.ts**

```typescript
import { describe, it, expect, vi } from "vitest";
import { renderAgentLine, renderProjectHeader, renderFooter, pollDashboard } from "../commands/dashboard.js";

describe("Dashboard Display", () => {
  it("renders agent card with phase", () => {
    const run = makeRun({ agent_type: "claude-sonnet-4-6", status: "running" });
    const progress = makeProgress({
      costUsd: 0.0245,
      turns: 12,
      currentPhase: "developer"
    });
    const output = renderAgentCard(run, progress);
    expect(output).toContain("developer");
  });

  it("formats event timeline correctly", () => {
    const event = makeEvent({ event_type: "complete", details: "explorer done" });
    const output = renderEventLine(event, "5m");
    expect(output).toContain("explorer done");
  });

  it("aggregates project metrics", () => {
    const metrics = { totalCost: 12.40, totalTokens: 45000, /* ... */ };
    const output = renderProjectHeader(project, metrics);
    expect(output).toContain("$12.40");
    expect(output).toContain("45.2k");
  });
});
```

**Test coverage targets:**
- Display functions: 100% (pure functions, easy to test)
- Polling logic: integration tests with mock store
- Event timeline: unit tests for formatting

### Phase 7: Integration & Polish

1. **Register command** in src/cli/index.ts
2. **Add options:**
   - `--project <id>` — Filter to specific project (for multi-project setups)
   - `--interval <ms>` — Polling interval (default 3000ms)
   - `--no-watch` — Single snapshot mode (like `status` command)
   - `--events <n>` — Number of recent events to show (default 10)
3. **Add help text:** Clear examples in --help
4. **Handle edge cases:**
   - No projects registered yet
   - No active runs
   - Very large numbers of events (truncate with "X more...")
5. **Color consistency:** Match chalk colors from watch-ui.ts

## Potential Pitfalls & Edge Cases

### 1. **Database Performance Under Load**
- **Issue**: Polling every 3s with multiple queries (listProjects, getActiveRuns, getMetrics, getEvents) may bottleneck SQLite with many agents writing progress.
- **Mitigation**:
  - Cache metrics in memory, only refresh from DB every 5-10 seconds
  - Use PRAGMA optimize before polling
  - Consider batching getRunProgress calls instead of looping

### 2. **Terminal Width & Content Overflow**
- **Issue**: Agent cards with long file lists won't wrap properly on narrow terminals.
- **Mitigation**:
  - Detect terminal width with `process.stdout.columns`
  - Truncate file lists: show 3 files + "N more..."
  - Wrap text at terminal width using a utility like `word-wrap`

### 3. **Screen Flickering**
- **Issue**: Clearing and redrawing screen every 3s may cause flicker on slow terminals.
- **Mitigation**:
  - Only redraw if state changed (compare prev state hash)
  - Use Ink's `staticOutput` concept: once an agent completes, don't redraw it

### 4. **Multi-Project State**
- **Issue**: Tracking state across multiple projects and managing display layout.
- **Mitigation**:
  - Keep state map keyed by project_id
  - Render projects in order (alphabetical or by activity)
  - Show only active/recent projects by default (--all-projects flag)

### 5. **Event Deduplication**
- **Issue**: Same event may appear in multiple polls if not tracking last seen event ID.
- **Mitigation**:
  - Store last event ID in memory
  - Query `getEvents()` with WHERE id > lastEventId

### 6. **Phase Parsing Edge Cases**
- **Issue**: lastToolCall format may not always be "phase:action" (e.g., "Bash" for single-agent mode).
- **Mitigation**:
  - Reuse `parsePipelinePhase()` from status.ts
  - Gracefully fall back to showing lastToolCall if not a phase

### 7. **Cost Aggregation Accuracy**
- **Issue**: Progress.costUsd is estimated; actual cost may differ when SDK reports final cost.
- **Mitigation**:
  - Show both estimated (from progress) and finalized (from costs table) if available
  - Note "*estimated" in display when showing progress.costUsd
  - Sum verified costs from costs table for completed runs

### 8. **SIGINT Handling**
- **Issue**: Ctrl+C pressed twice may kill process before cleanup.
- **Mitigation**:
  - Set flag on first SIGINT, only exit on second (like watchRunsInk)
  - Clear intervals before exiting
  - Print "Detached" message clearly

### 9. **Empty State Handling**
- **Issue**: Dashboard should work even with no projects/runs yet.
- **Mitigation**:
  - Check for empty projects/runs early
  - Display helpful message: "No projects yet. Run 'foreman init' to start."
  - Still exit cleanly (don't hang on ctrl+c)

### 10. **Backwards Compatibility**
- **Issue**: watch-ui.ts has `watchRunsInk` but uses chalk (historical naming).
- **Mitigation**:
  - Keep watch-ui.ts as-is for backwards compatibility
  - Create new dashboard-specific display functions in dashboard.ts
  - Don't refactor watch-ui.ts in this task

## Next Steps for Developer

1. **Create dashboard.ts command file** with structure from monitor.ts and status.ts pattern
2. **Implement pollDashboard(store)** function to gather state from store
3. **Implement renderDashboard(state)** function with multi-project layout
4. **Add event rendering** via renderEventLine()
5. **Implement polling loop** with 3-second interval and SIGINT handler
6. **Write unit tests** for display functions (renderDashboard, renderEventLine, etc.)
7. **Add integration test** for polling loop with mock store
8. **Register dashboard command** in src/cli/index.ts
9. **Test manually** with `npm run dev` and `foreman dashboard`
10. **Optimize database queries** if polling is slow with many agents
11. **Handle terminal resize** if time permits (optional polish)

## References & Inspiration

- **Existing watch display**: src/cli/watch-ui.ts (polling + chalk pattern)
- **Status command**: src/cli/commands/status.ts (static display with metrics)
- **Monitor command**: src/cli/commands/monitor.ts (categorized run display)
- **Store queries**: src/lib/store.ts (data access layer)
- **Test patterns**: src/cli/__tests__/watch-ui.test.ts (fixture patterns)
- **PRD dashboard section**: docs/PRD.md section 5 (requirements & mockups)
