# QA Report: Agent checkpoint save/restore for crash recovery

## Verdict: PASS

## Test Results
- Test suite: 245 passed, 7 failed (252 total)
- New tests added: 13 (9 phase-checkpoint store tests + 4 agent-worker checkpoint behavior tests)
- Baseline (before this change): 230 passed, 9 failed (239 total)
- Net improvement: +15 passing, −2 pre-existing failures resolved

## Issues Found

### Fixed During QA
**agent-worker.test.ts — TSX binary path in git worktree** (QA fix applied)

The new checkpoint tests (and 2 pre-existing tests) all failed because the test resolves the `tsx` binary at `PROJECT_ROOT/node_modules/.bin/tsx`. In a git worktree, the `node_modules` directory lives in the parent project (`foreman/`) rather than the worktree (`foreman/.foreman-worktrees/foreman-dc29/`), so the binary was not found.

Fixed by adding a fallback lookup:
```ts
const TSX_BIN = existsSync(join(PROJECT_ROOT, "node_modules", ".bin", "tsx"))
  ? join(PROJECT_ROOT, "node_modules", ".bin", "tsx")
  : join(PROJECT_ROOT, "..", "..", "node_modules", ".bin", "tsx");
```

After fix: all 7 agent-worker tests pass (including the 2 that were already broken before this change).

### Pre-existing Failures (not caused by this change, not fixed)

These 7 failures existed before the checkpoint implementation and are unrelated environment issues in the git worktree:

1. **commands.test.ts** (4 tests) — CLI binary not compiled in worktree; `execFile` fails with ENOENT. Pre-existing.
2. **worker-spawn.test.ts** — "tsx binary exists in node_modules" directly asserts tsx lives at the worktree's node_modules path. Pre-existing.
3. **detached-spawn.test.ts** (2 tests) — Uses tsx from worktree node_modules for spawning child process. Pre-existing.

## Implementation Review

### store.ts — `PhaseCheckpoint` table and methods
- ✅ New `phase_checkpoints` DB table with `UNIQUE(run_id, phase)` constraint
- ✅ `savePhaseCheckpoint()` uses stable derived ID `run_id:phase` (idempotent INSERT OR REPLACE)
- ✅ `getPhaseCheckpoints()`, `getPhaseCheckpoint()`, `deletePhaseCheckpoints()` all correct
- ✅ All 9 new store unit tests pass

### agent-worker.ts — File checkpoint (crash diagnostics)
- ✅ `saveCheckpoint()` writes atomically (temp file → rename) — correct
- ✅ `loadCheckpoint()` returns null for missing file or wrong schema version — correct
- ✅ `deleteCheckpoint()` called on success and non-rate-limit failures — correct
- ✅ Stale checkpoint detected and logged on startup
- ✅ `checkpointDir` defaults to `$HOME/.foreman/checkpoints` if not in config

### agent-worker.ts — Pipeline phase skipping
- ✅ `store.getPhaseCheckpoints(runId)` called at pipeline start
- ✅ Completed phases skipped via `completedPhases.has("explorer")` guards
- ✅ Prior cost seeded into `progress.costUsd` from stored checkpoints
- ✅ `savePhaseCheckpoint()` called after each phase completes

### dispatcher.ts
- ✅ `checkpointDir` passed in `WorkerConfig` for both spawn and resume paths

## Files Modified
- `src/orchestrator/__tests__/agent-worker.test.ts` — Fixed TSX binary path fallback for worktree environment; this also resolves 2 pre-existing test failures
