# Developer Report: Extract per-phase model selection to environment variables

## Approach

This is a second-pass developer iteration addressing review feedback on an already-implemented feature. The core feature (env-var-driven model selection via `buildRoleConfigs()`) was complete. This pass focused on:

1. **[WARNING] Fix**: Preventing module-load crashes when an invalid model string is in an env var.
2. **[NOTE] Fix**: Documenting the sync requirement between `VALID_MODELS` and `types.ts`.
3. **[NOTE] Fix**: Documenting the env-var timing constraint in `agent-worker.ts`.
4. **[NOTE] Fix**: Removing a duplicate test.

## Files Changed

- `src/orchestrator/roles.ts` — Four changes:
  1. Added `DEFAULT_MODELS` constant to DRY up the hard-coded defaults; used by both `buildRoleConfigs()` and the fallback in the IIFE.
  2. Updated `buildRoleConfigs()` to reference `DEFAULT_MODELS` instead of string literals.
  3. Wrapped the module-level `ROLE_CONFIGS` initialization in an IIFE with try/catch. On `buildRoleConfigs()` failure, it logs a warning to stderr and falls back to hard-coded defaults — ensuring the module always loads successfully so `main()` can open the store and record the error.
  4. Added a comment to `VALID_MODELS` noting it must stay in sync with the `ModelSelection` union in `types.ts`.

- `src/orchestrator/agent-worker.ts` — Added a comment above the `config.env` application loop explaining that `FOREMAN_*_MODEL` values supplied via `config.env` have no effect on model selection (they arrive after `ROLE_CONFIGS` is already materialised at module load time) and that per-phase model overrides must be set in the parent process environment before the worker is spawned.

## Tests Added/Modified

- `src/orchestrator/__tests__/roles.test.ts`:
  - Added `vi` import from vitest (for `vi.restoreAllMocks()` in new suite).
  - Removed duplicate test "env var takes precedence over hard-coded default" (was functionally identical to "overrides explorer model via FOREMAN_EXPLORER_MODEL").
  - Added new `describe("ROLE_CONFIGS module-level fallback")` suite with 3 tests covering:
    - Verifying `ROLE_CONFIGS` is always a valid object (module loaded without crashing).
    - Verifying `buildRoleConfigs()` throws on invalid model (same logic the IIFE try-block executes).
    - Verifying `ROLE_CONFIGS` is consistent with a fresh `buildRoleConfigs()` call when no env vars are set.

## Decisions & Trade-offs

- **IIFE fallback uses `DEFAULT_MODELS` directly** (not a recursive `buildRoleConfigs()` call with env vars cleared): avoids mutation of `process.env` in a fallback path, which could have unintended side-effects in tests.
- **Warning goes to `console.warn` (stderr)**: consistent with typical Node.js startup-warning patterns; visible in logs without crashing the process.
- **No changes to `resolveModel()`**: it still throws on invalid input, which is the right contract for the public `buildRoleConfigs()` function (callers get a clear error). The module-level safety net is the IIFE try/catch.
- **Timing comment in `agent-worker.ts` is documentation-only**: changing the behaviour (e.g. re-initialising `ROLE_CONFIGS` after env vars are applied) would be a larger refactor out of scope for this task.

## Known Limitations

- The module-level fallback silently uses defaults when an env var is invalid; the process continues and may run phases with unexpected models. A future improvement could have `runPhase()` detect and surface the fallback as a structured warning in the run record.
- `VALID_MODELS` still requires manual maintenance in sync with `types.ts`. A unit test cross-checking the two arrays would be a stronger guarantee; deferred as it requires importing types at runtime.
