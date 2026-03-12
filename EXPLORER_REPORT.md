# Explorer Report: Add pre-commit bug scanning to finalize phase

## Task Overview

Add pre-commit bug scanning to the finalize phase of the agent pipeline. The finalize phase is the final step where git operations (add, commit, push) and seed closure occur. Bug scanning should validate the code before committing to catch compilation errors, type errors, and other defects early.

## Relevant Files

### Primary File to Modify

- **src/orchestrator/agent-worker.ts** — Contains the `finalize()` function (lines 429-493) that handles git operations. This is where bug scanning checks will be added **before** the commit step (before line 441).

### Related Files (Reference/Documentation Only)

- **src/orchestrator/lead-prompt.ts** — Documents the finalize process in team instructions (lines 182-187). Shows that finalize performs git add, commit, push, and seed close. Pipeline description at lines 518 and 643.
- **src/orchestrator/__tests__/agent-worker-team.test.ts** — Contains test patterns for agent-worker phases. Test at line 193: `"generated prompt includes finalize steps (commit, push, close)"` would need updating.
- **src/orchestrator/__tests__/lead-prompt.test.ts** — Contains test at line 37: `"includes finalize steps (commit, push, close)"` would need updating.
- **src/lib/store.ts** — Defines `currentPhase` field in `RunProgress` type; tracks "finalize" as a pipeline phase.
- **package.json** — Contains `"build": "tsc"` (line 11) which is the primary bug scanning tool to use.

## Architecture & Patterns

### Current Finalize Function Flow

The `finalize()` function (lines 429-493 in agent-worker.ts) follows this sequence:

```
1. Initialize report array with seed info and timestamp
2. TRY: git add -A, git commit, git rev-parse HEAD
       CATCH: "nothing to commit" special case, other commit errors
3. TRY: git push -u origin foreman/{seedId}
       CATCH: log and continue on error
4. TRY: sd close {seedId} --reason "Completed via pipeline"
       CATCH: log and continue on error
5. Write FINALIZE_REPORT.md to disk
6. Return
```

**Proposed addition**: Insert bug scanning BEFORE step 2 (commit).

### Error Handling Pattern

The finalize function uses **try-catch blocks per operation** with these characteristics:

