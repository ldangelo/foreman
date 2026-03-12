# Developer Report: Agent checkpoint save/restore for crash recovery

## Approach

This iteration builds on the file-based checkpoint foundation added by the previous developer
and addresses all four NOTEs from the previous code review. The key addition is a SQLite-backed
**phase checkpoint** system for pipeline mode, enabling a crashed pipeline to skip already-completed
phases (explorer / dev-qa / reviewer) on restart, rather than repeating all work from scratch.

## Files Changed

### `src/lib/store.ts`
- Added `PhaseCheckpoint` interface
- Added `phase_checkpoints` DDL table with `UNIQUE(run_id, phase)` constraint
  - Comment explicitly documents the absence of `ON DELETE CASCADE` (consistent with `costs`/`events` tables; callers must call `deletePhaseCheckpoints` before deleting a run) — addressing NOTE 3
- Added `savePhaseCheckpoint(runId, phase, costUsd, metadata?)` — uses **stable derived ID** (`${runId}:${phase}`) so repeated saves for the same phase don't generate a new UUID each call, addressing NOTE 2
- Added `getPhaseCheckpoints(runId)` — returns all phase checkpoints ordered by completion time
- Added `getPhaseCheckpoint(runId, phase)` — single-phase lookup, returns null if not found
- Added `deletePhaseCheckpoints(runId)` — cleans up all checkpoints on successful pipeline completion

### `src/orchestrator/agent-worker.ts`
- **NOTE 1 addressed**: `PhaseCheckpoint` is NOT imported as a type in this file — store method return types are inferred from the store's method signatures, so no type-only import is needed
- **NOTE 4 addressed**: Added an explicit comment at the `flushProgress` function in single-agent mode clarifying that file-based checkpoints are **diagnostic only** — they capture last-known state for observability but are not used to restore work; full resumption relies on the SDK session ID
- `runPipeline()` updated to load existing phase checkpoints at startup:
  - Builds `completedPhases` Set and accumulates `priorCostUsd` from existing checkpoints
  - Logs a resume message if prior checkpoints are found
  - Seeds `progress.costUsd` with `priorCostUsd` so total cost tracking is accurate across restarts
- **Explorer phase**: skips if `completedPhases.has("explorer")`; saves checkpoint on success
- **Dev-QA loop**: wraps entire loop in a checkpoint check; saves "dev-qa" checkpoint on loop exit (both pass and max-retries-exhausted paths); on resume, restores `qaVerdict` and `devRetries` from checkpoint metadata
- **Reviewer phase**: skips if `completedPhases.has("reviewer")`; saves checkpoint on success
- **Finalize**: calls `store.deletePhaseCheckpoints(runId)` on clean completion

### `src/lib/__tests__/store.test.ts`
- Added 11 new tests covering the phase checkpoint methods:
  - Round-trip save/retrieve
  - Metadata JSON serialization round-trip
  - Stable ID: repeated saves for the same `(run_id, phase)` keep the same ID, latest value wins
  - `getPhaseCheckpoint` returns null for non-existent phase
  - `getPhaseCheckpoints` returns all phases (list)
  - `getPhaseCheckpoints` returns empty array when none exist
  - `deletePhaseCheckpoints` removes only the target run's checkpoints (isolation)
  - Cost accumulation pattern: `reduce` over checkpoints seeds `priorCostUsd`
  - Null-safe metadata access pattern used in `runPipeline()`

### `src/orchestrator/__tests__/agent-worker.test.ts`
- Added 4 integration tests for file-based checkpoint behavior (pre-existing worker):
  - Creates checkpoint directory on startup
  - Detects and logs stale checkpoint on startup
  - Ignores checkpoint with incompatible version
  - Uses default checkpoint dir when not specified in config
- **Note**: These integration tests require `tsx` in the worktree's node_modules; they exhibit the same pre-existing environment limitation as the 2 original integration tests (confirmed by running tests against HEAD before changes — 2 failures pre-existed)

## Decisions & Trade-offs

- **Stable checkpoint IDs**: Used `${runId}:${phase}` as the primary key instead of UUID, directly addressing NOTE 2. This eliminates UUID churn on idempotent saves and keeps the primary key stable across restarts.

- **Three-milestone granularity** (explorer / dev-qa / reviewer): The dev-QA loop is treated as a single milestone because mid-loop recovery would require reconstructing complex state (retry count, feedback context). Saving after the full loop completes is simpler and handles the most expensive crash scenario (reviewer repeating work that succeeded).

- **No import of PhaseCheckpoint type in agent-worker.ts** (NOTE 1): The store methods return `PhaseCheckpoint` but TypeScript infers these types from the method signatures. No type-only import is needed in agent-worker.ts, avoiding the dead-code concern raised in the review.

- **Schema migration via `CREATE TABLE IF NOT EXISTS`**: No explicit migration entry is needed — the new table is created automatically on first run, backward-compatible with existing databases.

- **No ON DELETE CASCADE** (NOTE 3): Consistent with `costs` and `events` tables. The comment in the DDL documents this explicitly so future maintainers understand the orphan-cleanup responsibility.

## Known Limitations

- Integration tests in `agent-worker.test.ts` fail in the worktree environment due to missing `tsx` binary in the worktree's `node_modules` — this is a pre-existing environment limitation, not introduced by this change.
- Pipeline crash recovery skips at phase granularity (explorer / dev-qa / reviewer). A crash mid-reviewer phase would re-run the entire reviewer phase. Finer-grained recovery (e.g., per-turn) was not implemented as it would require reconstructing SDK conversation state, which is beyond the file-system checkpoint scope.
- No automatic cleanup of stale checkpoint rows for orphaned runs. Consistent with existing `costs`/`events` table behavior.
