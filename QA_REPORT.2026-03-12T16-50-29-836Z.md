# QA Report: Multi-repo orchestration support

## Verdict: PASS

## Test Results
- Test suite: 242 passed, 9 failed (see pre-existing failures below)
- New tests added: 12 (8 in `multi-repo.test.ts` + 4 in `seeds-multi-repo.test.ts`)
- All 12 new tests: **PASS**
- TypeScript type check (`tsc --noEmit`): **PASS** (0 errors)

## Pre-Existing Failures (Not Caused by This PR)

The 9 failing tests are in 4 test files that all fail for the same reason: the worktree's `node_modules` directory is incomplete (only contains `.vite` and `.vite-temp`), so the `tsx` binary at `node_modules/.bin/tsx` is missing. These tests spawn subprocesses using the `tsx` binary and fail with `ENOENT`. Running the same test suite from the main repository (which has a full `node_modules`) gives **250 passing, 0 failing**.

**Affected files (pre-existing environment issue, no code changes involved):**
- `src/cli/__tests__/commands.test.ts` — 4 failures (`--help`, `--version`, `decompose`, `plan --dry-run`)
- `src/orchestrator/__tests__/agent-worker.test.ts` — 2 failures (subprocess spawn)
- `src/orchestrator/__tests__/detached-spawn.test.ts` — 2 failures (subprocess spawn)
- `src/orchestrator/__tests__/worker-spawn.test.ts` — 1 failure (`tsx binary exists` check)

None of these test files were modified by this PR.

## New Feature Coverage

### `SeedsClient.readyAcrossRepos` / `listAcrossRepos` (seeds-multi-repo.test.ts)
- ✅ Aggregates seeds from multiple repos
- ✅ Isolates per-repo failures (failing repo returns `[]`, others unaffected)
- ✅ Empty project list input → empty output
- ✅ Options are forwarded to each underlying `list()` call

### `Dispatcher.dispatchMultiRepo` (multi-repo.test.ts)
- ✅ Unregistered projects return empty `DispatchResult` and are skipped gracefully
- ✅ Registered projects aggregate results (both projects appear in `byProject`)
- ✅ `maxAgentsTotal` limit respected — stops dispatching new projects once limit hit

### `Refinery.mergeMultiRepo` (multi-repo.test.ts)
- ✅ Unregistered projects return empty `MergeReport` and are skipped gracefully
- ✅ Per-project target branches are configured correctly
- ✅ Empty merge report when no completed runs exist

## Code Review Notes

- **Backward compatibility**: All new CLI flags (`--projects`, `--project`, `--all-projects`) are optional and have no effect on existing single-repo workflows. ✅
- **Type safety**: New `MultiRepoDispatchOpts`, `MultiRepoDispatchResult`, `MultiRepoMergeOpts`, `MultiRepoMergeReport` interfaces are well-typed in `types.ts`. TypeScript compilation passes with 0 errors. ✅
- **Fail-open behavior**: Both `dispatchMultiRepo` and `mergeMultiRepo` log a warning and return empty results for unregistered projects rather than throwing — appropriate for a multi-repo batch operation. ✅
- **`log` function in refinery.ts**: Defined as a module-level function after the class; JavaScript function hoisting makes it accessible inside class methods. ✅
- **Seed ID collisions**: Acknowledged in developer report as a known limitation; the store's `(project_id, seed_id)` pairing handles them at the data layer. ✅
- **Cross-repo dependency ordering**: Acknowledged as known limitation; within-repo ordering still applies. ✅

## Files Modified
- No source files modified by QA
- `QA_REPORT.md` — this file (written by QA)
