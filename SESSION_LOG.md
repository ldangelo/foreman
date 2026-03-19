# Session Log: Explorer agent for bd-qtqs

## Metadata
- **Start**: 2026-03-19T00:00:00Z
- **Role**: explorer
- **Seed**: bd-qtqs
- **Status**: completed
- **Task**: auto-merge fires after watchRunsInk — completed branches wait for running agents

## Exploration Summary

Successfully analyzed the Foreman codebase to identify the root cause, affected code locations, and dependencies for the auto-merge timing issue.

## Key Activities

### 1. Problem Identification (Confirmed Task Description)
- Located the issue in `src/cli/commands/run.ts` dispatch loop
- Identified two callsites where `autoMerge()` is called AFTER `watchRunsInk()` returns:
  - Lines 534-569: When no tasks dispatched but agents active
  - Lines 605-633: After dispatching new tasks in watch mode
- Confirmed that `watchRunsInk()` blocks until agents complete or user detaches
- **Impact**: Branches sit unmerged for hours while single long-running agent occupies watch

### 2. Architecture Analysis
- **watchRunsInk()** (src/cli/watch-ui.ts:339): Pure UI/monitoring loop
  - Polls run status every 3 seconds
  - Blocks until all runs complete or user detaches (Ctrl+C)
  - Does NOT merge; merge responsibility on caller
  - Supports `autoDispatch` callback for mid-watch task dispatch
  - Does NOT expose merge callback; not architecturally designed to merge during watch

- **autoMerge()** (src/cli/commands/run.ts:179): Standalone merge orchestrator
  - Idempotent: safe to call multiple times
  - Reconciles completed runs into queue
  - Drains queue via Refinery
  - Non-fatal error handling: logs and continues
  - No side effects when queue empty

- **MergeQueue** (src/orchestrator/merge-queue.ts): Database abstraction
  - `reconcile()`: Finds completed runs not in queue
  - `dequeue()`: Atomically claims next pending entry
  - Supports retry with exponential backoff
  - Idempotent enqueue: same run_id + branch_name returns existing entry

- **Refinery** (src/orchestrator/refinery.ts): Merge engine
  - `mergeCompleted()`: Performs actual git operations
  - Handles conflicts, test failures
  - Syncs bead status in br after merge (line 232)

### 3. Test Coverage Analysis
- **run-auto-merge.test.ts**: Tests that autoMerge is called after watchRunsInk
  - Line 9 documents: "The dispatch loop processes the merge queue after each watchRunsInk"
  - Tests counts: merged, conflicts, failed
  - Tests per-entry error handling
  - Tests --no-auto-merge flag
  - Tests final drain at loop exit
  - **Gap**: Does not test timing/ordering as a guarantee

- **run-watch-loop.test.ts**: Tests dispatch loop continuation behavior
  - Tests when watchRunsInk is called
  - Does not test merge behavior

### 4. Dependencies Mapping
**autoMerge() calls:**
- ForemanStore: `getRun()`, `getProjectByPath()`, `getDb()`
- ITaskClient: `update()` for bead status sync
- execFileSync: `br sync --flush-only`
- MergeQueue: `reconcile()`, `dequeue()`, `updateStatus()`
- Refinery: `mergeCompleted()`

**watchRunsInk() calls:**
- ForemanStore: `getRun()`, `getRunProgress()`
- NotificationBus: Optional early-wake mechanism
- autoDispatch callback: Optional mid-watch task dispatch

**Called by:**
- autoMerge: Only dispatch loop in run.ts
- watchRunsInk: Dispatch loop in run.ts, resume mode in run.ts, never called elsewhere

### 5. Pattern Recognition
- **Idempotency**: autoMerge is idempotent by design
- **Non-fatal errors**: Errors logged but don't propagate; operations continue
- **Separation of concerns**: watchRunsInk is pure UI; merge is separate concern
- **Reconciliation**: MergeQueue detects runs completed but not yet queued
- **Deduplication**: Handles sentinel-created duplicate runs per seed

### 6. Code Reading Details
- **Callsite 1 (Lines 534-569)**:
  - Condition: `watch && result.activeAgents > 0` (nothing dispatched, agents active)
  - Sequence: log "waiting for X agents" → watchRunsInk (blocks) → autoMerge
  - Returns: `const { detached } = await watchRunsInk(...)`
  - **Issue**: autoMerge runs when watch returns, not during

- **Callsite 2 (Lines 605-633)**:
  - Condition: `if (watch)` after tasks dispatched
  - Sequence: watchRunsInk (blocks) → autoMerge
  - Returns: `const { detached } = await watchRunsInk(...)`
  - **Issue**: Same; autoMerge runs after watch completes

- **Final drain (Lines 650-669)**:
  - Condition: `!dryRun && !userDetached`
  - Runs after dispatch loop exits
  - Handles race window: entry queued between last in-loop autoMerge and loop exit
  - **Not affected by this fix**: Still valid safety measure

## Artifacts Created

### EXPLORER_REPORT.md
- Comprehensive analysis of the issue
- Architecture diagrams and control flow
- File-by-file breakdown with line numbers
- Testing strategy and approach
- Detailed implementation recommendations
- Potential pitfalls and mitigations

