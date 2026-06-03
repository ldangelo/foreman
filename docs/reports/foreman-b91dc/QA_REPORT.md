# QA Report: [Backlog-003] Stall Detection

## Verdict: PASS

## Test Results

**Targeted command(s) run:**
```bash
npx vitest run src/orchestrator/__tests__/monitor.test.ts --reporter=verbose
```
- Test suite: 1 file, 14 tests all passed
- Raw summary: `Test Files 1 passed (1) | Tests 14 passed (14) | Duration 130ms`

**Full suite commands run:**
```bash
npm test -- --reporter=dot 2>&1 | tail -30
```
- Unit tests (vitest run): 1 passed
- Integration tests (vitest run): 1 passed
- E2E smoke tests: 1 passed (2 tests)
- E2E full-run tests: 1 passed (1 test)

**TypeScript compilation:**
```bash
npx tsc --noEmit 2>&1
```
- No errors (clean compile)

**Pre-flight conflict marker check:**
```bash
grep -rn --include="*.ts" --include="*.tsx" --include="*.js" '<<<<<<<\|>>>>>>>\||||||||' src/
```
- Only legitimate uses found in test fixtures and conflict-resolver documentation (no unresolved git conflict markers in source files)

## New Tests Added

`src/orchestrator/__tests__/monitor.test.ts` — 6 new tests in `checkForStalls` describe block:
- `does not mark a run as stalled when lastActivity is recent`
- `marks a run as stalled when lastActivity exceeds threshold`
- `handles multiple stalled runs`
- `skips runs with no progress data`
- `skips non-running runs`
- `skips runs that are already in a terminal success state`

## Issues Found

None.

## Files Modified (staged)

- `src/lib/config.ts` — Added `stallTimeoutMs` to `PIPELINE_LIMITS` (default 5 min, env var `FOREMAN_STALL_TIMEOUT_MS`)
- `src/orchestrator/monitor.ts` — Added `checkForStalls()` method
- `src/orchestrator/__tests__/monitor.test.ts` — Added 6 tests for `checkForStalls`
- `docs/reports/foreman-b91dc/DEVELOPER_REPORT.md` — Developer self-report

## Quality Assessment

**Implementation matches task description:**
- `checkForStalls()` uses `RunProgress.lastActivity` (not `lastEventAt` — correctly identified as non-existent in Explorer Report)
- Threshold of 5 minutes via `PIPELINE_LIMITS.stallTimeoutMs`
- Marks run as `stuck` with reason `stall` when threshold exceeded
- Retry scheduling deferred to dispatcher loop (existing `recoverStuck()` pattern), consistent with Explorer guidance

**No regressions:**
- All 14 monitor tests pass (existing 8 + new 6)
- Full test suite passes
- TypeScript compiles cleanly

**Design decisions aligned with codebase patterns:**
- Follows same structure as `detectHungSessions()` (same `MonitorStore` interface, same skip logic for terminal states, same progress-check pattern)
- Uses existing `PIPELINE_LIMITS` config infrastructure
- No session termination in this PR (matches stated deferred approach)

## Test Coverage Gaps (Recommended — Not Implemented)

QA does not modify source code. The following edge cases are noted for future test coverage:
1. **`checkForStalls` with `projectId` filter** — the method accepts `opts?.projectId` but no test exercises this. Existing `checkAll` and `detectHungSessions` tests do not cover this either, so this is a pre-existing gap.
2. **Boundaries at exact threshold** — tests use 1 min (recent) and 6/10 min (stale). A test at exactly `stallTimeoutMs` boundary would confirm the `>` (not `>=`) comparison is correct.

## Notes

- Stall detection is currently passive — `checkForStalls()` must be called by an external caller (daemon loop, CLI, etc.). This was explicitly deferred in the Developer Report. The method is self-contained and ready for wiring.
- Pi SDK session termination is not implemented; worktree cleanup will happen on next dispatch via `recoverStuck()`.