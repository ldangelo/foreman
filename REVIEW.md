# Code Review: Extract per-phase maxTurns to environment variables

## Verdict: FAIL

## Summary

The implementation is well-structured and correctly extracts all five hardcoded budget constants (`FOREMAN_EXPLORER_MAX_BUDGET_USD`, `FOREMAN_DEVELOPER_MAX_BUDGET_USD`, `FOREMAN_QA_MAX_BUDGET_USD`, `FOREMAN_REVIEWER_MAX_BUDGET_USD`, `FOREMAN_PLAN_STEP_MAX_BUDGET_USD`) into environment variables via a new `config.ts` helper. The `getBudgetFromEnv()` function handles all invalid-input edge cases correctly and the new `config.test.ts` tests are thorough. Production code is correct and backward-compatible. However, the updated `roles.test.ts` contains a logic flaw in the env-var-set branch that will cause test failures if the env var is set to an invalid value (zero, negative, non-numeric, Infinity), because it calls `parseFloat()` directly rather than mimicking `getBudgetFromEnv`'s validation/fallback behaviour.

## Issues

- **[WARNING]** `src/orchestrator/__tests__/roles.test.ts:49-55,60-66` — The `else` branches for the developer and reviewer budget tests call `parseFloat(process.env[VAR])` directly, which returns `NaN`/`0`/negative for invalid values. `getBudgetFromEnv` would fall back to the default in those same cases, so `expect(ROLE_CONFIGS.developer.maxBudgetUsd).toBe(parseFloat("0"))` fails as `expect(5.00).toBe(0)`. The `else` branch should either use `getBudgetFromEnv(VAR, defaultValue)` as the expected value, or guard `parseFloat(raw) > 0` before using it.

- **[NOTE]** `src/orchestrator/roles.ts` — `ROLE_CONFIGS` is initialised once at module-load time, so environment variables must be set before the module is imported. This is the expected Node.js pattern and tests work correctly, but it means you cannot override a role budget within the same process after import. Worth documenting.

- **[NOTE]** `README.md` — The Explorer report's implementation checklist included documenting the new `FOREMAN_*_MAX_BUDGET_USD` environment variables, but no documentation was added to `README.md` or a `CONFIG.md`. Users deploying the tool have no discoverable reference for these variables. Consider adding an **Environment Variables** section to the README.

## Positive Notes

- `getBudgetFromEnv` handles every invalid-input edge case (undefined, empty string, `NaN`, `Infinity`, zero, negative) with a single clean guard (`!isFinite(parsed) || parsed <= 0`). The fallback is always the supplied default, and a stderr warning is emitted only for genuinely invalid values (not for the normal "not set" case).
- All five budget constants are covered (four roles + plan step), satisfying the full scope of the task.
- Defaults are kept identical to the previous hardcoded values, so existing deployments work without any configuration changes.
- `config.test.ts` is comprehensive: 10 tests cover all documented invalid-input variants and the happy path.
- The `PLAN_STEP_MAX_BUDGET_USD` constant correctly uses `getBudgetFromEnv` at module level, consistent with the `ROLE_CONFIGS` pattern.
- TypeScript compilation is clean (`tsc --noEmit` exits 0).
