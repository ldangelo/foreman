# Developer Report: Cost tracking with per-agent and per-phase breakdowns

## Approach

Extended the existing progress tracking infrastructure to store per-phase costs and agent attribution inside the `RunProgress` JSON column (already stored in SQLite). This avoids any database schema changes while adding full per-phase and per-agent cost visibility.

The approach follows the Explorer's recommended plan exactly:
1. Extend `RunProgress` and `Metrics` interfaces with optional phase/agent fields
2. Record phase costs in `agent-worker.ts` immediately after each phase completes
3. Add `getCostBreakdown()` and `getPhaseMetrics()` query methods to `ForemanStore`
4. Update `getMetrics()` to aggregate phase costs
5. Update `watch-ui.ts` to show per-phase breakdown in agent cards
6. Update `status.ts` to show phase and model breakdown in the Costs section

## Files Changed

- **src/lib/store.ts** — Added `costByPhase` and `agentByPhase` optional fields to `RunProgress` interface; added `costByPhase` and `agentCostBreakdown` optional fields to `Metrics` interface; added `getCostBreakdown(runId)` and `getPhaseMetrics(projectId?, since?)` methods; updated `getMetrics()` to call `getPhaseMetrics()` and populate the new fields.

- **src/orchestrator/agent-worker.ts** — In `runPhase()`, after accumulating totals, now also records `progress.costByPhase[role]` and `progress.agentByPhase[role]` with the phase's cost and the model used from `roleConfig.model`.

- **src/cli/watch-ui.ts** — In `renderAgentCard()`, after displaying the total cost, shows a per-phase cost breakdown with agent model hints when `costByPhase` data is present. Phases are sorted in pipeline order (explorer → developer → qa → reviewer).

- **src/cli/commands/status.ts** — In the Costs section, added display of per-phase cost breakdown and per-model cost breakdown using data from `getMetrics()`.

- **src/lib/__tests__/store-metrics.test.ts** — Added 6 new tests covering: backwards compatibility (no phase data), `getCostBreakdown` for runs with and without phase data, `getPhaseMetrics` aggregation across runs, `getMetrics` integration with phase data, and `getMetrics` with no phase data.

## Tests Added/Modified

- **src/lib/__tests__/store-metrics.test.ts** — 6 new test cases:
  1. `empty project returns zero metrics` — extended to check `costByPhase`/`agentCostBreakdown` are undefined
  2. `getCostBreakdown returns empty records for runs without phase data`
  3. `getCostBreakdown returns empty records for runs with progress but no phase data` (backwards compat)
  4. `getCostBreakdown returns correct phase and agent costs`
  5. `getPhaseMetrics aggregates phase costs across multiple runs`
  6. `getMetrics includes costByPhase and agentCostBreakdown when phase data exists`
  7. `getMetrics omits costByPhase/agentCostBreakdown for runs without phase data`

All 10 tests pass (4 pre-existing + 6 new).

## Decisions & Trade-offs

- **Storing in progress JSON vs new DB table**: Chose the progress JSON approach to avoid schema migrations. The progress column already stores arbitrary JSON; adding optional fields is backward-compatible.

- **Phase costs are cumulative per role**: Since developer can run multiple times (retry loop), `costByPhase[role]` accumulates with `+=` so all retries are summed into the phase total.

- **`getMetrics()` delegates to `getPhaseMetrics()`**: Avoids duplicating the aggregation logic. The `since` parameter is passed through so time-bounded metrics work correctly.

- **Optional fields return `undefined` when empty**: Consumers that don't need phase data are unaffected; `costByPhase` and `agentCostBreakdown` are only populated when there is actual phase data.

## Known Limitations

- **Single-agent mode**: No per-phase breakdown (there are no phases). The `costByPhase` field will be absent from progress. This is by design.
- **Finalize phase**: The finalize step runs `git` commands, not the SDK, so it has no cost to record. It correctly has no entry in `costByPhase`.
- **Phase order in display**: The `reviewer` phase is included in the order but only when `skipReview` is false. The ordering is still correct.
