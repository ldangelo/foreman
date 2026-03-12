# Developer Report: Multi-repo orchestration support

## Approach

This iteration addresses all feedback from the previous code review. The multi-repo orchestration feature was already implemented in the previous pass; this pass focuses entirely on correctness issues identified in the review — no new features were added.

## Files Changed

### `src/cli/commands/status.ts`
- **[CRITICAL fix]** Changed `renderStatus()` to `throw` an error instead of calling `process.exit(1)`. The `--all-projects` loop now wraps each `renderStatus(proj.path)` call in a try/catch, logs the error, and `continue`s to the next project. Single-project mode and watch mode catch the thrown error and call `process.exit(1)` as before (preserving original behavior in non-multi-project contexts).
- **[WARNING fix]** Added a warning when `--all-projects` and `--watch` are used together: `"Warning: --watch is ignored when --all-projects is set."` This makes the silent discard visible to users.
- **[NOTE fix]** Removed the no-op `const projectPath = opts.project ?? undefined` assignment; all callers now use `opts.project` directly.

### `src/cli/commands/run.ts`
- **[WARNING fix]** Added an explicit error and `process.exit(1)` when `--seed` and `--projects` are used together, with a clear message explaining that `--seed` is not supported in multi-repo mode.
- **[NOTE fix]** Updated `--projects` help text to include "(must be registered via 'foreman init')" so unregistered paths are no longer silently skipped without documentation.

### `src/orchestrator/refinery.ts`
- **[WARNING fix]** Replaced the fake `FailedRun` sentinel (`{ runId: "", seedId: "", branchName: "", error: message }`) in `mergeMultiRepo`'s catch block with a proper `errors: Record<string, string>` field on the return value. Failed projects now contribute to `errors[projectPath]` instead of polluting `testFailures` with empty-string entries.
- **[WARNING fix]** Changed `sorted.includes(run)` to `sorted.some((r) => r.id === run.id)` in `orderByDependencies` for robustness against object cloning.
- **[NOTE fix]** Moved the `log()` function to the top of the file (before the `Refinery` class), making it available without relying on runtime-only hoisting semantics.
- **[NOTE fix]** Replaced all inline `import("../lib/store.js").Run` type annotations with a top-level `import type { ForemanStore, Run }` import for cleaner, idiomatic TypeScript.

### `src/orchestrator/types.ts`
- Added `errors: Record<string, string>` field to `MultiRepoMergeReport` to support the clean error-reporting path in `mergeMultiRepo`.

### `src/orchestrator/__tests__/multi-repo.test.ts`
- Updated existing `Refinery.mergeMultiRepo` tests to assert `result.errors` equals `{}` for the happy path.
- Added new test: "captures project-level merge errors in errors record, not as fake FailedRun" — verifies that when `mergeCompleted()` throws, the error appears in `result.errors[projectPath]` and `testFailures` is empty.

## Tests Added/Modified

- `src/orchestrator/__tests__/multi-repo.test.ts` — added assertions for `result.errors` field; added a test for the error capture path in `mergeMultiRepo`

## Decisions & Trade-offs

- **`renderStatus` now throws instead of exiting**: This is a breaking change in the function's contract, but it's the correct design — functions shouldn't call `process.exit()` when they might be invoked from a loop. The top-level action handlers are the appropriate place for process termination.
- **Error vs warning for `--seed` + `--projects`**: Chose a hard error (`process.exit(1)`) over a warning because silently ignoring the `--seed` flag would be confusing — the user clearly intended it to have an effect.
- **`errors` field on `MultiRepoMergeReport`**: Adding a dedicated field is cleaner than embedding error information in `testFailures` as sentinel objects. Consumers can now distinguish "nothing to merge" from "failed to attempt merge" with a simple `Object.keys(result.errors).length > 0` check.
- **`dispatcher.ts:447` warning**: The reviewer noted this as safe — the current `>= maxTotal` guard at the top of each iteration correctly skips over-limit projects before any store hits. No change needed.

## Known Limitations

- The `--all-projects` + `--watch` interaction still silently ignores `--watch` after printing the warning. A full fix would require running the watch loop across all projects, which is out of scope for this iteration.
- `mergeMultiRepo` still creates a `Refinery` instance per project, which means it cannot easily batch or pipeline across projects. This is by design (consistency with `dispatchMultiRepo`).
