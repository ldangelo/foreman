# Explorer Report: Add pre-commit bug scanning to finalize phase

## Task Overview
Add pre-commit bug scanning to the finalize phase of the agent pipeline. The finalize phase is the final step where git operations (add, commit, push) and seed closure occur. Bug scanning should validate the code before committing to catch compilation errors, type errors, and other defects early.

## Relevant Files

### Primary File to Modify
- **src/orchestrator/agent-worker.ts** — Contains the `finalize()` function (lines 429-493) that handles git operations. This is where bug scanning checks will be added **before** the commit step.

### Related Files (Reference Only)
- **src/orchestrator/lead-prompt.ts** — Documents the finalize process in instructions (line 182-187). Shows that finalize performs git add, commit, push, and seed close.
- **src/orchestrator/__tests__/agent-worker-team.test.ts** — Contains test patterns for agent-worker phases. Shows how finalize steps are tested (line 193).
- **src/lib/store.ts** — Defines `currentPhase` field in RunProgress type (line 74), tracks "finalize" as a phase.
- **src/orchestrator/roles.ts** — Defines role prompts and verdict parsing; reference for error handling patterns.
- **src/cli/commands/status.ts** — Uses finalize phase in status display (lines 122-125); shows how phases are tracked UI-side.

## Architecture & Patterns

### Current Finalize Function Flow
```
1. Prepare report array
2. TRY: git add -A, git commit, git rev-parse HEAD
       Catch exceptions: "nothing to commit" special case
3. TRY: git push -u origin foreman/{seedId}
       Catch and log errors
4. TRY: sd close {seedId}
       Catch and log errors
5. Write FINALIZE_REPORT.md
6. Return
```

