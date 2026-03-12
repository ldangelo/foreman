# Explorer Report: 4-tier merge conflict resolution

## Summary
The codebase currently has basic merge conflict detection and two manual resolution strategies (theirs/abort). This task implements a **4-tier escalating conflict resolution system** that automatically attempts increasingly aggressive strategies before requiring human intervention.

## Current State: 2-Strategy System
- **Tier 1 (Manual): Abort** — abandon merge, mark run as failed
- **Tier 2 (Manual): Theirs** — retry with `-X theirs` strategy, accept agent's changes

The system relies on user intervention via `foreman merge --resolve <runId> --strategy <strategy>`.

## Inferred 4-Tier Architecture
Based on git merge best practices and the codebase patterns:

1. **Tier 1: Automatic (recursive)** — Default git merge, may auto-resolve simple conflicts
2. **Tier 2: Ours strategy** — Accept main branch changes, discard agent changes
3. **Tier 3: Theirs strategy** — Accept agent changes, overwrite main branch changes
4. **Tier 4: Manual/Escalation** — Flag for human review, create PR, or abort

## Relevant Files

### 1. **src/lib/git.ts** (lines 174-200)
- **Purpose**: Git operation wrapper functions, including merge command
- **Current State**:
  - `mergeWorktree()` attempts a single `git merge` with `--no-ff`
  - Detects conflicts by catching git error and parsing `git diff --name-only --diff-filter=U`
  - Returns `{ success: boolean; conflicts?: string[] }`
  - No strategy parameter or retry mechanism
- **Relevance**: Core location where merge strategies must be implemented

### 2. **src/orchestrator/refinery.ts** (lines 56-169, 176-237)
- **Purpose**: Main orchestration for merging completed runs and managing the merge lifecycle
- **Key Methods**:
  - `mergeCompleted()` (56-169): Iterates completed runs, calls `mergeWorktree()`, detects conflicts, handles test failures
  - `resolveConflict()` (176-237): Currently handles "theirs" and "abort" strategies only
- **Current Flow**:
  1. Attempt merge
  2. If conflict: abort merge, log event, add to `conflicts[]` report
  3. If successful: optionally run tests
  4. Manual user intervention needed to call `resolveConflict()`
- **Relevance**: Main method that orchestrates merge attempts; must integrate 4-tier strategy

### 3. **src/cli/commands/merge.ts** (lines 9-81)
- **Purpose**: CLI entry point for merge command
- **Current State**:
  - Takes `--target-branch`, `--no-tests`, `--test-command` options
  - Calls `refinery.mergeCompleted()` to generate report
  - Displays results: merged, conflicts, test failures
  - Line 56: Suggests manual resolution with `--resolve` flag (currently only supports "theirs|abort")
- **Relevance**: CLI interface that will need to display which tier resolved the conflict (or if escalation needed)

### 4. **src/orchestrator/types.ts** (lines 112-136)
- **Purpose**: Type definitions for refinery operations
- **Current State**:
  - `ConflictRun` captures conflicting files and basic metadata
  - No tier information or resolution metadata
- **Relevance**: Must extend types to track which tier resolved conflicts

### 5. **src/lib/__tests__/git.test.ts** (lines 105-130)
- **Purpose**: Tests for git operations including merge
- **Current Tests**:
  - `mergeWorktree detects conflicts` — verifies conflict detection works
  - Creates conflict scenario and validates `result.conflicts` array
- **Relevance**: Provides test patterns for implementing multi-strategy merge tests

## Architecture & Patterns

### Current Merge Pattern
```typescript
// Current single-attempt merge
const result = await mergeWorktree(repoPath, branchName, targetBranch);
if (!result.success) {
  // Conflict detected - requires manual intervention
  conflicts.push({ beadId, conflictFiles: result.conflicts });
}
```

### Proposed 4-Tier Pattern
```typescript
// New multi-tier merge with automatic escalation
const result = await mergeWorktreeWithTiers(repoPath, branchName, targetBranch);
// Returns: { success, tier?, conflicts?, strategy? }
// tier: 1 | 2 | 3 | 4
// strategy: 'recursive' | 'ours' | 'theirs' | 'manual'
```

### Git Merge Strategy Mapping
- **Tier 1 (Automatic recursive)**: `git merge <branch> --no-ff` (default, recursive strategy)
- **Tier 2 (Ours)**: `git merge <branch> --no-ff -X ours`
- **Tier 3 (Theirs)**: `git merge <branch> --no-ff -X theirs`
- **Tier 4 (Manual)**: Create PR or flag for human review

### Error Handling Pattern (existing)
```typescript
try {
  const { stdout } = await execFileAsync("git", args, { cwd });
  return stdout.trim();
} catch (err: any) {
  // Parse error message for CONFLICT/merge failure
  // Return structured error response
}
```

## Dependencies

### What Uses mergeWorktree()
1. **refinery.ts** — `mergeCompleted()` function (line 76)
   - Primary caller, orchestrates merge workflow
   - Must be updated to handle tier-based results

2. **refinery.ts** — `resolveConflict()` function (line 202)
   - Currently hardcoded `-X theirs` for conflict resolution
   - Will become obsolete with automatic tier system

### What Uses resolveConflict()
1. **merge.ts** — CLI command indirectly (user must call `foreman merge --resolve` separately)
   - Not directly called from CLI, invoked via separate flow

### Module Exports
- `git.ts` exports: `mergeWorktree`, `mergeWorktree` must support strategy parameter
- `refinery.ts` exports: Refinery class with `mergeCompleted()` and `resolveConflict()`
- `merge.ts` CLI command references `refinery.mergeCompleted()`

