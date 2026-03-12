# Developer Report: Extract per-phase maxTurns to environment variables

## Approach

Created a small `config.ts` helper module with a `getBudgetFromEnv()` function that reads budget
values from environment variables with fallback to hardcoded defaults. Updated `roles.ts` and
`dispatcher.ts` to use this helper, leaving all default values unchanged so existing deployments
require no configuration changes.

## Files Changed

- `src/orchestrator/config.ts` — **New file.** Exports `getBudgetFromEnv(varName, defaultValue)`
  which parses a `process.env` string as a positive float and falls back to the provided default
  when the variable is absent, empty, non-numeric, zero, or negative. Logs a `console.warn` on
  invalid input for operational visibility.

- `src/orchestrator/roles.ts` — Imported `getBudgetFromEnv` and replaced the four inline numeric
  literals in `ROLE_CONFIGS` with calls to `getBudgetFromEnv`:
  - `FOREMAN_EXPLORER_MAX_BUDGET_USD` (default 1.00)
  - `FOREMAN_DEVELOPER_MAX_BUDGET_USD` (default 5.00)
  - `FOREMAN_QA_MAX_BUDGET_USD` (default 3.00)
  - `FOREMAN_REVIEWER_MAX_BUDGET_USD` (default 2.00)

- `src/orchestrator/dispatcher.ts` — Imported `getBudgetFromEnv` and replaced the hardcoded
  `PLAN_STEP_MAX_BUDGET_USD = 3.00` constant with an env-var-driven value:
  - `FOREMAN_PLAN_STEP_MAX_BUDGET_USD` (default 3.00)

## Tests Added/Modified

- `src/orchestrator/__tests__/config.test.ts` — **New file.** 10 tests covering `getBudgetFromEnv`:
  - Returns default when env var is unset or empty
  - Returns parsed float for valid positive values (float and integer)
  - Returns default for non-numeric strings, zero, negative numbers, Infinity, NaN

- `src/orchestrator/__tests__/roles.test.ts` — Updated the two pinned-value tests
  (`developer budget is $5.00` and `reviewer budget is $2.00`) to be env-var-aware: they check the
  actual env var value when set, or assert the default when not set. This prevents spurious failures
  if someone runs tests with custom env vars.

## Decisions & Trade-offs

- **Module-level evaluation**: `ROLE_CONFIGS` is a top-level `const`, so budget values are resolved
  at module import time. This means env vars must be set before the process starts (standard
  practice). No lazy evaluation was introduced to keep the code simple.

- **Warn, don't throw**: Invalid env var values produce a `console.warn` and fall back to the
  default rather than crashing the process. Operational deployments should notice the warning and
  fix the configuration, but won't be broken by a typo.

- **All vars optional**: Every env var has a default matching the original hardcoded value, ensuring
  full backward compatibility.

- **Helper in separate module**: Placing `getBudgetFromEnv` in `config.ts` keeps `roles.ts` focused
  on role definitions and makes the helper independently testable and reusable.

## Known Limitations

- Since `ROLE_CONFIGS` is evaluated at import time, you cannot change budget values without
  restarting the process. A future improvement could make budgets configurable per-run via CLI
  flags, but that is out of scope for this task.
- No documentation file (README/CONFIG.md) was added per the Explorer recommendation; that is a
  separate documentation task.
