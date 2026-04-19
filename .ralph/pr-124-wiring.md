# Wire PRD-2026-009 modules into pipeline

## Goal
Implement the missing wiring for PR #124's guardrails and observability modules.

## Steps

### 1. Add EventType values to store.ts
Add to the EventType union in src/lib/store.ts:
- "heartbeat"
- "guardrail-veto"
- "guardrail-corrected"
- "worktree-rebased"
- "worktree-rebase-failed"
- "phase-start"
- "phase-complete"
Remove all `as never` casts from the new modules.

### 2. Wire StaleWorktreeChecker into dispatcher
Import and call StaleWorktreeChecker in spawnWorkerProcess() before spawning. Check if worktree is stale and auto-rebase if needed.

### 3. Wire HeartbeatManager into pipeline-executor
Import HeartbeatManager. Start it at the beginning of each phase, stop it at the end. Pass it session stats (turns, cost, tool calls).

### 4. Wire ActivityLogger into pipeline
Import ActivityLogger. Start at pipeline start, log each phase start/complete, finalize at pipeline end.

### 5. Wire guardrails into pi-sdk-runner
Import guardrails. Wrap tool factories with guardrail hooks when configured. Pass expectedCwd from WorkerConfig.

### 6. Update WorkerConfig to include observability settings
Add observability config fields to WorkerConfig.

### 7. Verify: npx tsc --noEmit passes, tests pass