## Existing Tests

### Test Files
1. **src/lib/__tests__/git.test.ts**
   - Tests: createWorktree, removeWorktree, listWorktrees, mergeWorktree
   - Key test: `mergeWorktree detects conflicts` (lines 105-130)
   - Creates real git scenario with conflicting edits to README.md
   - **Impact**: Provides pattern for testing merge strategies; will need 4 new tests for each tier

2. **src/orchestrator/__tests__/refinery.test.ts**
   - No file found; unclear if refinery has tests
   - **Impact**: May need to create test coverage for new tier-based merge workflow

### Test Patterns
- Uses `mkdtempSync()` to create temporary git repos
- Initializes repos with `git init`, sets config, commits initial content
- Creates conflicts by editing same file from different branches
- Validates success/failure and conflict file detection

## Recommended Approach

### Phase 1: Extend git.ts mergeWorktree() to Support Strategies
1. Add `strategy?: 'recursive' | 'ours' | 'theirs'` parameter to `mergeWorktree()`
2. Modify git command to include `-X <strategy>` flag based on parameter
3. Update return type to include resolved strategy and tier info:
   ```typescript
   interface MergeResultEx {
     success: boolean;
     tier?: number;           // 1, 2, 3, or 4
     strategy?: string;       // which strategy worked
     conflicts?: string[];
   }
   ```

### Phase 2: Implement 4-Tier Logic in refinery.ts
1. Create new `mergeWorktreeWithTiers()` helper in refinery.ts that:
   - Tier 1: Attempt default recursive merge (no strategy flag)
   - If fails → Tier 2: Attempt with `-X ours`
   - If fails → Tier 3: Attempt with `-X theirs`
   - If fails → Tier 4: Flag for manual/PR creation
2. Update `mergeCompleted()` to use new tier-based approach
3. Return tier information in merge report

### Phase 3: Update Types and CLI
1. Extend `ConflictRun` type to include:
   - `resolvedTier?: number`
   - `resolvedStrategy?: string`
   - `requiresManualReview: boolean`
2. Update CLI output to show which tier resolved conflicts
3. Remove or deprecate `resolveConflict()` method (no longer needed)
4. Update merge command help text to explain automatic tier resolution

### Phase 4: Add Comprehensive Tests
1. Add test cases in git.test.ts for each merge strategy:
   - `mergeWorktree with ours strategy`
   - `mergeWorktree with theirs strategy`
   - `mergeWorktree falls back through tiers`
2. Test tier escalation scenario:
   - Create conflict that only theirs can resolve
   - Verify tier 1 fails, tier 3 succeeds

### Phase 5: Enhance Conflict Resolution Logic (Future)
Optional: Tier 4 could be smarter:
- **4a (PR-based)**: Create a PR for human review instead of aborting
- **4b (LLM-assisted)**: Spawn a resolver agent to analyze and merge conflicts
- **4c (Manual flag)**: Simply mark run as `conflict` and require `foreman merge --resolve`

## File Modification Summary

| File | Changes | Reason |
|------|---------|--------|
| src/lib/git.ts | Add strategy param to mergeWorktree(), implement tier logic | Core merge implementation |
| src/orchestrator/refinery.ts | Update mergeCompleted() to use tier system, deprecate resolveConflict() | Orchestration logic |
| src/orchestrator/types.ts | Extend ConflictRun, add MergeResultEx | Type safety |
| src/cli/commands/merge.ts | Update help text, adjust output display | User-facing changes |
| src/lib/__tests__/git.test.ts | Add tier-based merge tests | Test coverage |

## Potential Pitfalls & Edge Cases

1. **Merge Abort State** — After failed merge, git is in conflict state
   - Current code calls `git merge --abort` to clean up
   - Must ensure state is clean before attempting next tier

2. **Strategy Effectiveness** — `-X ours` vs `-X theirs` may both fail if:
   - Conflicts are in the same file at structural level
   - Git's merge driver can't automatically resolve even with strategy
   - Solution: Must still check for remaining conflicts after each tier

3. **Test Suite Interaction** — Phase 3 runs tests after merge
   - If tier 2 or 3 succeeds but tests fail, merge is reverted
   - Tier-based approach means we might pass tests that would fail with tier 1
   - Consider: should we re-test with different strategy if tests fail?

4. **Backwards Compatibility** — `resolveConflict()` is currently the resolution mechanism
   - Users may have scripts or workflows calling `foreman merge --resolve`
   - Decision: Keep method but mark deprecated, or remove entirely?

5. **Conflict File Tracking** — Current code detects conflicts via:
   ```bash
   git diff --name-only --diff-filter=U
   ```
   - This works for detecting initial conflicts
   - After strategy attempt, must re-run to verify conflicts still exist

6. **Performance** — Retrying merges multiple times could be slow
   - Each failed merge requires `git merge --abort`
   - Each new attempt requires new merge operation
   - Acceptable for small projects; monitor for large repos

## Next Steps for Developer

1. Understand git merge `-X` strategy options thoroughly (`man git-merge`)
2. Design the tier escalation logic with clear decision boundaries
3. Implement `mergeWorktree()` strategy parameter in git.ts
4. Add tier-based merge helper in refinery.ts
5. Update types to track resolution tier
6. Add comprehensive tests for each tier
7. Update CLI output to show tier information
8. Consider whether tier 4 should be PR-based or agent-based resolution
9. Test with real-world conflict scenarios (complex file merges)
10. Monitor performance impact of multi-attempt merge strategy
