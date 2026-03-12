# Explorer Report: Detect and fix seed/agent state mismatches in foreman reset

## Summary

The foreman system tracks work through two state machines that are not properly synchronized:
- **Seed State**: Managed by the seeds backend (status: `open`, `in_progress`, `closed`, `completed`)
- **Run State**: Managed by foreman's SQLite store (status: `pending`, `running`, `completed`, `failed`, `stuck`, `merged`, `conflict`, `test-failed`, `pr-created`)

**The Mismatch**: When a seed is dispatched for work, the dispatcher marks the seed as `in_progress` and creates a run. However, when the agent completes (run becomes `completed`, `failed`, or `stuck`), the seed's status is never updated. This leaves seeds orphaned in `in_progress` state long after their runs have finished, creating inconsistency during reset operations.

## The Problem in Detail

### Current Flow (with Bug)

```
Dispatcher.dispatch()
  ├─ create run (status: pending)
  ├─ mark seed "in_progress"
  └─ spawn agent
       └─ Agent completes
            ├─ agent-worker.ts: update run (status: completed/failed/stuck)
            └─ 🐛 BUG: seed status NOT updated → still "in_progress"

After any run completes:
  ├─ Seed: "in_progress" (stale)
  ├─ Run: "completed" | "failed" | "stuck" (correct)
  └─ MISMATCH!

Reset.command()
  ├─ finds run with status "failed" or "stuck"
  ├─ resets seed to "open" (blindly, no mismatch check)
  └─ but what if run is actually "completed"? Seed should be "closed", not "open"
```

### Where Mismatches Occur

1. **Normal Completion Path** (agent-worker.ts lines 206-240)
   - Run marked as `completed` → seed still `in_progress` ❌
   - Seed should be `closed` or `completed`

2. **Failure/Rate Limit Path** (agent-worker.ts lines 220-241)
   - Run marked as `failed` or `stuck` → seed still `in_progress` ❌
   - Seed should remain resettable, but being left in `in_progress` is confusing

3. **Merge/Finalize Path** (refinery.ts lines 207-230)
   - Run marked as `merged`, `conflict`, `test-failed`, `pr-created` → seed never updated ❌
   - Seed should be closed after successful merge

4. **Monitor Detection Path** (monitor.ts lines 39-52)
   - Monitor checks seed status to detect completion
   - Works one-way: seed `closed` → run marked `completed`
   - But reverse sync (run completion → seed update) is missing

## Relevant Files

### 1. **src/cli/commands/reset.ts** (lines 9-183)
- **Purpose**: Kills agents, removes worktrees, resets seeds to "open", and marks runs as failed
- **Current State**:
  - Line 59: Gets "ready" seeds and filters to active runs
  - Lines 127-143: Resets seeds to "open" status
  - Line 131: Calls `await seeds.update(seedId, { status: "open" })`
  - **Issue**: No detection of seed/run state mismatches before or during reset
  - **Issue**: Doesn't verify that seed status matches its run's actual status
- **Relevance**: Primary location where mismatches should be detected and fixed

### 2. **src/orchestrator/dispatcher.ts** (lines 100-187)
- **Purpose**: Dispatches ready seeds and creates runs
- **Current State**:
  - Line 129-134: Creates run with `status: pending`
  - Line 146: Marks seed as `status: in_progress`
  - Line 163-167: Updates run to `status: running` after spawn
  - **Issue**: Sets seed to `in_progress` but never resets it when run completes
- **Relevance**: Source of the mismatch — initiates the asynchronous state divergence

### 3. **src/orchestrator/agent-worker.ts** (lines 200-296)
- **Purpose**: Worker process that runs SDK queries and updates run progress
- **Current State**:
  - Lines 206-240: Handles SDK result (success/failure/rate-limit)
  - Line 207: `store.updateRun(runId, { status: "completed", ... })`
  - Lines 227-230: `store.updateRun(runId, { status: "failed" or "stuck", ... })`
  - **Issue**: Updates only the run, never syncs back to seed
  - **Issue**: No call to `seeds.update()` or `seeds.close()`
  - **Missing**: Logic to set seed to `closed` when run completes
- **Relevance**: Agent completion point — where seed status SHOULD be updated but isn't

