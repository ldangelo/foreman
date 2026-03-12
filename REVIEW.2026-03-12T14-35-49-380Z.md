# Code Review: PageRank-based task prioritization for sd ready

## Verdict: PASS

## Summary

The implementation is clean, well-structured, and correctly satisfies the requirement. A new `pagerank.ts` module encapsulates all scoring logic with four exported functions covering the full pipeline: reverse-map construction, direct dependent lookup, BFS transitive closure, and priority boosting. Integration into `dispatcher.ts` is minimal and appropriately guarded — the graph fetch is skipped when a specific `seedId` is targeted, errors are caught and fall back gracefully to the original ready order, and the sort is applied correctly before the dispatch loop. The 28 unit tests cover all meaningful combinations of graph topologies, edge types, and priority values. No security issues exist. One minor logic subtlety in `getTransitiveDependents` is worth documenting below, but it is functionally correct.

## Issues

- **[NOTE]** `src/orchestrator/pagerank.ts:95-96` — The BFS starts its queue with `[...exclude]` (the direct dependents) and the visited set is pre-seeded with both `seedId` and all `exclude` entries. This design is correct but subtly non-obvious: the function is computing "nodes reachable from the direct dependents that are not themselves direct dependents." If `exclude` is passed as an empty set (or a caller omits it), the BFS starts with an empty queue and immediately returns `[]`, which is the right behavior for a seed with no direct dependents. This is verified by test coverage, but the JSDoc comment could be clearer that `exclude` serves the dual role of both the BFS starting frontier and the exclusion filter.

- **[NOTE]** `src/orchestrator/dispatcher.ts:77-79` — The fallback error is logged via `log()`, which routes to `console.error`. This is consistent with the rest of the file's logging style and appropriate for a non-fatal degradation, but callers (e.g. `foreman run`) have no way to surface this warning to the user in the terminal output. If the graph becomes persistently unavailable, users won't know that PageRank ordering is silently disabled. This is a minor observability gap and can be addressed in a follow-up.

- **[NOTE]** `src/orchestrator/pagerank.ts:124` — `priorityBoost` accepts `string | undefined` and the `Seed` interface declares `priority: string` (not `string | undefined`). The broader signature is defensive and harmless, but it slightly mismatches the interface. No actionable impact.

## Positive Notes

- Excellent separation of concerns: all scoring logic lives in `pagerank.ts` and is independently unit-testable; `dispatcher.ts` only contains the integration glue.
- The BFS cycle guard (`visited` set) is present and correct, protecting against malformed dependency graphs even though they should not occur in practice.
- Only `"blocks"` edges are counted — `"parent"` edges are correctly filtered, consistent with `sd ready` semantics as documented in the project memory.
- The sort in `dispatcher.ts` copies the array (`[...readySeeds]`) before sorting, avoiding mutation of the original `readySeeds` reference prior to the `seedId` filter check below it.
- Tie-breaking by priority field after impact score is a sensible fallback that respects the user's explicit priority assignments.
- Test coverage is thorough: diamond dependency deduplication, multi-level chains, mixed edge types, empty graphs, and all priority values are all exercised.
- The scoring is skipped entirely when `opts.seedId` is set, avoiding a pointless graph fetch for single-seed dispatch.
- QA confirmed all 28 new tests pass with zero regressions in the existing suite.
