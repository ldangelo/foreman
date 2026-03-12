# QA Report: Replace maxTurns with maxBudgetUsd for pipeline phase limits

## Verdict: PASS

## Test Results
- Test suite: 228 passed, 9 failed (all failures are pre-existing infrastructure issues, not related to this change)
- New tests added: 3 (added by Developer in roles.test.ts)

## Analysis of Failures

All 9 test failures are pre-existing infrastructure issues caused by the worktree environment lacking a `tsx` binary in its local `node_modules/.bin/`. The worktree's `node_modules` directory contains only `.vite` and `.vite-temp` entries and does not have a `tsx` symlink. Tests that spawn `tsx` as a child process fail with `ENOENT`.

Affected test files (all pre-existing failures, unrelated to this change):
- `src/orchestrator/__tests__/agent-worker.test.ts` — 2 failed (tsx ENOENT)
- `src/cli/__tests__/commands.test.ts` — 4 failed (tsx ENOENT)
- `src/orchestrator/__tests__/worker-spawn.test.ts` — 1 failed (tsx ENOENT)
- `src/orchestrator/__tests__/detached-spawn.test.ts` — 2 failed (tsx ENOENT)

Verification: Running the same tests from the main project directory (which has full node_modules) yields 234 tests passing with 0 failures.

## Implementation Review

The change is complete and correct:

1. **`src/orchestrator/roles.ts`** — `RoleConfig` interface renamed `maxTurns: number` → `maxBudgetUsd: number`. Budget values set:
   - explorer (haiku): $1.00
   - developer (sonnet): $5.00
   - qa (sonnet): $3.00
   - reviewer (sonnet): $2.00

2. **`src/orchestrator/agent-worker.ts`** — `runPhase()` function updated:
   - Log format changed from `maxTurns=N` to `maxBudgetUsd=N`
   - SDK query options changed from `maxTurns: roleConfig.maxTurns` to `maxBudgetUsd: roleConfig.maxBudgetUsd`

3. **`src/orchestrator/dispatcher.ts`** — `dispatchPlanStep()` updated from `maxTurns: 50` to `maxBudgetUsd: 3.00`

4. **TypeScript compilation** — `npx tsc --noEmit` passes with zero errors.

5. **SDK compatibility** — `maxBudgetUsd` is a valid SDK option per the `@anthropic-ai/claude-agent-sdk` type definitions (sdk.d.ts line 906). The SDK also already handled `error_max_budget_usd` in error detection logic.

## Tests Added by Developer

The developer added 3 new tests to `src/orchestrator/__tests__/roles.test.ts`:
- `all roles have positive maxBudgetUsd values` — verifies all configs have `maxBudgetUsd > 0`
- `explorer has lower budget than developer (haiku vs sonnet)` — verifies cost-tiering logic
- `all role configs have no maxTurns property` — negative assertion ensuring old property is fully removed

All 21 tests in `roles.test.ts` pass.

## Issues Found
- None related to the task implementation.
- Pre-existing: worktree node_modules missing tsx binary causes 9 tests to fail when run from the worktree directory. This is an environment setup issue, not a code defect.

## Files Modified
- No test files modified by QA (developer-added tests were already correct)
