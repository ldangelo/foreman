# Code Review: 4-tier merge conflict resolution

## Verdict: FAIL

## Summary
The implementation successfully wires the Tier 4 CLI (`--resolve`/`--strategy`) to the pre-existing `resolveConflict()` method in `refinery.ts`, and adds solid test coverage for all three Refinery methods. However, two correctness bugs exist in `resolveConflict()` that must be fixed before shipping: (1) the target branch is hard-coded to `"main"`, silently ignoring `--target-branch`; and (2) a failed `-X theirs` merge is not aborted, which can leave the repository in a mid-merge state. Additionally, the CLI does not validate that the run is actually in `"conflict"` status before applying `--resolve`, which can cause state regressions.

## Issues

- **[CRITICAL]** `src/orchestrator/refinery.ts:281` — `resolveConflict()` hard-codes `git checkout main` regardless of what target branch was used during the original merge. If the project uses `--target-branch develop` (or any non-`main` branch), conflict resolution silently merges into `main` instead of the intended target. The `targetBranch` must be stored on the run record (or passed in) and used here, consistent with how `mergeCompleted()` accepts a `targetBranch` option.

- **[CRITICAL]** `src/orchestrator/refinery.ts:303` (catch block) — When `git merge ... -X theirs` fails, the catch block marks the run as failed and returns, but never calls `git merge --abort`. The repository is left in a mid-merge state with conflict markers, blocking all subsequent git operations. Compare with `mergeCompleted()` lines 160–164 which correctly calls `git merge --abort` after a conflict. The same cleanup must be applied here.

- **[WARNING]** `src/cli/commands/merge.ts:47-52` — The CLI verifies the run exists but does not check that `run.status === "conflict"`. Running `foreman merge --resolve <id> --strategy abort` on an already-`merged` run will mark it as `"failed"`, permanently regressing its state. Running `--strategy theirs` on a `"completed"` (not yet conflicted) run will attempt a duplicate merge. A guard like `if (run.status !== "conflict") { console.error(...); process.exit(1); }` is needed.

- **[WARNING]** `src/orchestrator/refinery.ts:256` — `resolveConflict()` accepts no `targetBranch` parameter, so there is no way to pass the target branch through the call chain. The CLI's `--target-branch` option is silently dropped in `--resolve` mode (line 57 of `merge.ts` calls `refinery.resolveConflict(runId, strategy)` with no branch argument). The method signature needs a `targetBranch?: string` parameter and the CLI must forward `opts.targetBranch`.

- **[WARNING]** `src/orchestrator/__tests__/refinery.test.ts:143-164` — The test for "theirs strategy marks run as failed if git merge fails" correctly asserts the return value and status update, but does not verify that `git merge --abort` is called. Adding this assertion would have caught the cleanup bug above and would guard against future regressions.

- **[WARNING]** No tests run after `--strategy theirs` succeeds. `mergeCompleted()` runs the test suite after each merge (Tier 2 safety gate), but `resolveConflict()` skips tests entirely. This means broken code can reach `main` via the conflict-resolution path, bypassing the test guard that protects the normal path. Consider running `runTestCommand` in `resolveConflict()` and reverting (`git reset --hard HEAD~1`) on failure, consistent with `mergeCompleted()`.

## Positive Notes

- Test coverage for `resolveConflict()`, `mergeCompleted()`, and `orderByDependencies()` is thorough and well-structured; the mock helpers are clean and reusable.
- The CLI validation for missing/invalid `--strategy` is properly ordered and provides clear error messages.
- Defense-in-depth: run lookup is done in both the CLI and `resolveConflict()`, ensuring a useful error even if the method is called directly.
- Worktree removal failure is correctly treated as non-fatal in both `resolveConflict()` and `mergeCompleted()`.
- The topological sort (Kahn's algorithm) correctly handles the edge case of runs not present in the dependency graph by appending them after sorted runs.
- The `--list` output with dependency-ordered display and helpful follow-up hints (`foreman merge`, `foreman merge --seed <id>`) is a nice UX addition.
