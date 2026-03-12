# Developer Report: Agent checkpoint save/restore for crash recovery

## Approach

Implemented local file-based checkpoints that persist the agent's `RunProgress` state at `~/.foreman/checkpoints/<run-id>.json`. Checkpoints are written atomically (write to `.tmp` then rename) to prevent partial reads. On worker startup, the system detects any stale checkpoint from a prior crash and logs it for observability. Checkpoints are cleaned up on successful completion or permanent failure; they're intentionally preserved on rate-limit/stuck states so a subsequent resume can report the last known progress.

## Files Changed

- **src/orchestrator/agent-worker.ts** — Core implementation:
  - Added `checkpointDir?: string` to `WorkerConfig` interface
  - Added `CHECKPOINT_VERSION = 1` constant and `CheckpointData` interface (versioned for forward compatibility)
  - Added three helper functions: `saveCheckpoint()` (atomic write via temp+rename), `loadCheckpoint()` (returns null on missing/incompatible version), `deleteCheckpoint()`
  - On `main()` startup: creates checkpoint directory, checks for stale checkpoint and logs recovery message if found
  - Modified `flushProgress` timer to also call `saveCheckpoint` on each dirty flush (2-second intervals)
  - After session ID is first received: saves an immediate checkpoint
  - On success: `deleteCheckpoint` before marking completed
  - On permanent failure (non-rate-limit): `deleteCheckpoint` to clean up
  - On rate-limit/stuck: checkpoint preserved so `foreman resume` can report last known state

- **src/orchestrator/dispatcher.ts** — Passes checkpoint dir to workers:
  - Added `checkpointDir?: string` to `WorkerConfig` interface
  - In `spawnAgent()`: computes `~/.foreman/checkpoints` and passes it to `spawnWorkerProcess`
  - In `resumeAgent()`: same — passes checkpoint dir so resumed workers also checkpoint properly

## Tests Added/Modified

- **src/orchestrator/__tests__/agent-worker.test.ts**:
  - Added `mkdirSync` to imports
  - Added `describe("checkpoint behavior")` block with 4 tests:
    1. **Creates checkpoint directory on startup** — verifies `checkpointDir` is created even if worker fails at SDK
    2. **Detects and logs stale checkpoint** — pre-writes a valid v1 checkpoint, verifies worker logs "stale checkpoint" on stderr
    3. **Ignores checkpoint with incompatible version** — pre-writes a version=999 checkpoint, verifies worker does NOT log stale checkpoint
    4. **Uses default checkpoint dir when not in config** — omits `checkpointDir` from config, verifies `HOME/.foreman/checkpoints` is created

## Decisions & Trade-offs

- **Atomic writes**: Used temp file + rename to prevent partial checkpoint reads if the process crashes mid-write.
- **2-second flush cadence**: Checkpoint is saved on the same 2-second timer as DB progress. More frequent flushing (per-message) would reduce staleness but add I/O pressure on fast machines.
- **Preserve checkpoint on rate-limit**: When an agent hits a rate limit (`stuck` status), the checkpoint is kept so downstream tools can report "last known state was turn X". On permanent failure it's deleted since there's nothing to recover.
- **Version field**: `CheckpointData.version` allows future schema changes without breaking existing checkpoint readers.
- **No checkpoint in pipeline mode**: Pipeline phases use `persistSession: false` and are short-lived per phase. Checkpointing is only applied in single-agent mode where long-running sessions are more likely to crash.
- **Diagnostics only for now**: Checkpoint currently provides observability (log on recovery) and preserves state across rate-limit resume. Full replay from checkpoint (re-running from turn N) is deferred since SDK sessions handle actual conversation continuity.

## Known Limitations

- **Pipeline mode not checkpointed**: The `runPipeline()` path (explorer→developer→qa→reviewer) does not write per-phase checkpoints. Each phase uses `persistSession: false` and a fresh SDK session, so crash recovery for pipeline phases would require a different mechanism (tracking which phase was active).
- **2-second staleness window**: A crash between flush intervals loses up to 2 seconds of progress tracking. The checkpoint won't reflect tool calls made in the last flush window.
- **No automatic old checkpoint pruning**: Checkpoints in `~/.foreman/checkpoints/` for old runs that ended without cleanup (e.g., SIGKILL before deletion) will accumulate. A future `foreman doctor` or cron cleanup could prune files older than 30 days.
- **Single-process assumption**: The atomic rename is sufficient for the current single-worker-per-run model but would need a locking strategy if multiple processes could write the same checkpoint.