### 4. **src/orchestrator/monitor.ts** (lines 15-92)
- **Purpose**: Checks all active runs and detects completion/failure
- **Current State**:
  - Line 37: Fetches seed detail via `seeds.show(run.seed_id)`
  - Lines 39-52: If seed status is `closed` or `completed`, marks run as `completed`
  - **Issue**: One-way sync only (seed → run)
  - **Issue**: If run is `completed` but seed is `in_progress`, nothing happens
  - **Missing**: Reverse sync to update seed based on run status
- **Relevance**: Detection point — could identify and fix mismatches proactively

### 5. **src/orchestrator/refinery.ts** (lines 130-424)
- **Purpose**: Merges completed runs and creates PRs
- **Current State**:
  - Lines 216-225: Updates run to `merged` after successful merge
  - Lines 266-295: Updates run status on conflict resolution
  - **Issue**: Never updates seed status after merge/PR operations
  - **Missing**: Call to `seeds.close()` or `seeds.update()` after run finalized
- **Relevance**: Finalization point — should sync seed to terminal state

### 6. **src/lib/store.ts** (lines 18-30, 96-108)
- **Purpose**: SQLite data model for runs and projects
- **Current State**:
  - `Run` interface has `status` but no `seed_status_at_creation` or mismatch tracking
  - No schema to store expected seed status or detect deviations
  - **Issue**: No way to know what the seed status was when run was created
  - **Issue**: No audit trail of seed state changes
- **Relevance**: Could be enhanced to track seed state at run creation for debugging

### 7. **src/lib/seeds.ts** (lines 185-214)
- **Purpose**: SeedsClient for sd CLI operations
- **Current State**:
  - `update()` method exists (line 186) — can update seed status
  - `close()` method exists (line 209) — closes a seed with optional reason
  - **Issue**: These methods exist but are never called from agent-worker or refinery
- **Relevance**: API is available but underutilized — integration missing

## Architecture & Patterns

### State Synchronization Pattern (Current)

```
Dispatcher (creator)
  ├─ create run (pending)
  ├─ mark seed (in_progress)
  └─ spawn worker
       └─ Agent Worker (mutator)
            ├─ update run (completed/failed/stuck)
            └─ ❌ [MISSING] update seed (closed/resettable)

Monitor (observer)
  ├─ watch run status
  ├─ check seed status (one way)
  └─ mark run as completed IF seed is closed

Refinery (finalizer)
  ├─ merge completed runs
  ├─ update run status (merged/conflict)
  └─ ❌ [MISSING] update seed status

Reset (cleanup)
  ├─ find failed/stuck runs
  ├─ reset seeds to open
  └─ ❌ [BUG] doesn't detect mismatches
```

### Recommended State Machine

**Seed States:**
- `open` — ready to dispatch or resettable after failure
- `in_progress` — active run exists
- `closed` — completed successfully, run merged
- `completed` — marked complete by agent

**Run to Seed Mapping:**
- `run: pending | running` → `seed: in_progress`
- `run: completed` → `seed: closed | completed` (depending on merge status)
- `run: failed | stuck` → `seed: open` (resettable) OR `in_progress` if being resumed
- `run: merged | pr-created` → `seed: closed`
- `run: conflict | test-failed` → `seed: open` (can try again)

## Dependencies

### What Updates Seed Status
1. `dispatcher.ts` — marks seed `in_progress` on dispatch (line 146)
2. `reset.ts` — resets seed to `open` (line 131)
3. ❌ **Missing**: `agent-worker.ts` should update seed on completion
4. ❌ **Missing**: `refinery.ts` should update seed after merge
5. ❌ **Missing**: `monitor.ts` could sync seed ← run status

### What Reads Seed Status
1. `dispatcher.ts` — uses `seeds.ready()` to find dispatchable seeds
2. `monitor.ts` — checks `seeds.show()` to detect completion (lines 37-52)
3. `reset.ts` — doesn't check seed status (missing validation)

### Integration Points
- `SeedsClient` is injected into: Dispatcher, Monitor, Refinery, Reset
- All have access to `seeds.update()` and `seeds.close()`
- No cross-module constraints on state updates

## Existing Tests

### Test Files Relevant to State Sync

1. **src/orchestrator/__tests__/monitor.test.ts**
   - Tests monitor.checkAll() with seed status transitions
   - Lines 38-48: "detects completed run when seed status is closed"
   - Lines 57-70: "marks run as stuck when no status change for timeout"
   - **Status**: Tests exist for monitor detecting seed → run sync
   - **Gap**: No tests for reverse sync (run → seed)
   - **Impact**: Monitor tests pass because they only check one direction

