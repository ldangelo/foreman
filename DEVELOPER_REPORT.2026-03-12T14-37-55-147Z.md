# Developer Report: Agent observability: dashboard command with live TUI

## Approach

Implemented a `foreman dashboard` command following the existing chalk-based polling pattern used by `watch-ui.ts` and `status.ts`. The command provides a live TUI that refreshes every 3 seconds (configurable) with multi-project observability, active agent cards, event timelines, and cost/token totals.

## Files Changed

- **src/cli/commands/dashboard.ts** — New command file implementing:
  - `DashboardState` interface for collected state
  - `pollDashboard(store, projectId?)` — collects active runs, progress, metrics, and recent events from the store for all (or a filtered) project
  - `renderEventLine(event)` — formats a single event with icon, type, details, and elapsed age
  - `renderProjectHeader(project, activeCount, metrics)` — renders project summary line with cost/tokens
  - `renderDashboard(state)` — assembles the full TUI display: header, per-project sections (active agents, recently completed, recent events), and a global totals footer
  - `dashboardCommand` — Commander command with `--interval`, `--project`, `--no-watch`, and `--events` options; supports both single-snapshot and live polling modes with SIGINT handler for graceful detach

- **src/cli/index.ts** — Imported and registered `dashboardCommand`

## Tests Added/Modified

- **src/cli/__tests__/dashboard.test.ts** — 30 tests covering:
  - `renderEventLine()`: dispatch/complete/fail events, null details, non-JSON details, elapsed time suffix
  - `renderProjectHeader()`: project name, cost, token formatting, singular/plural agent counts
  - `renderDashboard()`: header, Ctrl+C hint, project section, active/completed agents, events, totals footer, empty state, multi-project cost aggregation
  - `pollDashboard()`: project listing, active runs collection, progress fetching, metrics/events per project, lastUpdated timestamp

## Decisions & Trade-offs

- **Reused `renderAgentCard` from watch-ui.ts** rather than reimplementing it — keeps agent display consistent with the `foreman run --watch` view
- **Multi-project support** — dashboard shows all registered projects by default; `--project <id>` filters to one. Used `listProjects()` rather than requiring a CWD project
- **Recently completed** — shows up to 3 completed runs per project as a lightweight history (doesn't require extra store method — uses existing `getRunsByStatus`)
- **Event detail parsing** — tries JSON parse first (since most events store JSON details), falls back to raw string for older events
- **`--no-watch` flag** — single snapshot exits immediately, useful for scripting or CI

## Known Limitations

- The `--project <id>` filter currently accepts a project ID, not a name (could be improved with fuzzy name matching)
- No terminal-width awareness — wide agent cards may overflow on narrow terminals (same limitation as existing watch-ui.ts)
- No state-diff optimization — redraws full screen on every poll tick even if nothing changed (avoids complexity; follows existing pattern)
- The `--project <id>` filter accepts a project ID only (not a name); could be improved with name-based lookup
