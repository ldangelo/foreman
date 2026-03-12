# Developer Report: Agent observability: dashboard command with live TUI

## Approach

Implemented a `foreman dashboard` command that provides a live, polling-based TUI dashboard for observing agent status across a project. The implementation follows the existing `watch-ui.ts` pattern (ANSI escape code clearing + polling loop) and reuses the existing `renderAgentCard()` helper.

Key design decisions:
- Separated UI rendering logic into `dashboard-ui.ts` (parallel to `watch-ui.ts`) to keep command files thin
- The dashboard shows ALL runs for a project (active + recent completed/failed), not just specific run IDs
- Includes a recent events log pulled from the store's events table
- Supports `--all` flag for cross-project view and `--no-auto-update` for single-render/testing mode

## Files Changed

- **src/cli/dashboard-ui.ts** (new) — Core TUI rendering + polling logic
  - `DashboardState` interface with project, runs, summary metrics, events
  - `renderDashboard()` — composes header, active agents, recent agents, events, summary bar
  - `renderEventLog()` — formats recent events with icons, type, bead ID, elapsed time
  - `renderAgentsList()` — wraps existing `renderAgentCard()` for a list of runs
  - `pollDashboard()` — queries store for active + recent runs, aggregates metrics, fetches events
  - `runDashboard()` — main polling loop with SIGINT handling (Ctrl+C to exit gracefully)

- **src/cli/commands/dashboard.ts** (new) — Commander command definition
  - Options: `--project <path>`, `--interval <ms>`, `--no-auto-update`, `--all`
  - Resolves project via `getProjectByPath()` from current directory or `--project` flag
  - Gracefully degrades to global view with a warning if project not registered

- **src/cli/index.ts** (modified) — Added import and registration of `dashboardCommand`

## Tests Added/Modified

- **src/cli/__tests__/dashboard.test.ts** (new) — 37 tests covering:
  - `renderEventLog()` — empty state, event type display, bead ID extraction, limit parameter, elapsed time
  - `renderAgentsList()` — empty state, multiple runs, status display, cost from progress
  - `renderDashboard()` — header, section visibility (Active/Recent Agents, Events), summary bar counts/cost/tools, Ctrl+C hint logic
  - `pollDashboard()` — project fetch, metric aggregation, run deduplication, count calculations (running/pending/completed/failed/stuck), events inclusion, timestamp accuracy

## Decisions & Trade-offs

1. **Reused `renderAgentCard()`** from `watch-ui.ts` instead of building a new card renderer — keeps consistent visuals with `foreman run --watch`.

2. **ANSI polling vs Ink/React** — Followed the existing `watchRunsInk` pattern (ANSI escape codes + poll loop) rather than introducing Ink React components. This keeps the implementation simple and consistent with the rest of the codebase. Ink is available as a dependency but not yet used anywhere.

3. **Show active + recent runs** — Unlike `watchRunsInk` which only shows specific run IDs, the dashboard fetches all active runs + last 5 completed + last 3 failed for the project, giving a holistic view.

4. **`--no-auto-update` flag** — Renders once without the clear-screen loop. Used by tests and useful for piping output or scripting.

5. **Graceful degradation when project not found** — Shows a warning and falls back to global view rather than hard-failing. Matches UX patterns of other foreman commands.

## Known Limitations

- No scrolling: with many concurrent agents, cards may overflow the terminal height. Terminal scrollback works but live updates overwrite. Future: implement terminal height detection and truncation.
- No keyboard interaction: pressing keys other than Ctrl+C has no effect. Future: use Ink for interactive mode (tabs, scroll, etc.).
- Events show project-level events only; there's no drill-down to per-run event history in the TUI.
- `--all` global view fetches runs without a project filter, which may be slow if many runs are in the database.