2. **src/orchestrator/__tests__/agent-worker.test.ts**
   - Tests worker initialization and config handling
   - **Status**: No tests for run completion or seed update
   - **Gap**: Missing tests for seed state after run completes
   - **Impact**: Agent-worker bugs not caught by tests

3. **src/orchestrator/__tests__/dispatcher.test.ts**
   - Tests selectModel() logic only
   - **Status**: No integration tests for dispatch() with state tracking
   - **Gap**: Could add test: "marks seed in_progress on dispatch"
   - **Impact**: Dispatch-side issues not caught

4. **src/cli/__tests__/commands.test.ts**
   - CLI smoke tests
   - **Status**: No reset command tests
   - **Gap**: Missing test: "reset should fix seed/run mismatches"
   - **Impact**: Reset bugs not detected

## Recommended Approach

### Phase 1: Detect Mismatches

**Modify `src/cli/commands/reset.ts`:**
1. Before resetting runs, check each seed's current status
2. Compare seed status against run status:
   - If `run: completed` but `seed: in_progress` → MISMATCH
   - If `run: failed | stuck` but `seed: closed` → MISMATCH
3. Log each mismatch with details (seed ID, current seed status, expected seed status)
4. Count mismatches in output and report findings
5. Write results to a detection report (e.g., `DETECTION_REPORT.md`)

**Implementation Details:**
```typescript
// In reset.ts, after collecting runs to reset:
const mismatches: Array<{ seedId: string; runStatus: string; seedStatus: string }> = [];

for (const run of runs) {
  try {
    const seedDetail = await seeds.show(run.seed_id);
    const expectedStatus = mapRunStatusToSeedStatus(run.status);

    if (seedDetail.status !== expectedStatus) {
      mismatches.push({
        seedId: run.seed_id,
        runStatus: run.status,
        seedStatus: seedDetail.status,
      });
      console.log(`MISMATCH: ${seedId} run=${run.status} seed=${seedDetail.status}`);
    }
  } catch (err) {
    // Seed not found — can't check
  }
}

// Report mismatches
console.log(`\nDetected ${mismatches.length} seed/run state mismatches`);
```

**Helper Function:**
```typescript
function mapRunStatusToSeedStatus(runStatus: Run["status"]): string {
  switch (runStatus) {
    case "pending":
    case "running":
      return "in_progress";
    case "completed":
      return "closed";  // or "completed" depending on merge status
    case "failed":
    case "stuck":
      return "open";    // resettable
    case "merged":
    case "pr-created":
      return "closed";
    default:
      return "open";
  }
}
```

### Phase 2: Fix Detected Mismatches

**Modify `src/cli/commands/reset.ts`:**
1. After detecting mismatches, attempt to fix them
2. Update seed status to expected value based on run status
3. Log each fix: "Fixed mismatch: foreman-abc run=failed → seed=open"
4. Handle seed API errors gracefully (not found = skip)

**Implementation Details:**
```typescript
for (const mismatch of mismatches) {
  const expectedStatus = mapRunStatusToSeedStatus(mismatch.runStatus);
  try {
    console.log(`  ${chalk.yellow("fix")} ${mismatch.seedId} seed: ${mismatch.seedStatus} → ${expectedStatus}`);
    if (!dryRun) {
      await seeds.update(mismatch.seedId, { status: expectedStatus });
      seedsFixed++;
    }
  } catch (err) {
    // Handle error
  }
}
```

### Phase 3: Prevent Future Mismatches

**Modify `src/orchestrator/agent-worker.ts` (lines 206-241):**
1. When SDK returns success result, update seed to `closed` before marking run complete
2. When SDK returns error, decide: keep seed `in_progress` (for resume) or set to `open` (resettable)
3. Log seed update alongside run update

**Implementation Details:**
```typescript
if (result.subtype === "success") {
  // Mark seed as closed/completed when run succeeds
  try {
    await seeds.close(seedId, "Agent completed successfully");
  } catch (err) {
    log(`Warning: Could not close seed ${seedId}: ${err}`);
  }
  store.updateRun(runId, { status: "completed", ... });
} else {
  // Keep seed in_progress for failed/stuck (allows resume) or can mark open
  // For now, leave seed status as-is; reset command will fix mismatches
  store.updateRun(runId, { status: "failed" or "stuck", ... });
}
```

