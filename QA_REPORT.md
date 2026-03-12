# QA Report: Cost tracking with per-agent and per-phase breakdowns

## Verdict: PASS

## Test Results
- Test suite: 236 passed, 9 failed (same 9 pre-existing failures as baseline without changes)
- New tests added: 6 (all in `src/lib/__tests__/store-metrics.test.ts`)

## Pre-existing Failures (not caused by this change)
All 9 failures exist on the baseline (before these changes) and are caused by missing `tsx` binary in the worktree's `node_modules/.bin/`:
- `commands.test.ts` (4): ENOENT spawning CLI binary
- `agent-worker.test.ts` (2): ENOENT spawning worker binary
- `detached-spawn.test.ts` (2): ENOENT spawning tsx
- `worker-spawn.test.ts` (1): tsx binary not found

## Type Errors
None — `npx tsc --noEmit` completed with no output.

## Implementation Summary
The feature adds per-phase and per-agent cost tracking across three layers:

1. **`src/lib/store.ts`** — Two new fields on `RunProgress` (`costByPhase`, `agentByPhase`), two new fields on `Metrics` (`costByPhase`, `agentCostBreakdown`), two new methods (`getCostBreakdown`, `getPhaseMetrics`), and `getMetrics` now aggregates phase data.

2. **`src/orchestrator/agent-worker.ts`** — After each phase result, `costByPhase[role]` and `agentByPhase[role]` are populated using `roleConfig.model` (e.g. `"claude-haiku-4-5-20251001"`, `"claude-sonnet-4-6"`).

3. **`src/cli/commands/status.ts`** — `renderStatus()` shows per-phase and per-model cost breakdowns when phase data exists, with correct ordering (`explorer → developer → qa → reviewer`), descending sort for models.

4. **`src/cli/watch-ui.ts`** — `renderAgentCard()` shows per-phase costs in the live TUI with short model names as hints.

## Test Coverage Analysis

New tests in `store-metrics.test.ts` cover:
- `getCostBreakdown` returns empty for no-progress runs (backwards compat)
- `getCostBreakdown` returns empty for runs without phase data (single-agent mode)
- `getCostBreakdown` correctly computes byPhase and byAgent (multiple phases, same model)
- `getPhaseMetrics` aggregates across multiple runs
- `getMetrics` includes `costByPhase`/`agentCostBreakdown` when data exists
- `getMetrics` omits those fields when no phase data (undefined, not empty object)

Not covered by tests:
- `renderAgentCard` in `watch-ui.ts` does not have tests for the new phase cost lines (UI rendering path only, no logic risk)
- `renderStatus` in `status.ts` similarly has no tests for the new phase section (existing pattern — status-display tests do not use a real store)

## Issues Found
None. The implementation is correct and consistent with existing patterns.

## Files Modified
No new test files were created. The developer had already added 6 tests to `src/lib/__tests__/store-metrics.test.ts`.
