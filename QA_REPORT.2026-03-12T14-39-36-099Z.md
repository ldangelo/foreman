# QA Report: Agent observability: dashboard command with live TUI

## Verdict: PASS

## Test Results
- Test suite: 260 passed, 9 failed
- New tests added: 0 (developer added 30 tests; all pass)
- All 9 failures are pre-existing environment issues unrelated to this change (same 9 failures confirmed in prior QA report at `QA_REPORT.2026-03-12T14-32-11-030Z.md`)

### Dashboard-specific test results (all pass)
All 30 tests in `src/cli/__tests__/dashboard.test.ts` pass:

| Suite | Tests | Result |
|---|---|---|
| `renderEventLine` | 6 | ✓ PASS |
| `renderProjectHeader` | 6 | ✓ PASS |
| `renderDashboard` | 12 | ✓ PASS |
| `pollDashboard` | 6 | ✓ PASS |

### Pre-existing Failures (Not Caused by This Change)

| Test File | Failing Tests | Root Cause |
|---|---|---|
| `src/cli/__tests__/commands.test.ts` | 4 tests | `tsx` binary missing in worktree `node_modules` (ENOENT) |
| `src/orchestrator/__tests__/agent-worker.test.ts` | 2 tests | `tsx` binary missing in worktree `node_modules` |
| `src/orchestrator/__tests__/detached-spawn.test.ts` | 2 tests + 2 uncaught errors | `tsx` binary missing in worktree `node_modules` |
| `src/orchestrator/__tests__/worker-spawn.test.ts` | 1 test | `tsx` binary missing in worktree `node_modules` |

## TypeScript Compilation
`npx tsc --noEmit` passes with zero errors.

## Implementation Review

### src/cli/commands/dashboard.ts
- `DashboardState` interface is well-typed with Maps keyed by project ID
- `renderEventLine()` correctly handles JSON and non-JSON event details, falls back gracefully
- `renderProjectHeader()` correctly formats cost, tokens in k notation, and agent count (singular/plural)
- `renderDashboard()` correctly renders all sections: header, per-project blocks, totals footer, empty state
- `pollDashboard()` correctly queries store: listProjects, getActiveRuns, getRunsByStatus("completed"), getRunProgress per run, getMetrics, getEvents
- Command properly uses `--no-watch` (Commander boolean negation) and validates `--interval` and `--events` options
- SIGINT handler restores cursor (`\x1b[?25h`) and closes store before exit — clean teardown
- Reuses `renderAgentCard` from `watch-ui.ts` — consistent agent display across commands

### src/cli/index.ts
- `dashboardCommand` correctly imported and registered via `program.addCommand(dashboardCommand)`

## Issues Found

### Minor: commands.test.ts `--help` assertion was stale
The `--help` smoke test had `expect(output).not.toContain("dashboard")` — incorrect after the dashboard command was added. **Fixed** by updating the test to include `"dashboard"` in the list of expected commands and removing the stale negation.

Note: This test still "fails" in the worktree due to the pre-existing missing `tsx` binary, but the assertion logic is now correct.

## Files Modified
- `src/cli/__tests__/commands.test.ts` — Updated `--help` test name and assertion to include `dashboard` in expected commands (removed stale `not.toContain("dashboard")`)
