# QA Report: Fix task status after PR creation and merge

## Verdict: PASS

## Test Results

- **Targeted command(s) run:**
  - `npm run test:unit -- src/orchestrator/__tests__/task-phase-status.test.ts src/orchestrator/__tests__/startup-sync.test.ts src/orchestrator/__tests__/refinery.test.ts`
  - `npm run test:unit -- --reporter=dot 2>&1` (full suite)
  - `npx tsc --noEmit` (type check)
- **Full unit suite command:** `npm run test:unit -- --reporter=dot 2>&1`
- **Test suite (targeted):** 3 test files, 90 passed | PASS
- **Test suite (full):** 253 test files, 3599 passed, 6 skipped | PASS
- **TypeScript compilation:** No errors
- **New tests added:** 7 new tests in `startup-sync.test.ts` + 1 new test in `task-phase-status.test.ts`

## Issues Found

- None. All tests pass.

## Summary of Implementation

The implementation fixes the task status tracking after PR creation and merge:

1. **`src/orchestrator/agent-worker.ts`** (key fix):
   - Removed the shadowing `const runtimeTaskClient = await createRuntimeTaskClient(...)` line in the finalize fallback PR creation path
   - The outer scope `runtimeTaskClient` is now used consistently with `runtimeTaskBackend` for the Refinery initialization and the status update
   - Added PR metadata writing to `PR_METADATA.json` for reconciliation detection
   - Added task status update to `"review"` after successful PR creation with non-fatal error handling
   - This ensures consistency with how `onTaskPhaseChange` handles the explicit create-pr phase

2. **`src/orchestrator/task-phase-status.ts`**: `nativeTaskStatusForPhase("create-pr")` returns `"review"` instead of `null`

3. **`src/orchestrator/refinery.ts`**: Post-merge task closure uses `"closed"` status to match `mapRunStatusToNativeTaskStatus`

4. **Tests and Documentation**: Updated to use `"closed"` instead of `"merged"` as the terminal task status

## Files Modified (read-only inspection)

- `src/orchestrator/agent-worker.ts`
- `src/orchestrator/task-phase-status.ts`
- `src/orchestrator/refinery.ts`
- `src/orchestrator/__tests__/task-phase-status.test.ts`
- `src/orchestrator/__tests__/startup-sync.test.ts`
- `src/orchestrator/__tests__/refinery.test.ts`
- `docs/PRD/PRD-2026-006-multi-project-native-task-management.md`
- `docs/TRD/TRD-2026-006-multi-project-native-task-management.md`

## Acceptance Criteria Verification

| AC | Description | Status |
|----|-------------|--------|
| AC-1 | PR creation records PR metadata and sets task status to review | ✅ VERIFIED — `agent-worker.ts` writes `PR_METADATA.json` and updates task to `"review"` |
| AC-2 | Merged PR closes task | ✅ VERIFIED — `refinery.ts` uses `"closed"` status (matches `mapRunStatusToNativeTaskStatus`) |
| AC-3 | Finalize fallback and create-pr phase share status path | ✅ VERIFIED — Both use `onTaskPhaseChange` with `nativeTaskStatusForPhase("create-pr") = "review"` |
| AC-4 | Reconciliation handles stale tasks with merged PRs | ✅ VERIFIED — 7 new tests in `startup-sync.test.ts` cover stale finalize/review tasks |
| AC-5 | Tests cover all paths | ✅ VERIFIED — Tests cover PR-created, PR-merged, finalize fallback, create-pr phase, reconciliation |
| AC-6 | Docs updated | ✅ VERIFIED — PRD/TRD updated to use `"closed"` instead of `"merged"` |

## Technical Details

The critical bug fix ensures that in the finalize fallback PR creation path:
- The `runtimeTaskBackend` check and the `runtimeTaskClient.update()` call now use the same client instance
- Previously, `runtimeTaskClient` was shadowed by a locally created client, while `runtimeTaskBackend` still referred to the outer scope
- This inconsistency could cause the status update to use the wrong backend client in edge cases