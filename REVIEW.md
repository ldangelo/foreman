# Code Review: Cost tracking with per-agent and per-phase breakdowns

## Verdict: PASS

## Summary
The implementation is clean, complete, and correctly satisfies the requirement. A new `phase_costs` table is introduced without breaking the existing `costs` table, new store methods are well-structured, the orchestrator correctly records phase costs after each successful phase completion, and the CLI displays the information clearly. The five new tests cover the key query paths. There are a few minor observations worth noting but none rises to the level of a blocking issue.

## Issues

- **[NOTE]** `src/orchestrator/agent-worker.ts:564-566` — When QA fails in the primary dev-QA loop, `markStuck` is called and the function returns early, so no `recordPhaseCost` is called for the failed QA run. The QA phase did consume real tokens (returned in `qaResult.costUsd`) that go unrecorded in `phase_costs`. In the review-feedback branch (line 633) the same pattern is used: QA cost is only recorded on `qaResult.success`. This is consistent behavior but means failed-phase costs are silently dropped from phase-level accounting, creating a small undercount. This is unlikely to matter much in practice but is worth documenting.

- **[NOTE]** `src/lib/store.ts:551-574` — `totalCost` and `totalTokens` in `getMetrics()` are aggregated from the `costs` table, while `costByPhase` and `costByAgentAndPhase` come from the new `phase_costs` table. These two tables are populated independently. If a caller uses `since` filtering, the totals and the phase breakdown will filter on different timestamp columns (`c.recorded_at` vs `pc.recorded_at`). Since both are written near the same time this won't cause issues in practice, but it is an architectural seam to be aware of.

- **[NOTE]** `src/lib/store.ts:163` — `agent_type TEXT NOT NULL DEFAULT ''` uses an empty string as default rather than `NULL`. This is harmless given that the application always passes a non-empty value, but a `NULL`-able column would be a more idiomatic SQL choice.

- **[NOTE]** `src/lib/__tests__/store-metrics.test.ts` — There is no test verifying that `recordPhaseCost` is a no-op / throws predictably when passed an invalid (non-existent) `runId`. SQLite with `FOREIGN KEY` enforcement may or may not enforce this depending on `PRAGMA foreign_keys` setting. This is informational only; the existing test suite sufficiently covers the happy-path scenarios.

## Positive Notes
- The choice of a separate `phase_costs` table rather than adding a nullable `phase` column to `costs` is the right call: it avoids breaking existing queries and allows multiple phase-cost records per run (e.g. developer retries accumulate correctly).
- `progress.phaseCosts` in `RunProgress` gives the watch UI real-time access to per-phase cost data without an extra database query during rendering — a good design decision.
- SQL queries use `COALESCE(..., 0)` defensively, so empty result sets produce zero-valued totals rather than NULLs.
- The `getCostsByPhase` and `getCostsByAgentAndPhase` methods share a consistent parameter pattern with the rest of the store, making them easy to understand and extend.
- Phase cost recording is correctly placed after the early-return on failure, so only verified-successful phase costs land in the database.
- Test coverage for the new store methods is thorough: aggregation, date filtering, 2D breakdown, `getMetrics` integration, and empty-state are all exercised.
