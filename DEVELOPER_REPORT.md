# Developer Report: Cost tracking with per-agent and per-phase breakdowns

## Approach

The core implementation was already in place from a prior iteration. This pass addressed the feedback from the code review ([NOTE]-level issues):

1. **Failed QA phase costs were silently dropped** — the QA phase consumes real tokens even when it fails. Fixed by recording `recordPhaseCost` before calling `markStuck` or returning early.
2. **Architectural seam in `getMetrics()`** — documented via code comment that `totalCost`/`totalTokens` come from the `costs` table while phase breakdowns come from `phase_costs`, and both filter on `recorded_at` independently.
3. **`agent_type TEXT NOT NULL DEFAULT ''`** — added a comment in the schema explaining the empty-string default is intentional for backward compatibility; the application always supplies a non-empty value.
4. **Missing foreign-key enforcement test** — added a test confirming that `recordPhaseCost` with a non-existent `run_id` throws (since `PRAGMA foreign_keys = ON` is set at store construction).

## Files Changed

- `src/orchestrator/agent-worker.ts` — Fixed two QA phase cost recording locations:
  - In the primary dev-QA loop (line ~564): records `phase_costs` and updates `progress.phaseCosts` regardless of `qaResult.success`, then calls `markStuck`/returns only on failure.
  - In the review-feedback branch (line ~636): same pattern — records cost unconditionally, emits the `complete` event only on success.

- `src/lib/store.ts` — Added two code comments:
  - In the `phase_costs` schema: explains the `DEFAULT ''` choice.
  - In `getMetrics()`: documents the architectural seam between the `costs` and `phase_costs` tables when `since` filtering is used.

- `src/lib/__tests__/store-metrics.test.ts` — Added one new test:
  - `recordPhaseCost throws on non-existent runId (foreign key enforced)` — verifies SQLite foreign key enforcement is active.

## Tests Added/Modified

- `src/lib/__tests__/store-metrics.test.ts`:
  - Added: `recordPhaseCost throws on non-existent runId (foreign key enforced)` — covers the previously untested foreign-key behavior.
  - All 10 tests in the file pass.

## Decisions & Trade-offs

- **Cost recorded before markStuck**: Recording the cost and updating `progress.phaseCosts` before calling `markStuck` ensures the progress snapshot stored by `markStuck` includes the partial QA cost in `phaseCosts`. This is the most accurate representation.
- **Guard `costUsd > 0`**: Phase cost recording is guarded by `qaResult.costUsd > 0` to avoid inserting zero-cost rows when the SDK stream ended without returning a result (those return `costUsd: 0`).
- **Schema comment over migration**: The `agent_type DEFAULT ''` is only a style concern; altering a NOT NULL column in SQLite requires a full table rebuild. A comment is the appropriate fix.

## Known Limitations

- The `getMetrics()` architectural seam (separate `costs` and `phase_costs` tables filtered independently) is documented but not resolved. A future consolidation could unify them, but that would be a larger breaking schema change.
- Cache-read tokens (`cache_read`) are recorded as `0` for all phases because the SDK does not currently expose per-phase cache token counts separately.
