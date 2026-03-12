# Code Review: Agent checkpoint save/restore for crash recovery

## Verdict: PASS

## Summary

The implementation adds a `phase_checkpoints` SQLite table and four store methods (`savePhaseCheckpoint`, `getPhaseCheckpoints`, `getPhaseCheckpoint`, `deletePhaseCheckpoints`), then modifies `runPipeline()` to load existing checkpoints on startup, skip already-completed phases, save a checkpoint after each phase succeeds, and delete all checkpoints on clean pipeline completion. A companion file-based checkpoint mechanism (`saveCheckpoint`/`loadCheckpoint`/`deleteCheckpoint`) is added for single-agent mode. A critical double-close bug in `markStuck()` found in a prior review cycle has been fixed. All CRITICAL and WARNING findings from the previous review have been resolved. The store test coverage is comprehensive (11 new tests), and the TypeScript compilation is clean.

## Issues

- **[NOTE]** `src/orchestrator/agent-worker.ts:19` — `PhaseCheckpoint` is imported as a type but never directly referenced in the file. The methods `getPhaseCheckpoints` and `getPhaseCheckpoint` return `PhaseCheckpoint[]` / `PhaseCheckpoint | null` and those types are inferred from the store method signatures, so the import is unused. TypeScript does not error on unused type-only imports by default, but it is dead code that could confuse future readers.

- **[NOTE]** `src/orchestrator/agent-worker.ts:386–387` — In `savePhaseCheckpoint`, a new UUID is generated every call (`id: randomUUID()`). Because the table has `UNIQUE(run_id, phase)` and the insert is `INSERT OR REPLACE`, a re-save for the same `(run_id, phase)` pair will delete the old row and insert a new one with a different `id`. This is functionally correct but wastes a UUID and silently changes the primary key on idempotent saves. A small design note: storing a stable `id` (e.g. derived from `run_id + phase`) would make the record more stable, though this has no practical impact given the current usage pattern.

- **[NOTE]** `src/lib/store.ts:141–151` — The `phase_checkpoints` DDL comment correctly documents that there is no `ON DELETE CASCADE` on the `runs` table, so deleting a run leaves orphaned checkpoint rows unless `deletePhaseCheckpoints` is called first. No automated cleanup exists. This is consistent with the existing behavior of the `costs` and `events` tables, and the comment added in this iteration makes the limitation explicit.

- **[NOTE]** `src/orchestrator/agent-worker.ts` (single-agent mode) — The file-based checkpoint (`saveCheckpoint`/`loadCheckpoint`) is written on session-ID capture and on every 2-second progress flush in single-agent mode, but the stale checkpoint detected at startup is only logged — it is never used to restore state. This is intentional per the design (checkpoints are diagnostic in single-agent mode; full resumption uses the SDK session ID), and the logging provides crash observability. The behavior is correct but could benefit from a short in-code comment clarifying that file-based checkpoints in single-agent mode are diagnostic only.

## Positive Notes

- All three actionable findings from the prior review cycle (CRITICAL double-close in `markStuck`, WARNING zero-cost checkpoint on max-retries exhaustion, NOTE non-null assertion in dev-qa restore path) have been correctly resolved. The fixes are targeted and minimal.
- The three-milestone checkpoint design (explorer / dev-qa / reviewer) is a pragmatic simplification that avoids complex mid-loop state reconstruction while covering the most expensive phases.
- `INSERT OR REPLACE` semantics for `savePhaseCheckpoint` provide idempotency: a crash after a checkpoint save but before the next phase starts will harmlessly re-save on retry without manual deduplication.
- Cost accumulation on resume (`progress.costUsd = existingCheckpoints.reduce(...)`) correctly seeds total spend from all prior phase checkpoints, including the fixed max-retries path that now saves actual costs instead of zeros.
- `deletePhaseCheckpoints` on successful pipeline completion keeps the table clean, preventing stale checkpoint data from affecting future re-runs of the same `runId`.
- `getPhaseCheckpoint` returns `null` (not throws) for missing phases, and the null-safe access pattern (`devQaCheckpoint?.metadata ? ... : {}`) makes the restore path safe under any checkpoint-absent edge case.
- The atomic write pattern for file-based checkpoints (write temp file + rename) prevents partial reads under concurrent access or crash mid-write.
- Store test coverage for the new methods is thorough: round-trip save/retrieve, metadata round-trip, list, null/empty cases, UNIQUE replace semantics, delete isolation across runs, Set-based recovery pattern, cost accumulation, and null-safe access pattern are all exercised.
- TypeScript compiles clean (`npx tsc --noEmit` passes with zero errors).
- No schema migration is needed — `CREATE TABLE IF NOT EXISTS` makes the change backward compatible with existing databases.
