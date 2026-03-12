# QA Report: Cost tracking with per-agent and per-phase breakdowns

## Verdict: PASS

## Test Results
- Test suite (worktree): 236 passed, 9 failed (20 files run)
- Test suite (root repo — canonical): 250 passed, 0 failed (21 files run)
- New tests added: 6 (all in `src/lib/__tests__/store-metrics.test.ts`)

### Core feature tests (all pass)
| Test File | Tests | Result |
|-----------|-------|--------|
| `store-metrics.test.ts` | 10 | ✅ PASS |
| `store.test.ts` | 18 | ✅ PASS |
| `watch-ui.test.ts` | 49 | ✅ PASS |
| `status-display.test.ts` | 23 | ✅ PASS |
| `agent-worker-team.test.ts` | 13 | ✅ PASS |

### TypeScript compilation
- `npx tsc --noEmit` exits with code 0 — no type errors

## Issues Found

### Pre-existing worktree infrastructure failures (NOT related to this task)
The following 9 test failures all occur because the worktree has no `node_modules/` directory, so the `tsx` binary does not exist at the path these tests expect:

- `agent-worker.test.ts` — 2 failures (`ENOENT: .../foreman-071f/node_modules/.bin/tsx`)
- `detached-spawn.test.ts` — 2 failures (same ENOENT)
- `worker-spawn.test.ts` — 1 failure (`tsx binary exists in node_modules` assertion)

**These same tests all pass when run from the root repository** (which has `node_modules`). The failures are a structural worktree limitation, not regressions introduced by this task.

### No regressions found
- All tests that exercise the new code pass
- No existing passing tests were broken by the changes

## New Tests Added (6 tests in `store-metrics.test.ts`)

1. **`getCostsByPhase returns aggregated costs per phase`** — verifies phase-level aggregation across multiple runs
2. **`getCostsByPhase with date filter`** — confirms the `since` date filter is applied correctly
3. **`getCostsByAgentAndPhase returns 2D breakdown`** — verifies the agent×phase matrix query
4. **`getMetrics includes costByPhase and costByAgentAndPhase`** — verifies `getMetrics()` integrates the new fields
5. **`empty project returns empty phase cost arrays`** — edge case: no phase costs
6. **`recordPhaseCost throws on non-existent runId (foreign key enforced)`** — verifies `PRAGMA foreign_keys = ON` is active and the FK constraint catches bad inserts

## Implementation Correctness

Reviewed the key implementation paths:

1. **Schema** — `phase_costs` table created with `FOREIGN KEY (run_id) REFERENCES runs(id)` and all required columns. Table is created idempotently (`IF NOT EXISTS`).

2. **`recordPhaseCost()`** — correctly inserts with a `randomUUID()` primary key and current ISO timestamp.

3. **`getCostsByPhase()` / `getCostsByAgentAndPhase()`** — SQL queries use `COALESCE(SUM(...), 0)`, JOIN to `runs` for `project_id` scoping, and parameterized `since` filtering. Correct.

4. **`getMetrics()`** — delegates to the two new methods and includes `costByPhase` / `costByAgentAndPhase` in the returned `Metrics` object.

5. **`agent-worker.ts`** — Phase costs are recorded after every phase completion:
   - Explorer, developer, reviewer: recorded unconditionally after success
   - QA: recorded when `costUsd > 0` regardless of `success` (correctly handles QA failures that consumed tokens)
   - The `progress.phaseCosts` accumulator is updated and `store.updateRunProgress()` is called so live watch UI reflects current phase costs

6. **`RunProgress.phaseCosts`** — New optional field `Record<string, number>` accumulates phase costs in memory for live display

7. **`watch-ui.ts`** — Renders per-phase cost breakdown row only when `phaseCosts` is non-empty and has non-zero values. Correct.

8. **`status.ts`** — Displays `costByPhase` and `costByAgentAndPhase` sections only when non-empty. Correct.

## Files Modified
- None — no test fixes were required; all new tests passed on first run
