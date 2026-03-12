# Explorer Report: Agent checkpoint save/restore for crash recovery

## Summary

Foreman agents are spawned as detached child processes that run the Claude Agent SDK `query()` loop. Currently, agents rely on SDK session persistence (`persistSession: true`) and session resumption to recover from rate limits. This task extends crash recovery to handle unexpected agent process termination by implementing local checkpoint files that can restore agent state.

## Relevant Files

### Core Agent Execution
- **src/orchestrator/agent-worker.ts** (728 lines) — Main worker process
  - Lines 52-296: Single-agent mode with SDK query loop and progress tracking
  - Lines 298-650: Pipeline mode (explorer→developer→qa→reviewer orchestration)
  - Lines 107-130: Progress object tracking (turns, toolCalls, cost, filesChanged)
  - Lines 158-243: Message loop with SDK streaming and result handling
  - Lines 122-129: Progress flush timer (2-second intervals)
  - Currently uses `persistSession: true` (lines 143, 154) but no local checkpoints

### State Management & Persistence
- **src/lib/store.ts** (100+ lines read) — SQLite database
  - `Run` interface (lines 18-30): session_key, status, progress fields
  - `RunProgress` interface (lines 64-75): tracks toolCalls, toolBreakdown, filesChanged, turns, costUsd, currentPhase
  - Schema includes progress TEXT column for JSON serialization
  - `updateRunProgress()` method persists RunProgress to DB

### Dispatcher & Session Management
- **src/orchestrator/dispatcher.ts** (691 lines)
  - Lines 40-194: `dispatch()` method spawns new agents
  - Lines 195-316: `resumeRuns()` method resumes stuck/failed runs using SDK session IDs
  - Lines 468-556: `spawnAgent()` and `resumeAgent()` methods
  - Lines 598-636: `spawnWorkerProcess()` spawns detached worker with config JSON file
  - Lines 678-682: `extractSessionId()` extracts SDK session from `foreman:sdk:<model>:<runId>:session-<sessionId>` format
  - Currently tracks session_key in DB but no local file-based checkpoints

### CLI Commands
- **src/cli/commands/run.ts** — Dispatches agents
- **src/cli/commands/attach.ts** — Attaches to running sessions
- **src/cli/commands/reset.ts** — Resets runs (likely resets status in DB)

### Worker Configuration
- Lines 34-48 (agent-worker.ts): `WorkerConfig` interface
- Lines 575-589 (dispatcher.ts): Duplicated WorkerConfig interface
- Config passed via temp JSON file, read + deleted by worker at startup

### Testing
- **src/orchestrator/__tests__/agent-worker.test.ts** (100+ lines)
  - Tests config file deletion, log directory creation
  - Currently tests basic worker startup/failure scenarios
- **src/lib/__tests__/store.test.ts** — Database layer tests

## Architecture & Patterns

### Current Session Recovery Model
1. **SDK-Level Persistence**: Agent uses `persistSession: true` → SDK stores session state on Anthropic servers
2. **Session ID Tracking**: Worker extracts session_id from SDK messages, stores in DB as `session_key`
3. **Rate-Limit Recovery**: When agent gets rate-limited, SDK returns error. Dispatcher detects and calls `resumeRuns()` with session ID
4. **Resume Flow**: Dispatcher creates new run, spawns worker with `resume: <sessionId>` parameter

### Checkpoint Challenges
1. **Detached Process**: Worker runs as fully detached child (lines 623 `detached: true`), unref'd (line 629)
2. **No Heartbeat**: Parent doesn't monitor worker — relies on worker updating DB every 2 seconds
3. **Config Cleanup**: Config file deleted after reading (line 61) — lost after startup
4. **Partial State Loss**: If worker crashes mid-turn, progress might be stale (last 2-second flush)

### Existing Progress Tracking
- `RunProgress` object updated every tool use (lines 178-191)
- Progress flushed to DB every 2 seconds (lines 122-129)
- Includes: turns, toolBreakdown, filesChanged, tokensIn/Out, costUsd, lastActivity, currentPhase
- Progress stored as JSON string in `runs.progress` column

### File Organization Pattern
- Worktree per seed: `~/.foreman-worktrees/<seed-id>/`
- Config files: `~/.foreman/tmp/worker-<run-id>.json`
- Logs: `~/.foreman/logs/<run-id>.log`, `.out`, `.err`
- **No checkpoint directory pattern yet**

## Dependencies

### What Depends on Agent-Worker
- **dispatcher.ts**: Spawns worker, tracks session key, calls resumeRuns()
- **store.ts**: Receives progress updates, stores session_key and progress
- **CLI commands**: run, attach, reset, monitor all depend on worker status/session tracking

### What Agent-Worker Depends On
- **Claude Agent SDK** (`@anthropic-ai/claude-agent-sdk`): query() loop, persistSession, resume
- **ForemanStore**: updateRunProgress(), updateRun(), logEvent()
- **Node.js fs/child_process**: File ops, logging, execFileSync for finalization
- **Orchestrator roles**: explorerPrompt, developerPrompt, qaPrompt, reviewerPrompt

### SDK API Contracts
- `query({ prompt, options })` — Streaming generator of SDKMessage
  - Options include: `persistSession`, `resume`, `maxBudgetUsd`, `cwd`, `model`, `env`
  - Returns: assistant messages, tool results, final result message
  - **No explicit checkpoint save/load** in SDK API

