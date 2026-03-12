# Explorer Report: 4-tier merge conflict resolution

## Summary
The Foreman merge system has a 4-tier architecture for handling merge conflicts when integrating agent-completed worktree branches:

1. **Tier 1 — Merge Attempt**: Low-level git merge detection in `mergeWorktree()`
2. **Tier 2 — Conflict Handling**: Refinery orchestration in `mergeCompleted()` with conflict categorization
3. **Tier 3 — Conflict Resolution**: `resolveConflict()` method with merge strategies
4. **Tier 4 — CLI Interface**: User-facing merge command with conflict resolution options

This report documents the current state and identifies what needs implementation.

## Relevant Files

### 1. **src/lib/git.ts** (lines 174-200)
- **Purpose**: Low-level git operations including merge and conflict detection
- **Key Function**: `mergeWorktree(repoPath, branchName, targetBranch?)`
  - Attempts `git merge --no-ff <branch>`
  - Catches merge failure and extracts conflicting files using `git diff --name-only --diff-filter=U`
  - Returns `{ success: boolean, conflicts?: string[] }`
- **Current State**: Tier 1 implementation is complete
- **Relevance**: Foundation for conflict detection

### 2. **src/orchestrator/refinery.ts** (lines 130-249)
- **Purpose**: Orchestrates merge operations and handles results
- **Key Method 1**: `mergeCompleted(opts?)` (lines 134-249)
  - Calls `mergeWorktree()` for each completed run in dependency order
  - Handles 3 outcome categories:
    - **success + tests pass** → `status: "merged"` (Tier 2a)
    - **merge conflict** → `git merge --abort`, `status: "conflict"` (Tier 2b)
    - **tests fail** → `git reset --hard HEAD~1`, `status: "test-failed"` (Tier 2c)
  - Logs all outcomes to store