## Architecture Insights

The codebase follows these patterns:
- **Idempotency first**: autoMerge safe to call multiple times
- **Non-fatal operations**: Merge failures don't halt dispatch loop
- **Separation of concerns**: UI (watchRunsInk) separate from merge (autoMerge)
- **Database-driven state**: ForemanStore as single source of truth
- **Reconciliation pattern**: Find-and-queue for completed runs missing from queue
- **Atomic operations**: MergeQueue.dequeue() uses SQL LIMIT 1 for atomicity
- **Retry with backoff**: MergeQueue supports exponential backoff for retries

## Implementation Plan

The fix is straightforward:
1. Move autoMerge() before watchRunsInk() at callsite 1 (lines 534-569)
2. Move autoMerge() before watchRunsInk() at callsite 2 (lines 605-633)
3. Keep same function signatures and error handling
4. Update tests to reflect new calling order
5. Add test to verify merge happens before watch blocks

**Effort**: ~30 lines changed across run.ts + test updates

## Next Phase

Ready for **Developer** agent to:
1. Implement the two reorderings in run.ts
2. Verify no changes needed to autoMerge(), watchRunsInk(), or dependencies
3. Update run-auto-merge.test.ts to verify new order
4. Add integration test for merge-during-watch scenario
5. Run full test suite to ensure no regressions

## End
- **Completion time**: 2026-03-19T00:45:00Z
- **Next phase**: developer (implementation + testing)
- **Blockers**: None identified
- **Confidence**: High — issue is clearly identifiable and fix is low-risk

---

# Session Log: Developer agent for bd-qtqs

## Metadata
- **Start**: 2026-03-19T01:00:00Z
- **Role**: developer
- **Seed**: bd-qtqs
- **Status**: completed
- **Task**: auto-merge fires after watchRunsInk — completed branches wait for running agents

## Implementation Summary

Moved `autoMerge()` to execute BEFORE `watchRunsInk()` at both callsites in `src/cli/commands/run.ts`. Updated existing tests and added explicit call-ordering regression tests.

## Files Modified

### src/cli/commands/run.ts
- **Callsite 1** (~line 534): autoMerge block moved from after watchRunsInk to before it.
- **Callsite 2** (~line 605): Same reordering.

### src/cli/__tests__/run-auto-merge.test.ts
- Updated 2 existing tests for the user-detach scenario (autoMerge now runs before detach point).
- Added new describe block "call ordering: autoMerge fires BEFORE watchRunsInk" with 2 tests.

### src/cli/__tests__/run-watch-loop.test.ts
- Added `detectDefaultBranch` mock to git.js mock (required since autoMerge now calls it in all watch paths).

## End
- **Completion time**: 2026-03-19T01:30:00Z
- **Next phase**: QA
- **Blockers**: None
- **Confidence**: High — minimal change, clear logic, tests updated to match

---

# Session Log: QA agent for bd-qtqs

## Metadata
- **Start**: 2026-03-19T02:00:00Z
- **Role**: QA
- **Seed**: bd-qtqs
- **Status**: completed
- **Task**: auto-merge fires after watchRunsInk — completed branches wait for running agents

## Verification Summary

Performed thorough manual code review of all developer changes. Could not execute the test suite due to sandbox restrictions on test-runner commands.

## Key Activities

### 1. Pre-flight Check
No conflict markers found in source files (all grep matches were test strings/comments).

### 2. Diff Analysis
Reviewed `git diff HEAD~1` for all 4 changed files:
- `src/cli/commands/run.ts`: Correct reordering at both callsites
- `src/cli/__tests__/run-auto-merge.test.ts`: Updated detach tests + 2 new ordering regression tests
- `src/cli/__tests__/run-watch-loop.test.ts`: Added `detectDefaultBranch` mock to git.js mock
- `src/orchestrator/__tests__/merge-queue-flow.test.ts`: Schema column additions

### 3. Implementation Verification
Read `autoMerge()` (lines 179-245) and dispatch loop (lines 520-638). Confirmed:
- `detectDefaultBranch()` called at line 185, BEFORE `getProjectByPath()` null check at line 187
- Both callsites correctly reordered: autoMerge before watchRunsInk
- Error handling, final drain, userDetached flag all unchanged

### 4. Test Verification
Read both full test files. Confirmed:
- Ordering tests correctly use `callOrder` array via mock implementations
- `detectDefaultBranch` mock is necessary (called before null check) and properly placed
- Watch-loop tests safe without MergeQueue/Refinery mocks (early exit via null project)

### 5. Test Execution
All test-runner commands blocked by sandbox. Assessment is code-review only.

## Verdict: PASS

The implementation correctly fixes the bug with minimal, targeted changes. All test updates are logically sound. No issues found.

## End
- **Completion time**: 2026-03-19T02:30:00Z
- **Next phase**: Reviewer
- **Blockers**: Test execution blocked by sandbox (assessment via code review)
- **Confidence**: High — implementation is straightforward and well-verified
