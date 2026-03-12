# Developer Report: Replace maxTurns with maxBudgetUsd for pipeline phase limits

## Approach

Replaced the turn-based `maxTurns` limit with a budget-based `maxBudgetUsd` limit across the three files that configure and use phase limits. The change is a clean rename of the interface property and corresponding config values, plus substituting `maxBudgetUsd` in the SDK `query()` options.

## Files Changed

- `src/orchestrator/roles.ts` — Renamed `maxTurns: number` to `maxBudgetUsd: number` in `RoleConfig` interface. Updated `ROLE_CONFIGS` values with estimated USD budgets per phase:
  - explorer (haiku): $1.00 — Haiku is cheap; 30 light turns ~$0.30–$0.60 worst case
  - developer (sonnet): $5.00 — Heavier workload with file writes; 80 turns
  - qa (sonnet): $3.00 — Moderate, runs tests and reviews
  - reviewer (sonnet): $2.00 — Mostly read-only analysis, lighter
- `src/orchestrator/agent-worker.ts` — Updated `runPhase()` to log `maxBudgetUsd` instead of `maxTurns` (line ~322) and pass `maxBudgetUsd: roleConfig.maxBudgetUsd` to the SDK `query()` options (line ~337).
- `src/orchestrator/dispatcher.ts` — Replaced hard-coded `maxTurns: 50` with `maxBudgetUsd: 3.00` in `dispatchPlanStep()`.

## Tests Added/Modified

- `src/orchestrator/__tests__/roles.test.ts` — Added three new test cases:
  1. "all roles have positive maxBudgetUsd values" — asserts each role's budget is > 0
  2. "explorer has lower budget than developer (haiku vs sonnet)" — validates cost hierarchy
  3. "all role configs have no maxTurns property" — ensures old property is fully removed

All 21 tests pass (18 pre-existing + 3 new).

## Decisions & Trade-offs

- **Budget values are conservative estimates** — based on typical token usage patterns. Explorer gets $1.00 (haiku is cheap, 30 turns). Developer gets $5.00 (sonnet + many file operations). QA and reviewer get $3.00 and $2.00 respectively. These should be monitored and adjusted based on real run data.
- **No backwards compatibility concern** — `maxTurns` was only used internally within the pipeline; no external API or stored data references it.
- **Error handling for `error_max_budget_usd` was already in place** in agent-worker.ts (line 225) — no changes needed there.

## Known Limitations

- Budget values are estimates without production usage data. Monitor initial runs and adjust if phases consistently hit limits or have significant headroom.
- The `dispatchPlanStep` budget ($3.00) is independent of `ROLE_CONFIGS` — it could be centralized in the future but was kept consistent with the explorer report recommendation.
