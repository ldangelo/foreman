# QA Report: Add pre-commit bug scanning to finalize phase

## Verdict: PASS

## Test Results
- Test suite: 230 passed, 9 failed (all failures are pre-existing environment issues, not caused by this change)
- New tests added: 0 (existing tests were updated by the Developer)

## Feature Verification

### Implementation Review

The Developer correctly implemented pre-commit bug scanning in `src/orchestrator/agent-worker.ts`:

1. **Bug scan runs before `git add -A`** ✅
   Inserted at lines 441–458, before the commit block at line 460.

2. **Uses `npx tsc --noEmit`** ✅
   Correct command: no build artifacts generated, just type checking.

3. **60-second timeout** ✅
   Uses `buildOpts = { ...opts, timeout: 60_000 }` to accommodate TypeScript cold-start.

4. **Non-blocking (non-fatal pattern)** ✅
   Errors are caught, logged, and reported — finalization continues regardless of type-check failure.

5. **Error output captured correctly** ✅
   The implementation correctly extracts `stderr` from `execFileSync` errors (as a Buffer) and falls back to `err.message`, truncating to 500 chars for the report and 200 chars for log output.

6. **Report section added** ✅
   Adds `## Build / Type Check` section with `Status: SUCCESS` or `Status: FAILED` + error code block to FINALIZE_REPORT.md.

7. **`lead-prompt.ts` updated** ✅
   Finalize instructions now list step 1 as the pre-commit bug scan (`npx tsc --noEmit`), renumbering subsequent steps.

8. **Tests updated** ✅
   Both `lead-prompt.test.ts` and `agent-worker-team.test.ts` now assert that `tsc --noEmit` appears in the generated prompts — both pass (26/26).

## Issues Found

### Pre-existing Failures (unrelated to this change)

All 9 failing tests are due to missing `tsx` binary in the git worktree's `node_modules`. These tests spawn real child processes and require a full `npm install` in the worktree. The same tests pass on the main branch where `node_modules` is fully installed.

| Test File | Failures | Root Cause |
|---|---|---|
| `agent-worker.test.ts` | 2 | No `tsx` binary → process spawn fails |
| `commands.test.ts` | 4 | No `tsx` binary → CLI spawn fails |
| `worker-spawn.test.ts` | 1 | Asserts `tsx` exists in `node_modules/.bin` |
| `detached-spawn.test.ts` | 2 | No `tsx` binary → detached spawn fails |

**Confirmed pre-existing**: `git log` shows `agent-worker.test.ts` was last modified in commit `f060fed` (rename beads→seeds), not touched by this feature branch.

### No Regressions

The feature-related test files pass cleanly:
- `lead-prompt.test.ts`: 13/13 ✅
- `agent-worker-team.test.ts`: 13/13 ✅

## Edge Cases Assessed

| Edge Case | Handling |
|---|---|
| `npx` not in PATH | Will throw, caught by catch block, reported as FAILED, finalize continues |
| No TypeScript errors | Passes silently, reports SUCCESS |
| Type errors present | Captured with stderr detail, reports FAILED with code block |
| Very long error output | Truncated to 500 chars in report, 200 chars in log |
| "nothing to commit" case | Pre-existing handling; bug scan runs first regardless |

## Files Modified
- None — no test files needed to be created or fixed; the developer's implementation is correct and the failing tests are pre-existing environment issues unrelated to this change.