**Modify `src/orchestrator/refinery.ts` (lines 207-230):**
1. After successful merge, close the seed
2. On conflict/test failure, mark seed as `open` (resettable)

**Implementation Details:**
```typescript
// After successful merge:
try {
  await seeds.close(run.seed_id, "Successfully merged");
} catch (err) {
  log(`Warning: Could not close seed ${run.seed_id}: ${err}`);
}

// On test failure:
try {
  await seeds.update(run.seed_id, { status: "open" });
} catch (err) {
  log(`Warning: Could not mark seed as open: ${err}`);
}
```

**Modify `src/orchestrator/monitor.ts` (lines 35-88):**
1. When monitor detects run should be marked completed (based on seed status), also verify/sync seed status
2. Add reverse sync: if run is terminal but seed is still `in_progress`, update seed

**Implementation Details:**
```typescript
// Reverse sync: if run is completed but seed is in_progress, fix it
if (["completed", "failed", "stuck"].includes(run.status) && seedDetail.status === "in_progress") {
  const expectedStatus = mapRunStatusToSeedStatus(run.status);
  log(`Monitor fixing mismatch: ${run.seed_id} seed ${seedDetail.status} → ${expectedStatus}`);
  try {
    await seeds.update(run.seed_id, { status: expectedStatus });
  } catch {
    // Non-critical
  }
}
```

### Phase 4: Add Tests

**Add to `src/cli/__tests__/commands.test.ts`:**
- Test: "reset detects seed/run mismatches"
- Test: "reset fixes seed/run mismatches in dry-run and real modes"
- Test: "reset reports mismatch statistics"

**Add to `src/orchestrator/__tests__/agent-worker.test.ts`:**
- Test: "marks seed closed when run completes successfully"
- Test: "keeps seed in_progress when run fails for resume"

**Add to `src/orchestrator/__tests__/monitor.test.ts`:**
- Test: "monitor detects and fixes reverse mismatches (run terminal, seed in_progress)"

## Potential Pitfalls & Edge Cases

1. **Race Conditions**
   - Between agent completing and monitor checking: seed might briefly be in_progress
   - Monitor could detect before agent updates → false positive
   - Mitigation: Log and count mismatches, but don't fix in monitor (only in reset)

2. **Resume Semantics**
   - When run is stuck/failed, should seed be `open` or stay `in_progress`?
   - `open` = resettable, but allows re-dispatch
   - `in_progress` = prevents new dispatch, allows resume
   - Recommendation: Keep in `in_progress` for resume, let reset change to `open`

3. **Merged Runs**
   - If merge succeeds but seed close fails, seed stays `in_progress`
   - Next reset might incorrectly think run is still active
   - Mitigation: Log seed close failures prominently

4. **Seed Not Found**
   - Reset calls `seeds.show()` which throws if seed deleted externally
   - agent-worker calls `seeds.close()` which throws if seed deleted
   - Mitigation: Wrap in try/catch, log as non-critical, continue

5. **State Explosion**
   - Multiple seed states × multiple run states = complex matrix
   - Could add validation in a helper function
   - Mitigation: Keep mapping function simple and documented

6. **Backwards Compatibility**
   - Existing runs in DB might have stale seed states
   - Old runs won't have seed status snapshot in DB
   - Mitigation: Reset command can detect and fix all existing mismatches on first run

## Next Steps for Developer

1. Implement mismatch detection in reset command (Phase 1)
   - Read existing seed statuses before resetting
   - Compare against run statuses
   - Count and report mismatches

2. Implement mismatch fixing in reset command (Phase 2)
   - Update seed status to expected value
   - Log all fixes
   - Add statistics to summary

3. Implement preventive updates in agent-worker (Phase 3a)
   - Call `seeds.close()` when run completes
   - Call `seeds.update()` when run fails/stuck
   - Add logging for seed state changes

4. Implement preventive updates in refinery (Phase 3b)
   - Close seed after successful merge
   - Mark seed open after conflict/test-failure
   - Log seed state changes

5. Add comprehensive tests (Phase 4)
   - Reset mismatch detection and fixing
   - Agent-worker seed state updates
   - Monitor reverse sync (optional)

6. Validate with integration test
   - Create a seed → dispatch → complete → merge workflow
   - Verify seed status matches run status at each step
   - Run reset and verify it detects/fixes any mismatches
