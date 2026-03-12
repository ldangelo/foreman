# QA Report: Add 'foreman seed' command for natural-language issue creation

## Verdict: PASS

## Test Results
- Test suite: 242 passed, 5 failed
- New tests added: 8 (in `src/cli/__tests__/seed.test.ts`)
- Pre-existing failures (unrelated to this task): 5

## Summary of Changes Verified

### New command: `foreman seed`
- `src/cli/commands/seed.ts` — full implementation
- `src/cli/index.ts` — registered `seedCommand`

### Supporting additions to merge command (separate feature merged in same commit)
- `src/cli/commands/merge.ts` — added `--seed <id>` and `--list` options
- `src/orchestrator/refinery.ts` — added `getCompletedRuns()` and `orderByDependencies()`

## Issues Found

### Pre-existing failures (5 tests, all due to worktree environment — tsx not in worktree node_modules)
These failures existed before this task's changes:

1. `src/orchestrator/__tests__/worker-spawn.test.ts > tsx binary exists in node_modules`
   - Expected `node_modules/.bin/tsx` to exist in worktree root — it doesn't because worktrees don't get a full node_modules

2. `src/orchestrator/__tests__/agent-worker.test.ts > exits with error when no config file argument given`
   - Spawns tsx from worktree node_modules (ENOENT)

3. `src/orchestrator/__tests__/agent-worker.test.ts > reads and deletes the config file on startup`
   - Same tsx binary issue

4. `src/orchestrator/__tests__/detached-spawn.test.ts > detached child process writes a file after parent exits`
   - Same tsx binary issue

5. `src/orchestrator/__tests__/detached-spawn.test.ts > detached child continues after SIGINT to process group`
   - Same tsx binary issue

### Fixed during QA: tsx path resolution in CLI smoke tests
Both `src/cli/__tests__/commands.test.ts` and `src/cli/__tests__/seed.test.ts` hardcoded:
```
path.resolve(__dirname, "../../../node_modules/.bin/tsx")
```
This path resolves to the worktree's node_modules which lacks tsx (only the main repo has it).

Fixed by adding a `findTsx()` helper that walks up the directory tree, with a fallback to the parent repo's node_modules. After this fix, all 8 seed tests and all 6 commands tests pass.

### No regressions introduced
- TypeScript compilation: clean (`npx tsc --noEmit` exits 0)
- Before changes: 14 failed tests in 5 test files
- After changes: 5 failed tests in 3 test files (all pre-existing infrastructure issues)
- Net improvement: 9 previously-failing tests now pass

## Implementation Quality Notes

The `foreman seed` command implementation correctly:
- Registers in `src/cli/index.ts`
- Validates sd CLI and project initialization before proceeding
- Supports `--no-llm` mode for direct seed creation
- Handles file input vs. inline text
- Shows `--dry-run` preview without creating seeds
- Creates seeds in first pass, then wires dependencies in second pass
- Normalises LLM output (type, priority validation with defaults)
- Strips markdown fences from Claude output
- Includes JSON repair logic for truncated responses

## Files Modified
- `src/cli/__tests__/commands.test.ts` — added `findTsx()` helper for worktree compatibility
- `src/cli/__tests__/seed.test.ts` — added `findTsx()` helper for worktree compatibility (also the new test file written by Developer)
