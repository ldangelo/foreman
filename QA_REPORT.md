# QA Report: Extract per-phase maxTurns to environment variables

## Verdict: PASS

## Test Results
- Test suite: 240 passed, 9 failed
- New tests added: 0 (10 new tests already added by Developer in config.test.ts)

### Task-Relevant Tests (all pass)
- `src/orchestrator/__tests__/config.test.ts`: 10/10 passed
- `src/orchestrator/__tests__/roles.test.ts`: 23/23 passed
- Total task-relevant: **33/33 passed**

### Pre-Existing Failures (unrelated to this task)
The 9 failing tests are all pre-existing failures caused by missing `tsx` binary in the worktree's `node_modules/.bin/tsx`. They fail identically before and after the foreman-9a07 changes:
- `src/orchestrator/__tests__/agent-worker.test.ts`: 2 failures (tsx binary not found)
- `src/orchestrator/__tests__/detached-spawn.test.ts`: 2 failures + 2 unhandled errors (tsx binary not found)
- `src/orchestrator/__tests__/worker-spawn.test.ts`: 1 failure (tsx binary not found)
- `src/cli/__tests__/commands.test.ts`: 4 failures (tsx binary not found)

## Issues Found
None. The implementation is correct:

1. **`src/orchestrator/config.ts`** — New `getBudgetFromEnv()` helper correctly handles all edge cases: unset, empty string, non-numeric, zero, negative, `Infinity`, `NaN` — all fall back to defaults with a warning emitted only for genuinely invalid values.

2. **`src/orchestrator/roles.ts`** — `ROLE_CONFIGS` reads all four phase budgets from environment variables at module-load time with correct defaults ($1 explorer, $5 developer, $3 QA, $2 reviewer). JSDoc documents module-load-time behavior and all four env var names.

3. **`src/orchestrator/dispatcher.ts`** — `PLAN_STEP_MAX_BUDGET_USD` uses `getBudgetFromEnv("FOREMAN_PLAN_STEP_MAX_BUDGET_USD", 3.00)` — consistent with role config pattern.

4. **`src/orchestrator/__tests__/roles.test.ts`** — Updated developer/reviewer budget tests use `getBudgetFromEnv(VAR, default)` as the expected value, correctly mirroring production logic and handling the env-var-set-to-invalid case. The previous REVIEW.md WARNING about using `parseFloat` directly has been fixed.

5. **TypeScript**: `tsc --noEmit` exits 0 — no type errors.

## Files Modified
- None — no fixes were needed. All task-related tests pass as implemented.