- Each step is independent (catch blocks don't prevent next step)
- Errors are logged to both: in-memory `report` array AND the `logFile`
- Success/failure status recorded in report sections: `## Commit`, `## Push`, `## Seed Close`
- Error messages truncated to 300-500 chars for report, 200 chars for logging
- Non-fatal errors don't throw — they record and continue (pattern: log → report → continue)
- Special case handling: "nothing to commit" is caught separately and not treated as an error

### Command Execution Pattern

Uses `execFileSync()` for shell commands (preferred over shell strings for safety):

```typescript
execFileSync("git", ["add", "-A"], opts)
execFileSync("git", ["commit", "-m", msg], opts)
execFileSync("git", ["push", "-u", "origin", branch], opts)
```

Options object used throughout:
```typescript
const opts = { cwd: worktreePath, stdio: "pipe" as const, timeout: 30_000 };
```

### Imports Already Available

All necessary imports are already present in agent-worker.ts:
- `execFileSync` from `node:child_process` (line 15) ✓
- `appendFile` from `node:fs/promises` (line 13) ✓
- `join` from `node:path` (line 14) ✓
- Error handling patterns already established ✓

### Bug Scanning Tool Available

From package.json (lines 10-15):
```json
"scripts": {
  "build": "tsc",
  "dev": "tsx watch src/cli/index.ts",
  "start": "node dist/cli/index.js",
  "test": "vitest run",
  "test:watch": "vitest"
}
```

**Available option**: `npm run build` — TypeScript compilation via tsc

This catches:
- Type errors
- Syntax errors
- Missing imports
- Assignment type mismatches
- Other static analysis issues

**Alternative**: `tsc --noEmit` (non-destructive type check without generating dist/ files)

## Dependencies

### What This Feature Depends On

- `execFileSync` from `node:child_process` ✓
- NPM/tsc available in the worktree environment
- Existing error handling patterns ✓
- Existing report generation patterns ✓

### Who Depends on This

- **src/orchestrator/agent-worker.ts:runPipeline()** — calls `finalize()` at line 632
- **src/orchestrator/dispatcher.ts** — spawns agent-worker.ts as subprocess
- CLI commands that trigger pipeline (run.ts, etc.)

## Existing Tests

### Test Files That Reference Finalize

- **src/orchestrator/__tests__/agent-worker-team.test.ts** (line 193)
  - Test: `"generated prompt includes finalize steps (commit, push, close)"`
  - Current expectation: checks for "git commit", "git push", "sd close"
  - **Needs update**: Add expectation for bug scanning step (e.g., "build" or "type check")

- **src/orchestrator/__tests__/lead-prompt.test.ts** (line 37)
  - Test: `"includes finalize steps (commit, push, close)"`
  - Current expectation: checks for "git commit", "git push", "sd close"
  - **Needs update**: Add expectation for bug scanning step

### No Direct Unit Tests for `finalize()` Function

The `finalize()` function itself is not directly unit tested. It's integration-tested through the pipeline tests. This is acceptable since it's a straightforward shell command orchestrator.

## Recommended Approach

### Step-by-Step Implementation Plan

1. **Add bug scanning section in `finalize()` function** (agent-worker.ts)
   - Insert new try-catch block after report initialization (after line 439, before commit section at line 441)
   - Execute: `execFileSync("npm", ["run", "build"], opts)` with the existing `opts` object
   - Wrap in try-catch following existing error handling pattern
   - Catch errors (type check failures) and add status to report under new `## Build / Type Check` section
   - Non-blocking: report status but continue to commit regardless (following existing pattern)

2. **Update report structure**
   - Add `## Build` or `## Type Check` section before `## Commit` section
   - Status: SUCCESS | FAILED | SKIPPED
   - Include error output snippet (first few lines) for debugging

3. **Update lead prompt instructions** (lead-prompt.ts, lines 182-187)
   - Update Finalize section to mention that bug scanning occurs before commit
   - Helps document the new behavior for users

4. **Update tests**
   - agent-worker-team.test.ts line 193: Add expectation for build/type-check step
   - lead-prompt.test.ts line 37: Add expectation for build/type-check mention

### File Changes Summary

| File | Change Type | Details |
|------|-------------|---------|
| src/orchestrator/agent-worker.ts | Add try-catch | Insert bug scanning before commit (new lines ~440-460) |
| src/orchestrator/lead-prompt.ts | Update docs | Lines 182-187 (add mention of build/type-check) |
| src/orchestrator/__tests__/agent-worker-team.test.ts | Update test expectations | Line 193 (add expectation for build step) |
| src/orchestrator/__tests__/lead-prompt.test.ts | Update test expectations | Line 37 (add expectation for build/type-check) |

## Potential Pitfalls & Edge Cases

1. **Performance**: `npm run build` can be slow on large TypeScript projects
   - Current timeout: 30 seconds — should be sufficient for most builds
   - Mitigation: Could skip if no files changed (detect via `git diff --name-only`)
   - Status: Accept as-is initially; can optimize later if needed

2. **Tool Availability**: What if npm/tsc not in PATH in worktree?
   - Existing pattern: Line 475 in agent-worker.ts shows how to use full paths
   - Solution: Use `join(process.cwd(), "node_modules", ".bin", "npm")` or similar
   - Or: Execute from worktree directory where `npm` is available

3. **Type Check vs. Build**:
   - `tsc --noEmit`: Fast, type checking only, no dist output
   - `npm run build`: Builds full project, generates artifacts to disk (may be OK)
   - Recommendation: Use `npm run build` for now (matches project conventions)

4. **Failing Type Checks — Should They Block?**
   - Current pattern in finalize: Non-fatal errors (report but continue)
   - Recommendation: Follow existing pattern (non-blocking)
   - Rationale: Downstream QA/review phases already validate code; this is a safety check
   - Developer would see failure in FINALIZE_REPORT.md and can address in next iteration

5. **Pre-existing Type Errors**:
   - Bug scan might fail on code that was already broken
   - This is expected behavior — the feature is to catch issues
   - Report will clearly show what failed, allowing developer/reviewer to assess if it's pre-existing

6. **Empty Changes**:
   - Already handled by "nothing to commit" check (line 451)
   - Bug scan could be skipped in this case (optimization, not required)

## Implementation Notes

### Code Style & Conventions to Follow

- Use `execFileSync` with array args (never shell string concatenation)
- Use `opts` object with timeout, stdio, cwd defined at function start
- Wrap errors with context: `err instanceof Error ? err.message : String(err)`
- Truncate long errors: `.slice(0, 300)` for report, `.slice(0, 200)` for logging
- Log every step: `log("[FINALIZE] <message>")`
- Add every step to report: `report.push()`
- Use markdown headers in report: `## Build` or `## Type Check`

### Success Criteria

✅ Pre-commit bug scanning runs **before** `git add -A`
✅ Results reported in FINALIZE_REPORT.md with clear status
✅ Errors don't block finalization (non-fatal pattern consistent with push/close)
✅ Both console logging and report recording implemented
✅ Tests updated to reflect new finalize step
✅ Handles missing tools gracefully (doesn't crash)
✅ Performance acceptable (existing 30s timeout sufficient)
