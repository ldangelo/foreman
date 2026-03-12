# Developer Report: Extract per-phase model selection to environment variables

## Approach

Added a `buildRoleConfigs()` function to `roles.ts` that reads per-phase model
selection from environment variables (`FOREMAN_EXPLORER_MODEL`,
`FOREMAN_DEVELOPER_MODEL`, `FOREMAN_QA_MODEL`, `FOREMAN_REVIEWER_MODEL`).
Each variable falls back to the existing hard-coded default when absent or empty,
preserving full backward compatibility.  Invalid values throw at startup with a
helpful error message listing the accepted values.

The exported `ROLE_CONFIGS` constant is now initialised by calling
`buildRoleConfigs()`, so all existing consumers continue to work without changes.
`buildRoleConfigs()` is also exported so tests can call it directly after
manipulating `process.env`, avoiding module-reload complexity.

## Files Changed

- `src/orchestrator/roles.ts` — added `VALID_MODELS` constant, `resolveModel()`
  helper (validates a single env var), and `buildRoleConfigs()` function; replaced
  the inline static object with a call to `buildRoleConfigs()`.

- `src/orchestrator/__tests__/roles.test.ts` — imported `buildRoleConfigs` and
  added a new `describe` block ("buildRoleConfigs — environment variable
  overrides") with 12 tests covering defaults, per-phase overrides, simultaneous
  overrides, empty-string passthrough, invalid values, and verification that
  budget/reportFile fields are unaffected by model overrides.

## Tests Added/Modified

- `src/orchestrator/__tests__/roles.test.ts`
  - Added `beforeEach`/`afterEach` that save and restore all four env vars to
    prevent test pollution.
  - 12 new test cases covering every combination of interest.
  - All 35 tests (23 pre-existing + 12 new) pass.

## Decisions & Trade-offs

- **Export `buildRoleConfigs`**: makes env-var behaviour directly testable without
  module reloading or mocking; slight increase in public API surface but
  intentionally useful for advanced callers.
- **Throw on invalid model**: fail-fast at startup rather than silently falling
  back, so misconfigured deployments are caught immediately.
- **Empty string treated as absent**: `""` falls back to the default, which is the
  natural behaviour for unset variables in many shell environments
  (`export FOREMAN_EXPLORER_MODEL=`).
- **Budget/reportFile not configurable via env vars**: out of scope for this task;
  only model selection was requested.

## Known Limitations

- Env vars are read once at module-import time for the `ROLE_CONFIGS` constant.
  Changing them after import has no effect on `ROLE_CONFIGS` (but callers can
  invoke `buildRoleConfigs()` again if needed).
- No env-var support for `maxBudgetUsd` — deferred to a separate task if needed.
