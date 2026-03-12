# Developer Report: 4-tier merge conflict resolution

## Approach

The task was to complete the 4-tier merge conflict resolution system by wiring the existing `resolveConflict()` method in `refinery.ts` to the CLI merge command, and to add comprehensive test coverage for the Refinery class.

**Tier 1 (git.ts)** and **Tiers 2-3 (refinery.ts)** were already fully implemented. Only Tier 4 (CLI) was missing the `--resolve` and `--strategy` options. The main work was:

1. Adding `--resolve <runId>` and `--strategy <strategy>` options to `merge.ts`
2. Wiring them to call `refinery.resolveConflict()`
3. Adding validation for missing/invalid strategy values
4. Writing comprehensive unit tests for `mergeCompleted()`, `resolveConflict()`, and `orderByDependencies()`

## Files Changed

- `src/cli/commands/merge.ts` — Added `--resolve <runId>` and `--strategy <strategy>` CLI options. When `--resolve` is provided, the command enters "resolve mode": validates the strategy (must be `"theirs"` or `"abort"`), looks up the run, calls `refinery.resolveConflict()`, and displays the outcome. Error handling for missing strategy, invalid strategy, and unknown run ID is included.

## Tests Added/Modified

- `src/orchestrator/__tests__/refinery.test.ts` — New test file with 16 tests covering:
  - `resolveConflict()`:
    - Throws when run not found
    - `abort` strategy marks run as failed, returns false
    - `theirs` strategy calls git checkout + merge, marks run as merged, returns true
    - `theirs` strategy marks run as failed when git merge fails
    - `theirs` strategy removes worktree on success
    - `theirs` strategy succeeds even when worktree removal fails (non-fatal)
  - `mergeCompleted()`:
    - Returns empty report with no completed runs
    - Marks run as merged on clean merge (tests disabled)
    - Marks run as conflict when merge has conflicts
    - Marks run as test-failed when tests fail after merge
    - Merges in dependency order (topological sort)
    - Applies seedId filter when provided
    - Catches unexpected errors and reports as testFailures
  - `orderByDependencies()`:
    - Returns single run unchanged
    - Returns original order when graph unavailable
    - Places dependency before dependent

## Decisions & Trade-offs

1. **Resolve mode is mutually exclusive with normal merge mode** — When `--resolve` is given, the command exits after resolution without running `mergeCompleted()`. This matches the documented intent and keeps the flows clean.

2. **No test run after `--strategy theirs`** — The existing `resolveConflict()` does not run tests after a "theirs" merge (unlike `mergeCompleted()` which optionally runs them). This inconsistency was noted in EXPLORER_REPORT.md. I kept the existing behavior and did not add a `--run-tests` option to `resolveConflict()` to stay focused on the core task. The inconsistency can be addressed in a follow-up.

3. **Mock-based unit tests** — Rather than integration tests with real git repos (which already exist in `git.test.ts`), I used `vi.mock` to mock `node:child_process` and `../../lib/git.js`. This keeps the refinery tests fast, isolated, and focused on orchestration logic.

4. **Run validation in CLI, not in `resolveConflict()`** — Validation for missing run is done in both the CLI (with a user-friendly error message) and inside `resolveConflict()` (throws). This provides defense-in-depth and keeps the method usable as a library function.

## Known Limitations

- No test run after `--strategy theirs` conflict resolution (by design for now; see decision #2)
- The `--resolve` mode does not check whether the run is actually in `"conflict"` status; it will attempt resolution on any run (the underlying git operation will simply fail if there's no merge in progress)
- No CLI tests for the `--resolve` path (the existing `commands.test.ts` has infrastructure issues preventing tsx-based CLI tests; the refinery unit tests cover the logic thoroughly)
