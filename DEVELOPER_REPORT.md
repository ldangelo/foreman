# Developer Report: PageRank-based task prioritization for sd ready

## Approach

The implementation was largely complete from a prior iteration. This pass addressed three reviewer notes (all marked `[NOTE]`) to tighten the code quality:

1. **JSDoc clarity** — improved the `getTransitiveDependents` documentation to explicitly explain the dual role of the `exclude` parameter (both BFS frontier and exclusion filter).
2. **`priorityBoost` type alignment** — narrowed the parameter type from `string | undefined` to `string` to match the `Seed.priority: string` interface definition. The function already handled unknown values via the `default` switch branch, so no logic changed.
3. **Dispatcher observability** — the fallback warning is logged via `log()` (routes to `console.error`). This is an acknowledged minor gap: users won't see it in terminal output if PageRank is silently degraded. Deferred to a follow-up; documented in Known Limitations.

The core algorithm was already in place:
- **`src/orchestrator/pagerank.ts`** — `calculateImpactScores()` builds a reverse-dependency map (blocking edges only), then for each ready seed computes: `directDependents × 1.0 + indirectDependents × 0.5 + priorityBoost(priority)`.
- **`src/orchestrator/dispatcher.ts`** — after `seeds.ready()`, the dispatcher fetches the full graph, calculates impact scores, and sorts ready seeds descending by score (with priority as tie-breaker). Failures fall back silently to original order.

## Files Changed

- `src/orchestrator/pagerank.ts` — Improved JSDoc for `getTransitiveDependents` (dual role of `exclude` now explicitly documented); narrowed `priorityBoost` parameter type from `string | undefined` to `string`.
- `src/orchestrator/__tests__/pagerank.test.ts` — Updated the `priorityBoost(undefined)` test case to `priorityBoost("")` to match the updated signature.

## Tests Added/Modified

- `src/orchestrator/__tests__/pagerank.test.ts` — 28 tests covering all public functions:
  - `priorityBoost`: P0–P4 values, unknown values, empty string
  - `buildDependentsMap`: blocking edges, skipping parent edges, multiple dependents, empty graph
  - `getDirectDependents`: with and without dependents
  - `getTransitiveDependents`: BFS chains, diamond topology (no double-counting), empty results
  - `calculateImpactScores`: direct/indirect weights, priority boost, edge type filtering, multiple seeds, empty inputs, hub vs. leaf comparison
- `src/orchestrator/__tests__/dispatcher.test.ts` — 11 pre-existing tests for `selectModel()` continue to pass.

## Decisions & Trade-offs

- **`priorityBoost` signature**: narrowed to `string` (matching `Seed.priority`) rather than keeping `string | undefined`. The `default: 0.0` branch already handles any unrecognised string value, so the function is still robust. Callers passing the raw `seed.priority` field benefit from stronger type checking.
- **BFS vs. DFS for transitive closure**: BFS was chosen for predictable traversal order. The `visited` set guards against cycles (which shouldn't exist in valid `sd` graphs but could arise from user error).
- **Only `"blocks"` edges counted**: `"parent"` edges are organisational only and don't affect `sd ready` semantics, so inflating scores by counting them would be incorrect.

## Known Limitations

- **Dispatcher observability gap**: when `seeds.getGraph()` fails and PageRank is disabled, the warning is logged only to `console.error`. Users running `foreman run` in a terminal won't see it. If the graph becomes persistently unavailable, they won't know that ordering has silently degraded to insertion order. This can be addressed in a follow-up by surfacing the warning through the `DispatchResult` return value.
- **No caching**: impact scores are recalculated on every `dispatch()` call. For graphs with thousands of nodes this is still negligible (O(V+E) BFS), but a cache keyed on graph hash could be added if profiling reveals overhead.
