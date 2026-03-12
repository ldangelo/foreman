# Developer Report: 4-tier merge conflict resolution

## Approach

Addressed all five feedback items (2 critical, 3 warnings) from the previous review cycle. The changes
are confined to `resolveConflict()` in `refinery.ts`, the `--resolve` path in `merge.ts`, and the
corresponding test file. No unrelated code was modified.

## Files Changed

- `src/orchestrator/refinery.ts` — Four fixes to `resolveConflict()`:
  1. **[CRITICAL]** Added `opts?: { targetBranch?, runTests?, testCommand? }` parameter and replaced
     hard-coded `"main"` with `opts?.targetBranch ?? "main"` so merges always target the correct branch.
  2. **[CRITICAL]** Restructured the `theirs` path so the git checkout + merge are in a `try` block
     that, on failure, calls `git merge --abort` before marking the run as `"failed"` and returning.
     This matches the cleanup pattern already used in `mergeCompleted()`.
  3. **[WARNING]** After a successful `-X theirs` merge, `runTestCommand` is now invoked (when
     `runTests !== false`). On test failure the merge is reverted with `git reset --hard HEAD~1` and
     the run is marked `"test-failed"`, consistent with `mergeCompleted()`.
  4. **[WARNING]** The `targetBranch` used during merge is now included in the `"merge"` log event for
     observability.

- `src/cli/commands/merge.ts` — Two fixes to the `--resolve` path:
  1. **[WARNING]** Added a status guard: if `run.status !== "conflict"` the CLI prints an error and
     exits, preventing accidental state regressions on already-merged or completed runs.
  2. **[WARNING]** `resolveConflict()` is now called with `{ targetBranch: opts.targetBranch,
     runTests: opts.tests, testCommand: opts.testCommand }` so the correct branch and test settings
     are forwarded from the CLI flags.

## Tests Added/Modified

- `src/orchestrator/__tests__/refinery.test.ts` — 8 new tests added (21 total, all passing):
  - **`git merge --abort` assertion** added to the existing "theirs strategy marks run as failed if
    git merge fails" test, which would have caught the cleanup bug.
  - `theirs strategy uses provided targetBranch in git checkout` — verifies the branch argument flows
    through to `git checkout`.
  - `theirs strategy defaults to main when no targetBranch provided` — regression guard for default.
  - `theirs strategy marks run as test-failed and reverts when tests fail after merge` — verifies the
    Tier 2 safety gate: merge is reverted and status set to `"test-failed"`.
  - `theirs strategy marks run as merged when tests pass after merge` — happy-path for the test gate.
  - `theirs strategy skips tests when runTests is false` — verifies the opt-out path works.

## Decisions & Trade-offs

- `resolveConflict()` returns `false` for both a merge failure and a test failure. The CLI cannot
  distinguish these two failure modes from the boolean alone. This was left as-is since adding a richer
  return type (enum / discriminated union) would be a larger refactor and was not requested. The log
  events (`"fail"` vs `"test-fail"`) do distinguish the modes for observability.
- The status guard in the CLI uses a hard exit (`process.exit(1)`) consistent with every other error
  path in `merge.ts`.

## Known Limitations

- The CLI `--resolve` path does not print a specific message distinguishing "merge failed" from "tests
  failed" — both fall into the generic `"✗ Failed to resolve conflict"` branch. A richer return type
  from `resolveConflict()` would be needed to improve this.
