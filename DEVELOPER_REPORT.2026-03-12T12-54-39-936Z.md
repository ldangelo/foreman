# Developer Report: Cost tracking with per-agent and per-phase breakdowns

## Approach

Implemented a `phase_costs` table in SQLite to persistently track costs broken down by pipeline phase (explorer, developer, qa, reviewer) and agent model. Extended the in-memory `RunProgress` struct with a `phaseCosts` record so the CLI watch UI can show live per-phase cost breakdown without extra DB queries. Updated `getMetrics()` to include phase aggregations in its return value.

## Files Changed

- `src/lib/store.ts` — Added `phase_costs` table to schema; added `PhaseCostRecord`, `CostByPhase`, `CostByAgentAndPhase` interfaces; extended `Metrics` with `costByPhase` and `costByAgentAndPhase` fields; added `recordPhaseCost()`, `getCostsByPhase()`, `getCostsByAgentAndPhase()` methods; updated `getMetrics()` to include phase breakdowns; added `phaseCosts` field to `RunProgress` interface

- `src/orchestrator/agent-worker.ts` — Extended `PhaseResult` interface with `tokensIn`/`tokensOut`; updated all return paths in `runPhase()` to include token data; added `store.recordPhaseCost()` calls and `progress.phaseCosts` accumulation after each phase completion (including all retry paths)

- `src/cli/watch-ui.ts` — Added "By Phase" cost breakdown line to `renderAgentCard()` when `progress.phaseCosts` has data, using abbreviated phase names

- `src/cli/commands/status.ts` — Extended the Costs section to show "By Phase" and "By Agent & Phase" breakdowns using `metrics.costByPhase` and `metrics.costByAgentAndPhase`

## Tests Added/Modified

- `src/lib/__tests__/store-metrics.test.ts` — Added 5 new test cases:
  - `getCostsByPhase` aggregates correctly across multiple runs
  - `getCostsByPhase` respects date filtering (future/past)
  - `getCostsByAgentAndPhase` produces correct 2D breakdown by model × phase
  - `getMetrics` includes `costByPhase` and `costByAgentAndPhase` in return value
  - Empty project returns empty arrays for both new fields

All 9 tests pass (4 existing + 5 new).

## Decisions & Trade-offs

- **Separate `phase_costs` table** rather than adding a `phase` column to `costs`: avoids breaking existing queries and allows multiple cost records per phase (dev/QA retry loops record each pass separately)
- **`phaseCosts` in `RunProgress`**: allows live display in watch-ui without additional DB queries; accumulated in-memory as each phase completes, then persisted via `updateRunProgress`
- **`agent_type` stored in `phase_costs`**: enables the agent×phase 2D breakdown without JOINs; the role model is passed from `ROLE_CONFIGS` at the call site
- **`getMetrics()` delegates** to `getCostsByPhase()` / `getCostsByAgentAndPhase()` internally to avoid query duplication

## Known Limitations

- Existing runs (before this change) will have no `phase_costs` records; `costByPhase` will return empty arrays for historical data
- Cache-read tokens are recorded as `0` — the SDK `PhaseResult` doesn't expose cache token breakdown, only `input_tokens` / `output_tokens`
- The watch-ui phase breakdown only shows phases with cost > 0 and is limited to the 4 known phases; the `currentPhase: "finalize"` phase has no SDK cost and is not shown
