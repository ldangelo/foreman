# QA Report: Cost tracking with per-agent and per-phase breakdowns

## Verdict: PASS

## Test Results
- Test suite: 235 passed, 9 failed
- Pre-existing failures (unrelated): 9 (all due to missing `tsx` binary in worktree — infrastructure issue that existed before this change)
- New tests added: 5 (all pass, in `src/lib/__tests__/store-metrics.test.ts`)
- TypeScript: clean (`tsc --noEmit` exits 0)

## What Was Implemented

The developer fully implemented cost tracking with per-agent and per-phase breakdowns:

1. **`src/lib/store.ts`**
   - New `phase_costs` table with `run_id`, `phase`, `agent_type`, `tokens_in`, `tokens_out`, `cache_read`, `estimated_cost`, `recorded_at`
   - New interfaces: `PhaseCostRecord`, `CostByPhase`, `CostByAgentAndPhase`
   - Extended `RunProgress` with optional `phaseCosts?: Record<string, number>`
   - Extended `Metrics` with `costByPhase` and `costByAgentAndPhase` arrays
   - New methods: `recordPhaseCost()`, `getCostsByPhase()`, `getCostsByAgentAndPhase()`
   - `getMetrics()` now includes phase-level aggregations

2. **`src/orchestrator/agent-worker.ts`**
   - Extended `PhaseResult` with `tokensIn` and `tokensOut` fields
   - `recordPhaseCost()` called after each phase (explorer, developer, qa, reviewer)
   - `progress.phaseCosts` updated and persisted via `updateRunProgress()` after each phase
   - Handles multi-phase retries (developer+qa re-runs accumulate correctly)

3. **`src/orchestrator/roles.ts`** + **`src/orchestrator/dispatcher.ts`**
   - Migrated from `maxTurns` to `maxBudgetUsd` for phase budget control
   - Per-phase budgets: explorer=$1.00, developer=$5.00, qa=$3.00, reviewer=$2.00

4. **`src/cli/watch-ui.ts`**
   - Displays per-phase cost breakdown in agent card (expl/dev/qa/rev abbreviations)

5. **`src/cli/commands/status.ts`**
   - Shows `costByPhase` and `costByAgentAndPhase` in the metrics section

## Issues Found

None. All implementation-related tests pass cleanly.

### Pre-existing Failures (Not Related to This Change)
The 9 failing tests were present **before** this change (verified by stashing changes and re-running):
- `src/cli/__tests__/commands.test.ts` (4 tests): `ENOENT` for tsx binary
- `src/orchestrator/__tests__/agent-worker.test.ts` (2 tests): `ENOENT` for tsx binary
- `src/orchestrator/__tests__/detached-spawn.test.ts` (2 tests): `ENOENT` for tsx binary
- `src/orchestrator/__tests__/worker-spawn.test.ts` (1 test): `ENOENT` for tsx binary

These all fail because `node_modules/.bin/tsx` is not symlinked in the git worktree (the binary lives in the main repo's `node_modules`). This is a known worktree infrastructure issue, unrelated to cost tracking.

## New Tests Added (All Pass)

In `src/lib/__tests__/store-metrics.test.ts`:
1. `getCostsByPhase returns aggregated costs per phase` — verifies multi-run phase aggregation, correct token/cost sums
2. `getCostsByPhase with date filter` — verifies `since` date filtering works in both directions
3. `getCostsByAgentAndPhase returns 2D breakdown` — verifies cross-agent/phase matrix
4. `getMetrics includes costByPhase and costByAgentAndPhase` — verifies `getMetrics()` integration
5. `empty project returns empty phase cost arrays` — verifies safe empty-state handling

## Files Modified
- `QA_REPORT.md` (this file)
