# Developer Report: PageRank-based task prioritization for sd ready

## Approach

Implemented an impact-scoring algorithm (inspired by PageRank) that ranks ready seeds by how much downstream work they unblock. The scoring formula is:

```
score(seed) = directDependents * 1.0 + indirectDependents * 0.5 + priorityBoost(seed.priority)
```

- **directDependents**: seeds that immediately block on this one (`"blocks"` edges only)
- **indirectDependents**: seeds reachable transitively (at 50% weight to discount uncertainty)
- **priorityBoost**: P0=1.0, P1=0.8, P2=0.6, P3=0.4, P4=0.0

Only `"blocks"` edges are counted — `"parent"` edges are organisational only and do not affect `sd ready` semantics.

The Dispatcher fetches the full dependency graph once per `dispatch()` call, computes scores, and sorts the ready seeds before iterating. If `seeds.getGraph()` fails for any reason, it logs a warning and falls back to the original insertion order (graceful degradation).

## Files Changed

- **src/orchestrator/pagerank.ts** — New module with all scoring logic:
  - `calculateImpactScores(readySeeds, graph)` — main public API
  - `buildDependentsMap(graph)` — builds a reverse dependency map (seedId → Set of dependents)
  - `getDirectDependents(seedId, dependentsMap)` — direct dependent lookup
  - `getTransitiveDependents(seedId, dependentsMap, exclude)` — BFS transitive closure
  - `priorityBoost(priority)` — P0-P4 to numeric boost value

- **src/orchestrator/dispatcher.ts** — Two changes:
  1. Added `import { calculateImpactScores } from "./pagerank.js"` at top
  2. Added PageRank scoring block in `dispatch()` after `seeds.ready()`, before the specific-seed filter, with graceful try/catch fallback

## Tests Added/Modified

- **src/orchestrator/__tests__/pagerank.test.ts** — 28 unit tests covering:
  - `priorityBoost`: all P0-P4 values and unknown/undefined
  - `buildDependentsMap`: basic case, parent edge skipping, multiple dependents, empty graph
  - `getDirectDependents`: normal and empty cases
  - `getTransitiveDependents`: chain traversal, multi-level chains, diamond deduplication, empty cases
  - `calculateImpactScores`: all major scenarios (direct deps, transitive deps, priority boost, no deps, mixed edges, multiple seeds, empty inputs)

All 28 new tests pass. All 11 existing dispatcher tests continue to pass.

## Decisions & Trade-offs

1. **Separate module (`pagerank.ts`)**: Keeps scoring logic isolated and independently testable, following the existing pattern of single-responsibility files.

2. **BFS for transitive closure**: Simple and safe for DAGs; the visited set prevents infinite loops even if the graph has unexpected cycles.

3. **Only `"blocks"` edges**: Consistent with `sd ready` semantics. `"parent"` edges are organisational containers and don't represent work-blocking dependencies.

4. **Scoring weights (1.0 / 0.5 / boost)**: Conservative starting values. Direct dependents matter most; indirect dependents are weighted down to account for the uncertainty of long chains. Priority boost is added on top so P0/P1 seeds aren't buried by unrelated hub seeds.

5. **Graceful fallback**: If `getGraph()` fails (e.g. seeds not initialised, CLI error), the dispatcher logs a warning and uses the original ready order. This ensures the dispatcher never regresses.

6. **Skip scoring when `seedId` filter is active**: When dispatching a specific seed, sorting is meaningless — the list will have exactly one element. The graph fetch is skipped in that branch.

## Known Limitations

- **No caching**: The graph is re-fetched on every `dispatch()` call. For projects with thousands of seeds this may add latency (though `sd graph` is typically fast). Caching can be added later if profiling shows it matters.
- **Static weights**: The 1.0/0.5/boost coefficients are not configurable. If production usage shows the priority boost is too strong or weak relative to dependency count, the weights should be tunable.
- **No cycle detection warning**: The BFS visited-set prevents infinite loops, but cycles are silently handled rather than warned about. Cycles shouldn't occur in valid `sd` projects.
