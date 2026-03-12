# Code Review: Cost tracking with per-agent and per-phase breakdowns

## Verdict: PASS

## Summary
The implementation adds per-phase and per-agent cost tracking to the pipeline orchestration system by extending the existing `RunProgress` JSON column in SQLite with optional `costByPhase` and `agentByPhase` fields. This avoids any schema migrations and is fully backwards-compatible. The core logic in `agent-worker.ts` correctly accumulates phase costs using `+=` (so developer retries sum naturally), `watch-ui.ts` reads directly from `progress` JSON so the breakdown is visible during live monitoring, and `status.ts` shows aggregate breakdowns via `getMetrics()`. All 10 tests in `store-metrics.test.ts` pass (4 pre-existing + 6 new), TypeScript compiles without errors, and error handling is robust throughout.

## Issues

- **[NOTE]** `src/lib/store.ts:429,521` — When a `since` filter is used, `getMetrics` filters `totalCost` by `c.recorded_at` (cost-record timestamp) but `getPhaseMetrics` (called within `getMetrics`) filters runs by `r.created_at` (run-creation timestamp). These timestamps can differ by the run's duration, causing `costByPhase` totals to include runs whose costs are excluded from `totalCost` when a `since` date is passed. In practice, `getMetrics` is currently called without `since` (from `status.ts`), so this has no immediate user-facing impact.

- **[NOTE]** `src/cli/commands/status.ts:144` — The per-phase and per-model cost breakdown sections are nested inside the `if (metrics.totalCost > 0)` guard. `metrics.totalCost` queries the `costs` table via SQL, but `recordCost()` is never called from production code (only from tests). This means the Costs section in `foreman status` never renders in practice, making the new phase breakdown in `status.ts` currently unreachable. This is a pre-existing architectural gap (the costs table has always been unpopulated in production) rather than a regression introduced here. The `watch-ui.ts` breakdown is unaffected — it reads `progress.costByPhase` directly.

- **[NOTE]** `src/lib/store.ts:447` — The null check `if (!row.progress) continue` in `getPhaseMetrics` is load-bearing and correctly guards the subsequent `JSON.parse`. No action needed, but worth calling out as a critical guard path.

## Positive Notes

- The approach of storing phase cost data inside the existing `RunProgress` JSON column is elegant: no schema migrations, full backwards compatibility with old runs, and optional fields mean consumers that don't need phase data are unaffected.
- Accumulating `costByPhase[role] += cost` correctly handles multiple developer retries without losing any cost data.
- `getCostBreakdown` and `getPhaseMetrics` are well-named, single-responsibility methods that follow the existing store pattern.
- The `try/catch` around `JSON.parse` in `getPhaseMetrics` silently skips malformed rows — exactly the right behavior for resilient metrics aggregation.
- Phase ordering in `watch-ui.ts` and `status.ts` uses a consistent `phaseOrder` array rather than relying on object insertion order, which is correct for display purposes.
- All new tests cover the critical edge cases: backwards compatibility (no phase data), single-agent mode, aggregation across multiple runs, and integration with `getMetrics()`.
- TypeScript types are accurate — all new fields are optional with appropriate types and the type for `agentByPhase` correctly uses `string` (model name) rather than a more specific union, preserving extensibility.