- **Key Method 2**: `resolveConflict(runId, strategy)` (lines 256-317)
  - Takes a conflict run and applies a resolution strategy
  - Supports two strategies:
    - `"theirs"` → `git merge --no-ff -X theirs` (Tier 3a — take agent's version)
    - `"abort"` → Mark run as `status: "failed"` (Tier 3b — give up)
  - Currently **NOT CALLED** from anywhere
- **Dependency Ordering**: Uses `orderByDependencies()` (lines 67-128) with Kahn's algorithm to topologically sort completed runs before merging
- **Current State**: Tiers 2-3 implementation is complete but Tier 3 unreachable from CLI
- **Relevance**: Core merge orchestration; resolveConflict() needs CLI wiring

### 3. **src/cli/commands/merge.ts** (lines 9-123)
- **Purpose**: CLI interface for merge operations
- **Current Options** (lines 11-15):
  - `--target-branch <branch>` — target branch for merge (default: "main")
  - `--no-tests` — skip test suite after merge
  - `--test-command <cmd>` — custom test command (default: "npm test")
  - `--seed <id>` — merge single seed by ID
  - `--list` — list completed seeds, don't merge
- **Current Behavior**:
  - Calls `refinery.mergeCompleted()` and categorizes results
  - Displays merged, conflicts, and test failures with file lists
  - **Line 93**: Help text references `foreman merge --resolve <runId> --strategy theirs|abort` — NOT IMPLEMENTED
- **Current State**: Tier 4 options `--resolve` and `--strategy` are missing
- **Relevance**: User-facing interface; needs implementation

### 4. **src/orchestrator/types.ts** (lines 113-151)
- **Purpose**: Type definitions for merge operations
- **Relevant Types**:
  - `MergedRun` (lines 115-119) — successful merge
  - `ConflictRun` (lines 121-126) — merge conflicts detected
  - `FailedRun` (lines 128-133) — other failures (test failures, unexpected errors)
  - `MergeReport` (lines 135-139) — aggregated results with three arrays
- **Current State**: All types defined
- **Relevance**: Data contract for merge reporting

### 5. **src/lib/store.ts** (line 25)
- **Purpose**: SQLite database layer
- **Current State**: Run status type includes `"conflict"` as a valid status value
  ```typescript
  status: "pending" | "running" | "completed" | "failed" | "stuck" | "merged" | "conflict" | "test-failed" | "pr-created"
  ```
- **Methods Using Conflict Status**:
  - `updateRun(runId, { status: "conflict" })` — set conflict status
  - `getRunsByStatus("conflict")` — retrieve conflicted runs
- **Relevance**: Data persistence for conflict state

### 6. **src/lib/__tests__/git.test.ts** (lines 88-130)
- **Purpose**: Tests for git operations including conflict detection
- **Test Coverage**:
  - `mergeWorktree merges clean changes` (lines 88-103) — Tier 1 success case
  - `mergeWorktree detects conflicts` (lines 105-130) — Tier 1 conflict case
    - Creates conflicting edits on two branches
    - Verifies `result.success === false`
    - Verifies `result.conflicts` contains conflicting files
    - Cleans up with `git merge --abort`
- **Current State**: Tier 1 conflict detection tested
- **Relevance**: Validates merge conflict detection

## Architecture & Patterns

### Merge Flow (Happy Path)
```
foreman merge
  └─ Refinery.mergeCompleted()
      ├─ getCompletedRuns() → fetch runs with status="completed"
      ├─ orderByDependencies() → topological sort by seed dependencies
      └─ for each run:
          ├─ mergeWorktree(repo, branch, target)
          │   └─ git merge --no-ff → { success, conflicts? }
          ├─ if success:
          │   ├─ runTestCommand(testCmd) if --no-tests not set
          │   ├─ if tests fail:
          │   │   ├─ git reset --hard HEAD~1 (revert merge)
          │   │   └─ updateRun(status="test-failed")
          │   ├─ if tests pass (or skipped):
          │   │   ├─ removeWorktree()
          │   │   └─ updateRun(status="merged")
          └─ if conflicts:
              ├─ git merge --abort (abort merge)
              └─ updateRun(status="conflict")
```

### Conflict Resolution Flow (Unimplemented — Tier 4)
Currently, users can't resolve conflicts from CLI. The intended flow would be:
```
foreman merge --resolve <runId> --strategy theirs
  └─ Refinery.resolveConflict(runId, "theirs")
      ├─ git merge branchName --no-ff -X theirs
      ├─ if success:
      │   ├─ removeWorktree()
      │   └─ updateRun(status="merged")
      └─ if failure:
          └─ updateRun(status="failed")
```

### Key Design Patterns

1. **Dependency Ordering** — Uses Kahn's algorithm (topological sort) to order runs so dependencies merge before dependents. This ensures parent beads merge before child beads, reducing cascading conflicts.

2. **Three-Tier Conflict Classification**:
   - **Tier 2b**: Merge conflicts (conflicting file content) → detectable by git
   - **Tier 2c**: Test failures (code integrates but tests fail) → detectable by test run
   - **Tier 2d**: Other failures (git errors, unexpected exceptions) → caught by try/catch

3. **Merge Abort on Conflict** — When conflicts detected, immediately abort merge with `git merge --abort` to leave repo in clean state. This allows the next merge attempt to start fresh.

4. **Worktree Cleanup** — Only removes worktree on successful merge (Tier 2a). On conflict/failure, leaves worktree intact for potential future resolution.

5. **Status Tracking** — Runs move through statuses:
   - `completed` → `merged` (success)
   - `completed` → `conflict` (merge conflict)
   - `completed` → `test-failed` (tests failed after merge)
   - `completed` → `failed` (other error)
   - `conflict` → `merged` (after resolveConflict + theirs)
   - `conflict` → `failed` (after resolveConflict + abort)

## Dependencies

### What Uses the Merge System

1. **merge.ts (CLI Command)**:
   - Imports `Refinery`, `ForemanStore`, `SeedsClient`, `getRepoRoot`
   - Calls `refinery.mergeCompleted()` and displays results
   - Needs to add: call to `refinery.resolveConflict()` when `--resolve` flag provided

2. **refinery.ts**:
   - Imports `mergeWorktree()` from git.ts
   - Imports `removeWorktree()` from git.ts
   - Uses `SeedsClient` to fetch dependency graph for `orderByDependencies()`
   - Uses `ForemanStore` to update run statuses and log events

3. **git.ts**:
   - No internal dependencies; uses only Node.js built-ins (`child_process`, `fs`, `path`)

4. **store.ts**:
   - Defines Run type with "conflict" status
   - Methods: `updateRun()`, `getRunsByStatus()`, `logEvent()`

### What Depends on Merge System

- **merge.ts** — Only user-facing code that directly uses merge system

## Existing Tests

### Complete Test Coverage

1. **src/lib/__tests__/git.test.ts**
   - ✅ `mergeWorktree merges clean changes` — Tier 1 success
   - ✅ `mergeWorktree detects conflicts` — Tier 1 conflict detection
   - Coverage: Merge detection only; no Tier 2/3/4 tests

2. **No existing tests for**:
   - ❌ `mergeCompleted()` function (Tier 2)
   - ❌ `resolveConflict()` function (Tier 3)
   - ❌ Merge command with conflict handling (Tier 4)
   - ❌ Test failure reverting (Tier 2c)
   - ❌ Dependency ordering logic (Tier 2 prerequisite)

## Recommended Approach

### Phase 1: Wire Tier 4 CLI Options (Highest Priority)
1. Add `--resolve <runId>` option to merge command
2. Add `--strategy <strategy>` option (validate: "theirs" | "abort")
3. When both provided:
   - Call `refinery.resolveConflict(runId, strategy)`
   - Display result (success/failure) with new status
4. Add validation error if `--resolve` provided without `--strategy`
5. Add test: CLI calls `resolveConflict()` with correct arguments

### Phase 2: Add Comprehensive Tests (Medium Priority)
1. **refinery.test.ts** — Test `mergeCompleted()` with all outcome paths:
   - Clean merge + tests pass → status: "merged"
   - Merge conflict → status: "conflict" + merge aborted
   - Clean merge + test failure → status: "test-failed" + merge reverted
   - Other error → status: "failed"

2. **refinery.test.ts** — Test `resolveConflict()`:
   - Resolve with "theirs" → status: "merged" on success
   - Resolve with "theirs" → status: "failed" on second conflict
   - Resolve with "abort" → status: "failed"

3. **merge.test.ts** — Test CLI:
   - `--resolve <id> --strategy theirs` → calls resolveConflict
   - Error if missing `--strategy`
   - Error if invalid `--strategy` value

4. **git.test.ts** — Already covered; no additions needed

### Phase 3: Error Handling & Edge Cases (Lower Priority)
1. Handle resolve on non-"conflict" runs (e.g., already merged)
2. Handle resolve on missing run
3. Handle `git merge --abort` failure (merge not in progress)
4. Handle `git merge -X theirs` creating new conflicts
5. Clarify behavior when conflict run has missing worktree

## Potential Pitfalls & Edge Cases

1. **Conflict Run Without Worktree**
   - If worktree deleted before `resolveConflict()` called, git merge will fail
   - Solution: Verify worktree exists before attempting merge

2. **Multiple Conflicts in Sequence**
   - User resolves conflict A with "theirs"
   - New conflict B appears on same branch
   - Current code doesn't handle re-detection after re-merge
   - Solution: Verify git merge succeeds; if conflict found, mark as "failed"

3. **Test Suite Running on Conflicted Merges**
   - `mergeCompleted()` runs tests on merged code
   - But `resolveConflict()` does NOT run tests after "theirs" merge
   - Inconsistency: main merge path runs tests; conflict resolution doesn't
   - Solution: Either (a) add `runTests` param to `resolveConflict()`, or (b) document that "theirs" merge skips tests

4. **Dependency Ordering Assumptions**
   - `orderByDependencies()` assumes dependency graph is consistent
   - If seed A depends on seed B, but B has failed (not in completed list), A may be unblocked prematurely
   - Solution: Not an issue for merge (only runs on completed); but consider for future cross-phase merges

5. **Merge Strategy Clarity**
   - `-X theirs` means "in conflicts, take their version" (the branch being merged in)
   - Terminology may be confusing: "their" = the agent's work, "ours" = main branch
   - Solution: Add clarifying comment in code + help text: "Use agent's version of conflicting files"

6. **Status Transition Completeness**
   - Current code tracks transitions: completed → merged | conflict | test-failed | failed
   - But doesn't track: conflict → merged (via resolveConflict)
   - Solution: Add test to verify this transition

## Key Implementation Points

1. **Merge command needs to support two modes**:
   - Normal mode: `foreman merge` → calls `mergeCompleted()`
   - Resolve mode: `foreman merge --resolve <id> --strategy <strat>` → calls `resolveConflict()`
   - These are mutually exclusive

2. **Strategy validation**:
   - Allow only "theirs" and "abort" for now
   - Consider future strategies: "ours" (take main), "manual" (prompt user), "squash"

3. **Result reporting**:
   - For resolve mode, report single result (success/failure) not array
   - Show new run status after resolution
   - Show branch name for clarity

4. **Worktree management**:
   - `removeWorktree()` should only be called on success
   - On `resolveConflict()` success, worktree should be removed (like normal merge)
   - Already implemented in refinery line 284-290

5. **Database updates**:
   - `updateRun()` with new status
   - `logEvent()` with resolution details
   - Both already done in refinery.ts

## Next Steps for Developer

1. **Add CLI options** to merge command (--resolve, --strategy)
2. **Wire resolveConflict()** call from merge command
3. **Add validation** for option combinations
4. **Add basic tests** for CLI option handling
5. **Add integration tests** for resolveConflict() end-to-end
6. **Verify test running behavior** (should tests run after "theirs" merge?)
7. **Add documentation** for merge --resolve usage in CLI help text
8. **Consider telemetry** — log conflict resolutions for observability
