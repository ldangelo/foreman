# QA Report: Detect and fix seed/agent state mismatches in foreman reset

## Verdict: PASS

## Test Results
- Test suite: 252 passed, 9 failed
- New tests added: 22 (in `src/cli/__tests__/reset-mismatch.test.ts`)
- All 22 new tests pass
- All 9 failures are **pre-existing environment issues** unrelated to this change (tsx binary missing in worktree node_modules; main repo passes all 271 tests)

### Pre-existing Failures (Not Caused by This Change)

| Test File | Failing Tests | Root Cause |
|---|---|---|
| `src/cli/__tests__/commands.test.ts` | 4 tests | CLI binary not built (`ENOENT`) — tsx missing in worktree |
| `src/orchestrator/__tests__/detached-spawn.test.ts` | 2 tests + 2 uncaught errors | `tsx` binary missing in worktree `node_modules` |
| `src/orchestrator/__tests__/worker-spawn.test.ts` | 1 test | `tsx` binary missing in worktree `node_modules` |
| `src/orchestrator/__tests__/agent-worker.test.ts` | 2 tests | `tsx` binary missing in worktree `node_modules` |

Confirmed pre-existing: main repo (`/Users/ldangelo/Development/Fortium/foreman`) runs `npm test` with **271 passed, 0 failed**.

### New Test Coverage (all pass)

**`mapRunStatusToSeedStatus` (10 tests):**
- Maps `pending` → `in_progress`
- Maps `running` → `in_progress`
- Maps `completed` → `closed`
- Maps `failed` → `open`
- Maps `stuck` → `open`
- Maps `merged` → `closed`
- Maps `pr-created` → `closed`
- Maps `conflict` → `open`
- Maps `test-failed` → `open`
- Maps unknown status → `open` (default fallback)

**`detectAndFixMismatches` (12 tests):**
- Returns empty result when no terminal runs exist
- Detects mismatch: `completed` run, seed still `in_progress`
- Detects mismatch: `merged` run, seed still `in_progress`
- Fixes mismatches by calling `seeds.update`
- Respects dry-run mode (no updates performed)
- Skips seeds already in the reset batch (`resetSeedIds`)
- Reports no mismatch when seed status already matches expected
- Silently skips seeds that no longer exist (not-found error)
- Records error when `seeds.show` fails with unexpected error
- Records error when `seeds.update` fails; does not count as fixed
- Deduplicates multiple runs per seed (uses most recently created)
- Handles multiple seeds with different mismatch states

## TypeScript Compilation
`npx tsc --noEmit` passes with zero errors.

## Implementation Review

### What Changed
The developer implemented two iterations:
1. **Core implementation**: Added `mapRunStatusToSeedStatus`, `detectAndFixMismatches`, and integrated mismatch detection as step 7 in the reset command. Also removed the early-return when `runs.length === 0` so mismatch detection still runs even when there are no active runs to reset.
2. **Reviewer fix**: Removed a duplicate error display block (lines 285-289 in original) that printed `mismatchResult.errors` twice — once inline in the mismatch block and again in the unified `allErrors` summary. Current code shows errors only in the combined `allErrors` summary.

### Correctness
- `mapRunStatusToSeedStatus` covers all 9 run status values (`pending`, `running`, `completed`, `failed`, `stuck`, `merged`, `pr-created`, `conflict`, `test-failed`) plus a safe default
- `detectAndFixMismatches` correctly:
  - Skips seeds in the active-reset batch to avoid double-processing
  - Deduplicates by `seed_id` using most-recently-created run
  - Respects `dryRun` flag (no `seeds.update` calls in dry-run mode)
  - Handles not-found errors silently (seed deleted externally)
  - Propagates unexpected `seeds.show` errors to the `errors` array
  - Does not increment `fixed` counter when `seeds.update` fails
- The mismatch section in the CLI command correctly labels fixes as `(would fix)` in dry-run mode and `fixed` otherwise
- The `allErrors` summary consolidates errors from both the main reset loop and mismatch detection

### Edge Cases Validated
1. No active runs + stale terminal runs: mismatch detection still fires (early-return removed)
2. Multiple runs per seed: deduplication ensures only the most recent run's state determines expected seed status
3. Seed deleted externally: silently skipped, no error logged
4. API failure on `seeds.update`: recorded in errors, mismatch still counted, `fixed` not incremented
5. Seed in the `resetSeedIds` set: skipped by mismatch checker (handled by main loop)

## Issues Found
None. The implementation is correct, TypeScript compiles cleanly, and all 22 new tests pass.

## Files Modified
- `src/cli/__tests__/reset-mismatch.test.ts` — 22 new tests (created by Developer, no modifications needed by QA)
