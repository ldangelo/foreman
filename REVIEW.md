# Code Review: Extract per-phase model selection to environment variables

## Verdict: FAIL

## Summary
The implementation is clean, well-documented, and thoroughly tested. The `resolveModel` helper and `buildRoleConfigs()` function are nicely factored, and the 12 new tests cover all the important scenarios with proper env isolation via `beforeEach`/`afterEach`. However, there is one WARNING: if `FOREMAN_*_MODEL` is set to an invalid value, `buildRoleConfigs()` throws during module initialization (before `main()` even runs), crashing the worker process without updating the seed status in the store. The seed is silently left in whatever state the dispatcher set it to (likely "running"), which requires manual intervention to recover. This is a real operational hazard introduced by the new feature and should be addressed before shipping.

## Issues

- **[WARNING]** `src/orchestrator/roles.ts:90-91` — `ROLE_CONFIGS` is initialized at module load by calling `buildRoleConfigs()`. If an env var contains an invalid model string, `resolveModel` throws, the module fails to load, and the worker process exits with an unhandled error before `main()` runs. Because the `ForemanStore` is opened inside `main()`, the run record is never updated — the seed is left in its pre-dispatch status (e.g. "running") indefinitely. Unlike `main().catch()` at line 724, module-level errors are not caught. Consider wrapping the module-level call in a try/catch that falls back to defaults with a warning, or deferring validation to the moment the phase actually runs (inside `runPhase`), so the store is available for error recording.

- **[NOTE]** `src/orchestrator/roles.ts:22-26` — `VALID_MODELS` duplicates the values from the `ModelSelection` union in `types.ts`. There is no compile-time guarantee they stay in sync: if a new model is added to `ModelSelection`, `VALID_MODELS` must be updated manually or the new value will be rejected at runtime. A comment referencing `types.ts` or a unit test that cross-checks the arrays would help.

- **[NOTE]** `src/orchestrator/agent-worker.ts:91-93` vs `src/orchestrator/roles.ts:90-91` — Worker env vars from `config.env` are applied to `process.env` *after* the module is loaded and `ROLE_CONFIGS` is already materialized. This means `FOREMAN_*_MODEL` values passed via `config.env` have no effect on model selection. This is likely intentional (model overrides are a global/system configuration, not per-run), but it is a non-obvious timing constraint worth documenting so future callers don't expect per-run model overrides to work through `config.env`.

- **[NOTE]** `src/orchestrator/__tests__/roles.test.ts:208-213` — The "env var takes precedence over hard-coded default" test (explorer overridden from haiku to opus) is functionally identical to "overrides explorer model via FOREMAN_EXPLORER_MODEL" (lines 181-187). Both set `FOREMAN_EXPLORER_MODEL` and assert the same thing. Removing the duplicate would tighten the test suite.

## Positive Notes
- `resolveModel` is a well-factored, reusable helper with a clear error message that lists all valid options — excellent UX for operators.
- Exporting `buildRoleConfigs()` separately from the module-level `ROLE_CONFIGS` constant was the right call; it makes the function independently testable without fighting module caching.
- Test isolation with `beforeEach`/`afterEach` that saves and restores all four env vars is correct and thorough.
- The docblock on `buildRoleConfigs()` clearly documents all four env var names and their semantics — no guesswork for operators.
- Budget values and `reportFile` fields are correctly preserved as static properties, unaffected by model overrides; tests verify this explicitly.
- Empty string env vars gracefully fall back to the default — good defensive behavior.
