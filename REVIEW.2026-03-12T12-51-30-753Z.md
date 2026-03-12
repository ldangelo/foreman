# Code Review: Replace maxTurns with maxBudgetUsd for pipeline phase limits

## Verdict: PASS

## Summary
The implementation is a clean, complete, and consistent rename of `maxTurns` to `maxBudgetUsd` across all three affected files. The budget values are reasonable (explorer $1.00, developer $5.00, qa $3.00, reviewer $2.00, plan step $3.00), TypeScript compiles without errors, no `maxTurns` references remain anywhere in `src/`, and three well-targeted tests were added to confirm the new shape. No critical or warning-level issues found.

## Issues

- **[NOTE]** `src/orchestrator/dispatcher.ts:361` — The plan-step budget (`maxBudgetUsd: 3.00`) is a magic number hard-coded inline, just as `maxTurns: 50` was before it. Consider extracting it to a named constant (e.g. `PLAN_STEP_MAX_BUDGET_USD = 3.00`) to make future adjustments easier and to match how roles use `ROLE_CONFIGS`. Not a blocker.

- **[NOTE]** `src/orchestrator/__tests__/roles.test.ts:42-44` — The "explorer < developer" budget test guards one ordering relationship; it does not verify the absolute values (e.g. developer === 5.00). If a future change accidentally drops developer to $0.50 it would still pass. Pinning at least the developer or reviewer budget to an expected value would strengthen regression coverage.

## Positive Notes
- All three call sites updated atomically — no stale `maxTurns` references remain anywhere in `src/`.
- The pre-existing `error_max_budget_usd` error-subtype handling in `agent-worker.ts` now has a corresponding SDK option that can actually trigger it, making the error path coherent end-to-end.
- New test asserting `.not.toHaveProperty("maxTurns")` is a clean contract test that will catch any accidental reintroduction.
- TypeScript-clean (`tsc --noEmit` passes), confirming the SDK accepts `maxBudgetUsd` as a valid `query()` option.
- Budget values are proportional to role complexity/cost (haiku Explorer cheapest, sonnet Developer most expensive) — a sensible starting point.