### Error Handling Pattern
The function uses **try-catch blocks per operation** with these characteristics:
- Each step is independent (catch blocks don't prevent next step)
- Errors are logged to both: in-memory `report` array AND the `logFile`
- Success/failure status recorded in report sections: `## Commit`, `## Push`, `## Seed Close`
- Error messages truncated to 300-500 chars for report, 200 chars for logging
- Non-fatal errors don't throw — they record and continue

### Command Execution Pattern
Uses `execFileSync()` for shell commands (preferred over shell strings for safety):
- `execFileSync("git", ["add", "-A"], opts)`
- `execFileSync("git", ["commit", "-m", msg], opts)`
- `execFileSync("git", ["push", "-u", "origin", branch], opts)`
- Options object: `{ cwd: worktreePath, stdio: "pipe" as const, timeout: 30_000 }`

### Project's Bug Scanning Tools
Available checks in package.json (line 10-16):
- **`npm run build`** — TypeScript compilation via `tsc` (line 11)
- **`npm run test`** — Vitest runner (line 14) — already run in QA phase
- **`npm run typecheck`** — Would be ideal but not in current package.json

The best candidate: **`npm run build`** (tsc compilation) — catches:
- Type errors
- Syntax errors
- Missing imports
- Assignment type mismatches
- Other static analysis issues

Alternative: Run `tsc --noEmit` directly if faster feedback is preferred (non-destructive type check without generating dist/ files).

## Dependencies

### Imports Already Present in agent-worker.ts
- `execFileSync` from `node:child_process` (line 15) ✓
- `appendFile` from `node:fs/promises` (line 13) ✓
- `join` from `node:path` (line 14) ✓
- Error logging patterns ✓

### No New Dependencies Required
The finalize function already has all needed imports. Bug scanning command will be:
- A new `execFileSync()` call wrapped in try-catch
- Following existing error handling patterns
- Added **before** the git commit step (lines 441-459)

### Who Depends on This
- **src/orchestrator/agent-worker.ts:runPipeline()** — calls `finalize()` at line 632
- **src/orchestrator/dispatcher.ts** — spawns agent-worker.ts as subprocess
- CLI commands that trigger pipeline (run.ts, etc.)

## Existing Tests

### Test Files to Update
- **src/orchestrator/__tests__/agent-worker-team.test.ts** (line 193) — Has test: `"generated prompt includes finalize steps (commit, push, close)"`
  - This test would need updating to expect bug scanning step

- **src/orchestrator/__tests__/lead-prompt.test.ts** (line 37) — Has test: `"includes finalize steps (commit, push, close)"`
  - This test would need updating to expect bug scanning mentioned

### Test Pattern to Follow
From git.test.ts (lines 88-103 in lib/__tests__/git.test.ts):
- Use try-catch to expect execFileSync errors
- Create temp repos for testing git operations
- Verify file state before/after operations

## Recommended Approach

### Step-by-Step Implementation Plan

1. **Add bug scanning section in `finalize()` function** (agent-worker.ts, before commit step)
   - Insert new try-catch block after lines 439-440 (after report initialization, before commit)
   - Execute: `execFileSync("npm", ["run", "build"], opts)` or `execFileSync("tsc", ["--noEmit"], opts)`
   - Catch errors and add to report under new `## Type Check` section
   - Special handling: determine if errors are pre-existing vs. introduced by this PR

2. **Update report structure**
   - Add `## Type Check` section before `## Commit` section
   - Status: SUCCESS | FAILED | SKIPPED
   - Include first few lines of error output for debugging

3. **Modify lead prompt instructions** (lead-prompt.ts)
   - Update line 187 Finalize section to mention type checking
   - Show in pipeline string at line 518 and 643 if desired

4. **Update tests**
   - agent-worker-team.test.ts line 193: Add expectation for type check step
   - lead-prompt.test.ts line 37: Add expectation for typecheck mention
   - (Consider skipping type check in tests if tsc is slow)

5. **Handle edge cases**
   - If npm/tsc not found: log gracefully, don't block commit (warning vs. error)
   - If type check fails: should it block commit? (Decision point: FAIL report prevents merge downstream?)
   - If nothing changed: skip build check (can use `git diff` to detect)

### File Changes Summary
| File | Change Type | Lines |
|------|-------------|-------|
| src/orchestrator/agent-worker.ts | Add try-catch for type checking | 440-460 (insert) |
| src/orchestrator/lead-prompt.ts | Update finalize docs | 182-187, 518, 643 |
| src/orchestrator/__tests__/agent-worker-team.test.ts | Update test expectations | 193-196 |
| src/orchestrator/__tests__/lead-prompt.test.ts | Update test expectations | 37-40 |

## Potential Pitfalls & Edge Cases

1. **Performance**: `npm run build` or `tsc` can be slow on large projects
   - Consider timeout tuning (current: 30 seconds)
   - Mitigation: Skip if no files changed (check git status)

2. **Scope Creep**: Bug scan could fail on pre-existing code issues
   - Only scanchanged files? vs. entire repo?
   - Risk: Developer might have introduced a syntax error, legitimate bug scan catches it and blocks merge
   - Expected behavior: This is the point — catch issues before commit

3. **Type Check vs. Build**:
   - `tsc --noEmit`: Fast, type checking only, no dist output
   - `npm run build`: Builds full project, might generate artifacts
   - Recommendation: Use `tsc --noEmit` for safety (non-destructive) and speed

4. **Tool Not Available**: What if tsc/npm not in PATH in worktree?
   - Pattern: Use full path from node_modules/.bin like code elsewhere does
   - Example line 475 in agent-worker.ts: `const sdPath = join(process.env.HOME ?? "~", ".bun", "bin", "sd")`
   - For npm: `join(process.cwd(), "node_modules", ".bin", "tsc")`

5. **Report Format**: Should failed type checks block the commit?
   - Current implementation: Report status but still try to commit (non-blocking)
   - Alternative: Throw/skip commit if type check fails (blocking)
   - Recommendation: Follow existing pattern (non-blocking, report status) — let downstream QA/review decide

6. **Empty Changes**: What if git diff shows no changes?
   - Already handled by line 451: "nothing to commit" special case
   - Bug scan could be skipped in this case

## Implementation Notes

### Code Style & Conventions
- Use `execFileSync` with array args (never shell string concatenation)
- Use `opts` object with timeout, stdio, cwd defined at function start
- Wrap errors with context: `err instanceof Error ? err.message : String(err)`
- Truncate long errors: `.slice(0, 300)` for report, `.slice(0, 200)` for logging
- Log every step: `log("[FINALIZE] <message>")`
- Report every step: `report.push()`

### Testing Considerations
- Unit tests might want to mock/skip the type check (slow)
- Integration tests should verify the check runs and reports status
- Consider adding `config.skipTypeCheck` option for testing if needed

## Success Criteria

✅ Pre-commit bug scanning runs before `git add -A`
✅ Results reported in FINALIZE_REPORT.md
✅ Errors don't block finalization (non-fatal pattern)
✅ Both console logging and report recording implemented
✅ Tests updated to reflect new finalize step
✅ Handles missing tools gracefully
✅ Performance acceptable (< 30s timeout)
