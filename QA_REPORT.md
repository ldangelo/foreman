# QA Report: PageRank-based task prioritization for sd ready

## Verdict: PASS

## Test Results
- **PageRank unit tests** (`pagerank.test.ts`): 28 passed, 0 failed
- **Dispatcher tests** (`dispatcher.test.ts`): 11 passed, 0 failed
- **Total tests in scope**: 39 passed, 0 failed
- **New tests added**: 0 (28 new tests were added by the Developer)

### Full Suite Summary
Running the full test suite in the worktree shows 9 failures in 4 files, but **all failures are pre-existing worktree environment issues** unrelated to the PageRank implementation:

| File | Failures | Root Cause |
|------|----------|------------|
| `commands.test.ts` | 4 | CLI binary not found in worktree (no compiled dist) |
| `agent-worker.test.ts` | 2 | `node_modules/.bin/tsx` missing in worktree |
| `detached-spawn.test.ts` | 2 | `node_modules/.bin/tsx` missing in worktree |
| `worker-spawn.test.ts` | 1 | `node_modules/.bin/tsx` missing in worktree |

These same 4 files would fail in any fresh worktree without a local `npm install` and build. The main branch passes all 21 test files (250 tests) with a proper install.

## Implementation Review

### `src/orchestrator/pagerank.ts` (new file)
- **`buildDependentsMap`**: Correctly builds reverse adjacency map. Filters to `"blocks"` edges only — `"parent"` edges are excluded as intended.
- **`getDirectDependents`**: Simple, correct wrapper over the map lookup.
- **`getTransitiveDependents`**: BFS traversal using the `exclude` set as both the starting frontier and visited guard. Handles diamond topologies correctly (no double-counting). Cycle-safe via visited set.
- **`priorityBoost`**: Returns correct values P0→1.0 through P4→0.0. Parameter narrowed to `string` (matching `Seed.priority` interface) — unknown values fall to `default: 0.0`.
- **`calculateImpactScores`**: Combines direct×1.0 + indirect×0.5 + priorityBoost correctly.

### `src/orchestrator/dispatcher.ts` (modified)
- PageRank scoring injected after `seeds.ready()`, before the dispatch loop.
- Skipped when `opts?.seedId` is set (single-seed dispatch — scoring is unnecessary and the graph fetch would be wasteful).
- Graceful fallback: `try/catch` around `seeds.getGraph()` logs warning and preserves original order on error.
- Stable sort by score (descending), with priority field as tie-breaker (P0 first).
- `PLAN_STEP_MAX_BUDGET_USD = 3.00` constant is already present and used correctly.

## Issues Found

**None.** All 28 pagerank tests pass. No regressions in dispatcher.test.ts (11/11). The implementation matches the EXPLORER_REPORT spec exactly:
- Only `"blocks"` edges counted ✓
- Impact formula: `direct × 1.0 + indirect × 0.5 + priorityBoost` ✓
- Graceful fallback on graph unavailability ✓
- Tie-breaking by priority field ✓
- Diamond topology handled without double-counting ✓

## Files Modified
- None — all tests pass without modification.

## Files Reviewed (read-only)
- `src/orchestrator/pagerank.ts` — new file, correct implementation
- `src/orchestrator/dispatcher.ts` — integration correct
- `src/orchestrator/__tests__/pagerank.test.ts` — 28 tests, comprehensive coverage
- `src/orchestrator/__tests__/dispatcher.test.ts` — 11 pre-existing tests, all still pass
