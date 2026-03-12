# QA Report: Add pre-commit bug scanning to finalize phase

## Verdict: PASS

## Test Results
- Test suite: 230 passed, 9 failed
- New tests added: 0 (developer updated 2 existing tests)
- TypeScript type check (`npx tsc --noEmit`): **0 errors**

### All 9 failures are pre-existing environment issues — NOT caused by this change

| Test File | Count | Root Cause |
|---|---|---|
| `src/cli/__tests__/commands.test.ts` | 4 | CLI binary not built (`ENOENT`) — pre-existing |
| `src/orchestrator/__tests__/detached-spawn.test.ts` | 2 + 2 uncaught | `tsx` binary missing in worktree `node_modules` — pre-existing |
| `src/orchestrator/__tests__/worker-spawn.test.ts` | 1 | `tsx` binary missing in worktree `node_modules` — pre-existing |
| `src/orchestrator/__tests__/agent-worker.test.ts` | 2 | CLI binary not built (`ENOENT`) — pre-existing |

Confirmed pre-existing: prior QA report (QA_REPORT.2026-03-12T16-06-29-889Z.md) documents the identical 9 failures with the same root causes before this change was applied.

### Feature-relevant tests: ALL PASS

| Test File | Tests | Status |
|---|---|---|
| `src/orchestrator/__tests__/lead-prompt.test.ts` | 13 | ✅ PASS |
| `src/orchestrator/__tests__/agent-worker-team.test.ts` | 13 | ✅ PASS |

## Implementation Review

### Core Feature: Pre-commit Bug Scan in `finalize()` (agent-worker.ts)

**Correct.** A `npx tsc --noEmit` type-check block was inserted immediately after the report header initialization and **before** `git add -A` / `git commit`. The implementation:

- ✅ Runs **before** commit (line 441–458, commit starts at line 460)
- ✅ Non-blocking — `catch` records the failure in `FINALIZE_REPORT.md` and continues (consistent with how push/close failures are handled)
- ✅ Uses `execFileSync` with array args (no shell injection risk)
- ✅ Uses a separate `buildOpts` with 60s timeout (appropriate for TypeScript cold starts)
- ✅ Extracts `err.stderr` buffer for clean compiler output (not Node.js wrapper noise)
- ✅ Truncates errors: 500 chars in report, 200 chars in log (matches project conventions)
- ✅ Writes to both console log and `logFile`
- ✅ Report section `## Build / Type Check` with `Status: SUCCESS` or `Status: FAILED`

### Lead Prompt Update (lead-prompt.ts)

**Correct.** Finalize section updated from 4 steps to 5, with `npx tsc --noEmit` as step 1. Subsequent git operations renumbered 2–5.

### Test Updates

**Correct.** Both prompt-content tests updated:
- Test names updated to include "bug scan"
- `expect(prompt).toContain("tsc --noEmit")` assertion added to both

### Bonus Changes (out of original task scope)

The developer also added:
- **`refinery.ts`**: `getCompletedRuns()` and `orderByDependencies()` (Kahn's algorithm topological sort) methods
- **`merge.ts`**: `--seed <id>` and `--list` CLI options

These are clean, TypeScript-type-correct additions. The `orderByDependencies` implementation is logically correct (verified by code review): builds adjacency/in-degree maps from the seed graph, runs Kahn's BFS, falls back to original order if graph is unavailable. The `--seed` and `--list` options integrate correctly with the refinery.

**Gap**: `getCompletedRuns()` and `orderByDependencies()` have no unit tests. These are bonus out-of-scope additions and fall outside the task's test plan obligation; however, they represent untested logic in the refinery.

## Issues Found

None that affect this feature. The 9 test failures are pre-existing infrastructure issues in the worktree environment (missing `tsx` binary, unbuilt CLI).

## Files Modified

None — no test files were created or fixed. The developer's implementation is correct and the existing tests were already updated by the developer.
