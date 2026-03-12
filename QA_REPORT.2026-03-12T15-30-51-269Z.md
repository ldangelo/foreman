# QA Report: Extract per-phase maxTurns to environment variables

## Verdict: PASS

## Summary

The developer correctly extracted hardcoded budget values from `roles.ts` and `dispatcher.ts` into environment variables via a new `config.ts` helper module. All tests directly related to this feature pass. The 9 test failures observed in the full suite are pre-existing environment issues (missing `tsx` binary in the worktree's `node_modules`) that are **not caused by the developer's changes** — the same tests pass on the main repo.

## Test Results

- **Feature tests (config.test.ts + roles.test.ts):** 33 passed, 0 failed
- **Full suite (worktree):** 240 passed, 9 failed ← pre-existing env issue (no tsx in worktree)
- **Full suite (main repo):** 250 passed, 0 failed ← confirmed failures are environment-only
- **New tests added:** 10 (in `src/orchestrator/__tests__/config.test.ts`)
- **TypeScript compilation:** No errors (`tsc --noEmit` exits 0)

## Implementation Review

### `src/orchestrator/config.ts` (new)
- Exports `getBudgetFromEnv(varName, defaultValue)` — parses env var as float
- Falls back to default when env var is absent, empty, non-numeric, zero, negative, or non-finite
- Logs a warning to stderr on invalid values (graceful degradation)
- ✅ Correct behavior, well-tested

### `src/orchestrator/roles.ts`
- All 4 role configs now read from `FOREMAN_EXPLORER_MAX_BUDGET_USD`, `FOREMAN_DEVELOPER_MAX_BUDGET_USD`, `FOREMAN_QA_MAX_BUDGET_USD`, `FOREMAN_REVIEWER_MAX_BUDGET_USD`
- Defaults unchanged ($1, $5, $3, $2)
- ✅ Backward compatible

### `src/orchestrator/dispatcher.ts`
- `PLAN_STEP_MAX_BUDGET_USD` now reads from `FOREMAN_PLAN_STEP_MAX_BUDGET_USD` with default $3.00
- ✅ Backward compatible

### `src/orchestrator/__tests__/roles.test.ts`
- Developer/reviewer budget tests updated to conditionally check either the env var value or the default
- ✅ Tests work correctly in both env var set and unset scenarios

### `src/orchestrator/__tests__/config.test.ts` (new)
- 10 tests covering: unset, empty string, valid float, integer, non-numeric, zero, negative, Infinity, NaN, multiple defaults
- ✅ All pass; warnings on stderr are expected per implementation

## Issues Found

### Pre-existing failures (NOT caused by this PR)

The following 9 failures exist because the git worktree does not have `tsx` installed in its local `node_modules/.bin/tsx`. These tests spawn child processes using `tsx` by absolute path relative to `__dirname`, which resolves to the worktree root (not the main repo). All 9 tests pass when run from the main project directory.

| Test | Error |
|------|-------|
| `commands.test.ts > --help exits 0` | ENOENT (tsx not found) |
| `commands.test.ts > --version prints version` | ENOENT (tsx not found) |
| `commands.test.ts > decompose with nonexistent file` | ENOENT (tsx not found) |
| `commands.test.ts > plan --dry-run shows pipeline steps` | ENOENT (tsx not found) |
| `agent-worker.test.ts > exits with error when no config` | tsx ENOENT → err.status is null, not 1 |
| `agent-worker.test.ts > reads and deletes config file` | tsx ENOENT → config file not deleted |
| `detached-spawn.test.ts > writes file after parent exits` | tsx ENOENT → marker file not written |
| `detached-spawn.test.ts > continues after SIGINT` | tsx ENOENT → child.pid undefined |
| `worker-spawn.test.ts > tsx binary exists in node_modules` | tsx not in worktree node_modules |

**Root cause:** Worktree was created without running `npm install`. The test infrastructure uses `path.resolve(__dirname, "../../../node_modules/.bin/tsx")` which resolves to the worktree root, not the main project root where `tsx` is installed.

**This is not a regression introduced by the developer.** These same tests fail on the baseline worktree code (pre-changes) when run from the worktree directory.

## Files Modified

- No test or source files required fixes by QA; implementation is correct as delivered.
