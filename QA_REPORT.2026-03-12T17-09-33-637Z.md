# QA Report: Detect and fix seed/agent state mismatches in foreman reset

## Verdict: PASS

## Test Results
- Test suite: 252 passed, 9 failed
- New tests added: 22 (in `src/cli/__tests__/reset-mismatch.test.ts`)
- All 22 new tests pass ✓
- All 9 failures are **pre-existing environment issues** unrelated to this change (verified against previous QA reports)

### Pre-existing Failures (Not Caused by This Change)

| Test File | Failing Tests | Root Cause |
|---|---|---|
| `src/cli/__tests__/commands.test.ts` | 4 tests | CLI binary not built (`ENOENT`) |
| `src/orchestrator/__tests__/detached-spawn.test.ts` | 2 tests + 2 uncaught errors | `tsx` binary missing in worktree `node_modules` |
| `src/orchestrator/__tests__/worker-spawn.test.ts` | 1 test | `tsx` binary missing in worktree `node_modules` |
| `src/orchestrator/__tests__/agent-worker.test.ts` | 2 tests | `tsx` binary missing in worktree `node_modules` |

### New Test Coverage (all pass)

**`mapRunStatusToSeedStatus` (10 tests):**
- Maps `pending` → `in_progress` ✓
- Maps `running` → `in_progress` ✓
- Maps `completed` → `closed` ✓
- Maps `failed` → `open` ✓
- Maps `stuck` → `open` ✓
- Maps `merged` → `closed` ✓
- Maps `pr-created` → `closed` ✓
- Maps `conflict` → `open` ✓
- Maps `test-failed` → `open` ✓
- Maps unknown status → `open` ✓

**`detectAndFixMismatches` (12 tests):**
- Returns empty result when no terminal runs exist ✓
- Detects mismatch: `completed` run, seed still `in_progress` ✓
- Detects mismatch: `merged` run, seed still `in_progress` ✓
- Fixes mismatches by calling `seeds.update` ✓
- Respects dry-run mode (no updates) ✓
- Skips seeds already in the reset batch (`resetSeedIds`) ✓
- Reports no mismatch when seed status already matches expected ✓
- Silently skips seeds that no longer exist (not-found error) ✓
- Records error when `seeds.show` fails with unexpected error ✓
- Records error when `seeds.update` fails; doesn't count as fixed ✓
- Deduplicates multiple runs per seed (uses most recently created) ✓
- Handles multiple seeds with different mismatch states ✓

## TypeScript Compilation
`npx tsc --noEmit` passes with **zero errors** ✓

## Implementation Review

### Correctness
- `mapRunStatusToSeedStatus` correctly covers all run statuses defined in `Run["status"]`
- `detectAndFixMismatches` properly:
  - Skips seeds in the active-reset batch (avoids double-processing)
  - Deduplicates by seed_id using most-recently-created run
  - Respects `dryRun` flag
  - Handles `not found` seed errors silently (seed deleted externally)
  - Propagates unexpected errors to the `errors` array
  - Does not increment `fixed` counter when `seeds.update` fails

### Integration in `reset.ts`
- `detectAndFixMismatches` is called as step 7, after the main reset loop
- Summary output correctly includes `Mismatches fixed` count
- Dry-run summary includes `Would fix N mismatch(es)` message
- Errors from mismatch fixing are merged into the main error list
- Early-return removed when `runs.length === 0` so mismatch detection still runs with no active runs

### Edge Cases Validated
1. **No active runs + stale terminal runs**: mismatch detection still fires (early-return removed)
2. **Multiple runs per seed**: deduplication ensures only the most recent run's state determines expected seed status
3. **Seed deleted externally**: silently skipped, no error logged
4. **API failure on update**: recorded in errors, mismatch still counted, `fixed` not incremented

## Issues Found

None. The implementation is correct, TypeScript compiles cleanly, and all new tests pass.

## Files Modified
- `src/cli/__tests__/reset-mismatch.test.ts` — 22 new tests (new file created by Developer; no modifications needed)
