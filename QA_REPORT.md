# QA Report: Agent observability: dashboard command with live TUI

## Verdict: PASS

## Test Results
- Test suite: 267 passed + 37 new dashboard tests = 304 passing tests (after fix)
- Pre-existing failures: 9 (unrelated to this change — tsx binary missing in worktree, detached-spawn infrastructure issues)
- New tests added: 37 (src/cli/__tests__/dashboard.test.ts — all pass)
- TypeScript: No type errors (tsc --noEmit clean)

## Implementation Summary

Three new files were added and one existing file was modified:

1. **src/cli/commands/dashboard.ts** — CLI command registration using Commander.js. Accepts `--project`, `--interval`, `--no-auto-update`, and `--all` flags. Properly validates interval, gracefully degrades to global view when project not found.

2. **src/cli/dashboard-ui.ts** — Core TUI logic with:
   - `DashboardState` interface
   - `renderDashboard()` — Full dashboard renderer (header, active agents, recent agents, event log, summary bar)
   - `renderEventLog()` — Recent events with icons, elapsed time, and bead ID extraction
   - `renderAgentsList()` — Delegates to existing `renderAgentCard()` from watch-ui.ts
   - `pollDashboard()` — Queries store for active/completed/failed runs, merges and deduplicates, aggregates metrics
   - `runDashboard()` — Polling loop with SIGINT handling, supports both live and single-render modes

3. **src/cli/__tests__/dashboard.test.ts** — 37 tests covering: `renderEventLog`, `renderAgentsList`, `renderDashboard`, and `pollDashboard`.

4. **src/cli/index.ts** — Dashboard command imported and registered.

## Issues Found

### Minor Issue Fixed: commands.test.ts not updated for new command
- `src/cli/__tests__/commands.test.ts` had a test titled "shows all 7 commands" that explicitly asserted `expect(output).not.toContain("dashboard")`. The dashboard command is now the 8th command, so this assertion would fail if tsx was available.
- **Fix applied**: Updated test title to "shows all 8 commands", added "dashboard" to the expected command list, removed the `not.toContain("dashboard")` assertion.
- Note: This test was already failing due to tsx binary ENOENT (pre-existing worktree infrastructure issue) so no regression was introduced.

### Pre-existing Failures (not caused by this change)
All 9 pre-existing failures confirmed present on both `main` and on this branch before the dashboard changes:
- `src/cli/__tests__/commands.test.ts` (4 failures) — tsx binary not in worktree node_modules
- `src/orchestrator/__tests__/worker-spawn.test.ts` (1 failure) — tsx binary missing
- `src/orchestrator/__tests__/agent-worker.test.ts` (2 failures) — tsx binary missing
- `src/orchestrator/__tests__/detached-spawn.test.ts` (2 failures) — tsx binary missing + detach test failure

## Edge Cases Verified by Tests

- Empty runs list shows "no agents running" message
- Empty events list shows "no events yet" message and no "Recent Events" header
- Deduplication of runs that appear in both active and completed query results
- `test-failed` status counted in failedCount
- Ctrl+C hint hidden when no active agents, hidden when showDetachHint=false
- Project null case (global view)
- Cost/tool/file metric aggregation across multiple runs
- Event limit parameter respected
- `updatedAt` set to current time

## Files Modified
- `src/cli/__tests__/commands.test.ts` — Updated --help test to expect 8 commands including "dashboard"