## Existing Tests

### Unit Tests
- `src/orchestrator/__tests__/agent-worker.test.ts` — Startup, config deletion, logging
- `src/lib/__tests__/store.test.ts` — Database CRUD operations
- `src/orchestrator/__tests__/dispatcher.test.ts` — Dispatch, resume flows (likely)

### Integration Tests
- `src/cli/__tests__/commands.test.ts` — CLI command execution
- Pipeline tests in dispatcher/agent-worker tests

### Test Patterns
- Use `mkdtempSync` for isolated temp directories
- Use `execFileSync` to spawn worker in tests
- Mock or stub SDK interactions

## Recommended Approach

### Phase 1: Design Checkpoint Format
1. **Checkpoint File**: Write `~/.foreman/checkpoints/<run-id>.json` periodically
2. **Contents**: Serialize full RunProgress object + current step context
3. **Timing**: Flush whenever progress changes (more frequent than 2s), on timer, and on SDK messages
4. **Lifecycle**: Load at startup, delete on completion/permanent failure

### Phase 2: Implement Checkpoint I/O
1. **In agent-worker.ts**:
   - Add `checkpointDir` to WorkerConfig
   - Create checkpoint helper functions: `saveCheckpoint(runId, progress)`, `loadCheckpoint(runId)`
   - Modify progress flush: update both DB and checkpoint file
   - On startup: check for stale checkpoint, log it for observability

2. **In dispatcher.ts**:
   - Detect and report stale checkpoints on startup
   - Pass checkpoint dir in WorkerConfig
   - Add cleanup: delete checkpoint on success/permanent failure

### Phase 3: Recovery Logic
1. **Dispatcher detects crash**:
   - When `resumeRuns()` is called, check if checkpoint exists
   - If checkpoint newer than last DB progress update → agent likely crashed
   - Treat checkpoint state as "best known" state for logging/diagnostics

2. **Worker recovery**:
   - On startup, if checkpoint exists → log "Recovering from checkpoint at turn X"
   - Continue from saved progress marker, NOT from SDK resume
   - Clear checkpoint after successful completion or permanent failure

### Phase 4: Testing
1. **Unit tests**:
   - saveCheckpoint/loadCheckpoint functions with various progress states
   - Checkpoint format validation (JSON schema)
   - Edge cases: corrupted file, missing file, stale file

2. **Integration tests**:
   - Simulate worker crash (forcible SIGKILL in test)
   - Verify checkpoint written before crash
   - Verify recovery on subsequent run

3. **E2E tests**:
   - Dispatch agent → force crash → verify checkpoint → resume → completion

## Potential Pitfalls & Considerations

1. **Checkpoint Staleness**: If worker crashes mid-message, checkpoint won't reflect partial tool execution
   - Mitigation: Flush checkpoint very frequently, after each SDK message
   - Trade-off: More I/O on fast machines

2. **Concurrent Writes**: Multiple progress updates racing to update checkpoint
   - Mitigation: Use atomic write pattern (write temp file, rename)
   - Or: Use file locking with fs-sync-lock or similar

3. **Checkpoint vs. SDK Session**: Checkpoint is local; SDK session is on Anthropic servers
   - Checkpoint helps detect crash
   - SDK session helps resume interrupted work
   - Both needed for full recovery

4. **Storage**: Checkpoints accumulate in `~/.foreman/checkpoints/`
   - Need cleanup strategy: delete on permanent failure, after 30 days, etc.
   - Could use timestamp in filename for easy pruning

5. **Schema Changes**: RunProgress interface might evolve
   - Version checkpoint files with schema version
   - Handle migration/compatibility on load

## Key Code Locations to Modify

| File | Lines | Purpose |
|------|-------|---------|
| src/orchestrator/agent-worker.ts | 34-48 | Add checkpointDir to WorkerConfig |
| src/orchestrator/agent-worker.ts | 50-120 | Add saveCheckpoint/loadCheckpoint helpers |
| src/orchestrator/agent-worker.ts | 122-129 | Enhance progress flush to also write checkpoint |
| src/orchestrator/agent-worker.ts | 245-296 | Add checkpoint cleanup on exit |
| src/orchestrator/dispatcher.ts | 575-589 | Add checkpointDir to WorkerConfig |
| src/orchestrator/dispatcher.ts | 598-636 | Create checkpoint directory in spawnWorkerProcess |
| src/lib/store.ts | Add method | Add checkpoint status tracking (optional) |

## Expected Outcome

After implementation:
1. Each active agent maintains a local checkpoint file at `~/.foreman/checkpoints/<run-id>.json`
2. If agent process crashes, checkpoint preserves last known state
3. `foreman doctor` or `foreman status` can detect stale checkpoints and report agent crash
4. `foreman resume` can report "Last known state was turn X with Y tools, resuming from SDK session..."
5. Checkpoint deleted on clean completion or permanent failure
6. Tests verify checkpoint creation, corruption handling, and recovery scenarios

## Questions for Developer

1. Should checkpoints be used to fully resume work, or only for diagnostics/reporting?
2. How often should checkpoints be flushed? Every message (more I/O) or 2-second timer (more staleness)?
3. Should old checkpoints be automatically cleaned up? (e.g., after 7 days)
4. Should checkpoint exist in worktree or user's home directory?
5. Should checkpoint format be human-readable JSON or binary?
