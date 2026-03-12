# Developer Report: Replace maxTurns with maxBudgetUsd for pipeline phase limits

## Approach

This iteration addressed the two NOTE-level feedback items from the previous review cycle. The core `maxTurns → maxBudgetUsd` migration was already complete; this pass tightens two remaining rough edges:

1. Extract the inline `3.00` magic number in `dispatcher.ts` to a named constant, matching the pattern used by `ROLE_CONFIGS`.
2. Strengthen the budget regression tests in `roles.test.ts` by pinning absolute USD values for `developer` and `reviewer`, so accidental budget reductions are caught.

## Files Changed

- **src/orchestrator/dispatcher.ts** — Added `PLAN_STEP_MAX_BUDGET_USD = 3.00` constant above the `Dispatcher` class and replaced the inline literal `maxBudgetUsd: 3.00` with `maxBudgetUsd: PLAN_STEP_MAX_BUDGET_USD`. This mirrors how `ROLE_CONFIGS` centralises phase budgets, making future adjustments easy to find and change.

- **src/orchestrator/__tests__/roles.test.ts** — Added two new pinned-value tests:
  - `"developer budget is $5.00"` — asserts `ROLE_CONFIGS.developer.maxBudgetUsd === 5.00`
  - `"reviewer budget is $2.00"` — asserts `ROLE_CONFIGS.reviewer.maxBudgetUsd === 2.00`

  These supplement the existing relative ordering test (`explorer < developer`) with absolute guard rails that catch regression if any budget is accidentally halved or zeroed.

## Tests Added/Modified

- **src/orchestrator/__tests__/roles.test.ts**
  - Added `"developer budget is $5.00"` — pins the developer role's exact budget
  - Added `"reviewer budget is $2.00"` — pins the reviewer role's exact budget

## Decisions & Trade-offs

- **Which roles to pin**: Chose `developer` (the most expensive phase, most likely to be accidentally changed) and `reviewer` (a meaningfully different value from `developer`). `explorer` and `qa` are implicitly covered by the ordering test (`explorer < developer`) and the "all positive" guard.
- **Constant scope**: `PLAN_STEP_MAX_BUDGET_USD` is module-scoped (not exported) since it is only used inside `dispatcher.ts`. If other modules ever need it, it can be exported at that point.
- **No changes to budget values**: The values (`developer: 5.00`, `reviewer: 2.00`, plan step: `3.00`) are intentionally preserved from the previous iteration to keep this pass focused on code quality only.

## Known Limitations

- Budget values are estimates based on expected token usage; real-world calibration should happen after a few pipeline runs with production workloads.
