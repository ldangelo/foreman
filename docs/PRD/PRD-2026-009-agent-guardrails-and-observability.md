# PRD-2026-009: Agent Guardrails and Observability

**Author:** Leo D'Angelo / Foreman Pipeline  
**Created:** 2026-03-10  
**Updated:** 2026-04-19  
**Status:** Ready for Implementation  
**Priority:** P1  
**Epic:** Agent Guardrails and Observability

---

## 1. Executive Summary

Agents running in foreman pipelines operate with insufficient operator visibility and insufficient self-protection against common failure modes. When a pipeline is running, the operator has no real-time insight into what the agent is doing, where it is working, or whether it is on track. Problems are only discovered after failure or completion — by which point significant time and cost have been wasted.

This PRD defines a set of **guardrails** (runtime-enforced constraints) and **observability features** (structured reporting) that:
1. Verify the agent's working context before and during execution
2. Provide structured, real-time activity reporting without log file archaeology
3. Ensure commits are self-documenting and survive without DB queries
4. Prevent cross-worktree contamination and stale-worktree failures

---

## 2. Problem Statement

### Current Pain Points

| Pain Point | Current Behavior | Impact |
|---|---|---|
| Agent `cd`s to wrong directory | All subsequent commands/edit tools operate in unexpected location; agent may edit files in main foreman dir instead of worktree | Wrong code changed; wasted turns; corrupted state |
| No real-time progress reporting | Operator must tail log files or poll SQLite events table | Operator blind during execution |
| Agent re-runs tests already done | `test` phase runs; then `finalize` re-runs type-check and npm ci, potentially failing | Wasted time; timeouts in finalize phase |
| Commit not self-documenting | Must query DB events + log files to reconstruct what happened | Can't understand history from `git log` alone |
| Worktree not rebased before retry | Agent sees stale uncommitted changes from previous run | Agent re-implements already-fixed code |
| No heartbeat | Foreman can't distinguish "alive but quiet" from "hung" | Time to detect stuck agent = minutes |

### Who Is This For

1. **Foreman operators (autonomous mode)** — Running pipelines without real-time monitoring, need the pipeline to be self-documenting and fail-fast on recoverable issues without human intervention
2. **Foreman operators (human-in-loop mode)** — Want visibility into agent progress before approving phase transitions or finalizing
3. **Foreman developers** — Debugging pipeline behavior, need to reconstruct what happened from commit metadata alone

---

## 3. Goals & Non-Goals

### Goals

1. **Directory verification guardrail** — Before any `edit`, `bash`, or `write` tool call, the agent confirms `pwd` matches the expected worktree. If not, the guardrail either corrects the path or aborts the operation with a clear error.

2. **Phase-entry announcement** — When a phase starts, write a structured event to the events table: `{phase, worktreePath, expectedWorktree, model, timestamp}` so the operator can poll for status without reading logs.

3. **Heartbeat events** — Every 60 seconds during an active phase, write a heartbeat event: `{phase, turns, toolCalls, filesChanged, costUsd, lastFileEdited, lastCommand}` to the events table.

4. **Self-documenting commits** — `ACTIVITY_LOG.json` is written to the worktree before commit and committed alongside the code. It contains: files changed, phases run with durations, total cost, edit counts, any retry loops.

5. **Stale-worktree detection** — Before the `fix` phase begins, verify the worktree is rebased onto the latest target branch. If not, fail-fast with a clear message and option to auto-rebase or abort.

6. **Rebase-before-finalize** — Before `finalize` phase, verify the worktree is rebased. If `dev` moved since `test`, offer to rebase before committing.

### Non-Goals

1. Real-time streaming UI or WebSocket-based live view — this is a separate observability layer
2. Agent self-correction — the guardrail enforces constraints but does not direct agent behavior
3. Changing agent system prompts — this is done in the fix phase or via workflow config
4. Cross-platform worktree isolation — assumes single-machine operation

---

## 4. Architecture Integration

### 4.1 Existing Components

The implementation will extend these existing components:

| Component | File | Role |
|---|---|---|
| Pipeline Executor | `src/orchestrator/pipeline-executor.ts` | Phase orchestration, heartbeat timer, event logging |
| Pi SDK Runner | `src/orchestrator/pi-sdk-runner.ts` | Agent session management, tool hooks |
| VCS Backend | `src/lib/vcs/interface.ts` | Stale worktree detection, rebase commands |
| Foreman Store | `src/lib/store.ts` | Events table (existing), new event types |
| Agent Worker Finalize | `src/orchestrator/agent-worker-finalize.ts` | Self-documenting commit generation |

### 4.2 New Components

| Component | File | Description |
|---|---|---|
| Guardrail Module | `src/orchestrator/guardrails.ts` | Pre-tool hook for directory verification |
| Activity Logger | `src/orchestrator/activity-logger.ts` | Generates ACTIVITY_LOG.json |
| Stale Worktree Check | `src/orchestrator/stale-worktree-check.ts` | Pre-flight rebase detection |

### 4.3 Events Table (Existing)

```sql
CREATE TABLE events (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  run_id TEXT,
  event_type TEXT NOT NULL,
  details TEXT,          -- JSON string
  created_at TEXT
);
```

New event types to add:
- `phase-start` — Before agent spawns
- `heartbeat` — 60s interval during active phase
- `guardrail-veto` — Directory mismatch detected
- `guardrail-corrected` — Directory auto-corrected
- `worktree-rebased` — Auto-rebase performed
- `worktree-rebase-failed` — Rebase conflict

---

## 5. Functional Requirements

### FR-1: Working Directory Verification Guardrail

**Description:** Before executing any `edit`, `bash`, or `write` tool call, the agent runtime verifies that the active working directory matches the expected worktree path.

**Implementation:** Inject a pre-tool hook in `pi-sdk-runner.ts` via `createAgentSession` options. The hook checks `process.cwd()` before allowing the tool to execute.

**Behavior Options:**
- **Auto-correct (default):** Prepend `cd /expected/path &&` to bash commands; fix edit/write paths
- **Veto mode:** Abort the tool call and report via `guardrail-veto` event

**Configuration:**
```yaml
# .foreman/config.yaml
guardrails:
  directory:
    mode: auto-correct  # auto-correct | veto | disabled
    allowedPaths:       # Optional: restrict to specific paths
      - /Users/ldangelo/Development
```

**Schema:**
```typescript
interface GuardrailVetoEvent {
  event_type: "guardrail-veto";
  project_id: string;
  run_id: string;
  details: {
    tool: string;
    expectedCwd: string;
    actualCwd: string;
    vetoedAt: string;  // ISO 8601
  };
}
```

**Acceptance Criteria:**
- [ ] Given an agent session with expected worktree `/worktrees/project/seed-abc`, when the agent runs `edit` while `pwd` is `/worktrees/project/seed-xyz`, then the guardrail either corrects the path or vetoes the edit
- [ ] Given a guardrail veto, when it fires, then a `guardrail-veto` event is written to the events table
- [ ] Guardrail adds <5ms overhead per tool call

### FR-2: Phase-Entry Announcement

**Description:** When a phase begins, write a structured `phase-start` event to the events table before the agent session is spawned.

**Implementation:** In `pipeline-executor.ts`, before calling `runPhase()`, write the event:

```typescript
// In runPhases() before runPhase() call
store.logEvent(config.projectId, "phase-start", {
  seedId: config.seedId,
  phase: phaseName,
  worktreePath: config.worktreePath,
  expectedWorktree: config.worktreePath,
  model: resolvePhaseModel(workflowConfig, phaseName, config.seedPriority),
  runId: config.runId,
  targetBranch: config.targetBranch,
  timestamp: new Date().toISOString(),
}, config.runId);
```

**Schema:**
```typescript
interface PhaseStartEvent {
  event_type: "phase-start";
  project_id: string;
  run_id: string;
  details: {
    seedId: string;
    phase: string;
    worktreePath: string;
    expectedWorktree: string;
    model: string;
    targetBranch: string;
    timestamp: string;
  };
}
```

**Acceptance Criteria:**
- [ ] Given a pipeline with phases `fix → test → finalize`, when the `test` phase starts, then a `phase-start` event is written before the agent prompt is sent
- [ ] Given a `phase-start` event, when the operator queries the events table, all phase transitions are visible

### FR-3: Structured Heartbeat Events

**Description:** During any active phase, write a `heartbeat` event every 60 seconds to the events table.

**Implementation:** Add an interval timer in the phase loop in `pipeline-executor.ts`. The timer tracks:
- Turn count (from session)
- Tool call breakdown (from Pi SDK session stats)
- Files changed (from git diff)
- Cost estimate (from session stats)
- Last activity timestamp

```typescript
// In runPhases() during active phase
const heartbeatInterval = setInterval(() => {
  const stats = session.getSessionStats();
  const filesChanged = await getChangedFiles(worktreePath);
  
  store.logEvent(config.projectId, "heartbeat", {
    seedId: config.seedId,
    phase: currentPhase,
    runId: config.runId,
    turns: stats.turns,
    toolCalls: stats.toolCalls,
    toolBreakdown: stats.toolBreakdown,
    filesChanged,
    costUsd: stats.estimatedCost,
    tokensIn: stats.tokensIn,
    tokensOut: stats.tokensOut,
    lastFileEdited: getLastFileEdited(worktreePath),
    lastActivity: new Date().toISOString(),
  }, config.runId);
}, 60_000);
```

**Schema:**
```typescript
interface HeartbeatEvent {
  event_type: "heartbeat";
  project_id: string;
  run_id: string;
  details: {
    seedId: string;
    phase: string;
    turns: number;
    toolCalls: number;
    toolBreakdown: Record<string, number>;
    filesChanged: string[];
    costUsd: number;
    tokensIn: number;
    tokensOut: number;
    lastFileEdited: string | null;
    lastActivity: string;
  };
}
```

**Acceptance Criteria:**
- [ ] Given an active `fix` phase running for >60 seconds, when a heartbeat fires, then the `heartbeat` event is visible in the events table
- [ ] Given a `heartbeat` event, when it is queried, all tracked fields are non-null and reasonable
- [ ] Heartbeat does not interfere with agent execution (non-blocking, async)

### FR-4: Self-Documenting Commits

**Description:** Before `finalize` commits, write an `ACTIVITY_LOG.json` to the worktree root containing the full activity record. Commit it alongside the code changes.

**Implementation:** In `agent-worker-finalize.ts`, before staging files:

```typescript
async function generateActivityLog(
  worktreePath: string,
  runId: string,
  seedId: string,
  phases: PhaseRecord[],
): Promise<void> {
  const totalCost = phases.reduce((sum, p) => sum + p.costUsd, 0);
  const totalTurns = phases.reduce((sum, p) => sum + p.turns, 0);
  
  const activityLog = {
    seedId,
    runId,
    phases: phases.map(p => ({
      name: p.name,
      startedAt: p.startedAt,
      completedAt: p.completedAt,
      durationSeconds: p.durationSeconds,
      turns: p.turns,
      costUsd: p.costUsd,
      toolCalls: p.toolCalls,
      toolBreakdown: p.toolBreakdown,
      filesChanged: p.filesChanged,
      editsByFile: p.editsByFile,
      commandsRun: p.commandsRun,
      verdict: p.verdict,
    })),
    totalCostUsd: totalCost,
    totalTurns,
    totalToolCalls: phases.reduce((sum, p) => sum + p.toolCalls, 0),
    filesChangedTotal: [...new Set(phases.flatMap(p => p.filesChanged))],
    commits: await getCommitsInWorktree(worktreePath),
    warnings: detectWarnings(phases),
    retryLoops: countRetries(phases),
    generatedAt: new Date().toISOString(),
  };
  
  await writeFile(join(worktreePath, "ACTIVITY_LOG.json"), JSON.stringify(activityLog, null, 2));
}
```

**Schema:**
```typescript
interface ActivityLog {
  seedId: string;
  runId: string;
  phases: Phase[];
  totalCostUsd: number;
  totalTurns: number;
  totalToolCalls: number;
  filesChangedTotal: string[];
  commits: CommitInfo[];
  warnings: string[];
  retryLoops: number;
  generatedAt: string;
}

interface Phase {
  name: string;
  startedAt: string;
  completedAt: string;
  durationSeconds: number;
  turns: number;
  costUsd: number;
  toolCalls: number;
  toolBreakdown: Record<string, number>;
  filesChanged: string[];
  editsByFile: Record<string, number>;
  commandsRun: string[];
  verdict: "pass" | "fail" | "skipped" | "unknown";
}
```

**Update `FINALIZE_REPORT.md`** to include:
- File diff summary (`git diff --stat`)
- Phase-by-phase summary table
- Total cost + turns
- Any warnings about worktree state, retry loops, or guardrail vetoes

**Acceptance Criteria:**
- [ ] Given a completed pipeline for a seed, when `finalize` commits, then `ACTIVITY_LOG.json` is present in the commit
- [ ] Given a `git show` of the merge commit, the operator can see all files changed, all phases run, and total cost without querying the DB
- [ ] `FINALIZE_REPORT.md` includes `git diff --stat` output

### FR-5: Stale Worktree Detection and Auto-Rebase

**Description:** Before the `fix` phase begins on a retry (existing worktree), verify the worktree is rebased onto the latest target branch.

**Implementation:** In `pipeline-executor.ts` or `dispatcher.ts`, before spawning the worker:

```typescript
async function checkAndRebaseStaleWorktree(
  vcsBackend: VcsBackend,
  worktreePath: string,
  targetBranch: string,
): Promise<{ rebased: boolean; error?: string }> {
  try {
    // Get the commit the worktree is based on
    const localBase = await vcsBackend.getHeadId(worktreePath);
    
    // Get the current target branch tip
    await vcsBackend.fetch(worktreePath);
    const remoteBase = await vcsBackend.resolveRef(worktreePath, `origin/${targetBranch}`);
    
    if (localBase === remoteBase) {
      return { rebased: true };  // Already up-to-date
    }
    
    // Worktree is stale — auto-rebase
    const result = await vcsBackend.rebase(worktreePath, `origin/${targetBranch}`);
    
    if (result.success) {
      return { rebased: true };
    } else {
      return { rebased: false, error: `Rebase failed: ${result.error}` };
    }
  } catch (err) {
    return { rebased: false, error: String(err) };
  }
}
```

**New VcsBackend Methods Needed:**
- `getHeadId(repoPath: string): Promise<string>` — Get current HEAD commit hash
- `isAncestor(repoPath: string, ancestorRef: string, descendantRef: string): Promise<boolean>` — Check if commit is ancestor

**Note:** `resolveRef` and `fetch` already exist. `getHeadId` exists in both backends. `isAncestor` exists in JujutsuBackend but not GitBackend.

**Acceptance Criteria:**
- [ ] Given a worktree at commit `abc123` where `origin/dev` is now at `def456`, when the pipeline starts, then the worktree is auto-rebased before the `fix` phase
- [ ] Given a rebase conflict, when it occurs, then a `worktree-rebase-failed` event is written and the pipeline fails with a clear message
- [ ] Given a fresh worktree (no prior commits), no rebase is attempted

### FR-6: Rebase-Before-Finalize

**Description:** Before the `finalize` phase commits, verify the worktree is rebased onto the latest target. If `origin/<target>` has moved since the `test` phase completed, either auto-rebase or fail with a clear message.

**Implementation:** In `agent-worker-finalize.ts`, at the start of finalize:

```typescript
async function preFinalizeRebaseCheck(
  vcsBackend: VcsBackend,
  worktreePath: string,
  targetBranch: string,
): Promise<void> {
  await vcsBackend.fetch(worktreePath);
  const localBase = await vcsBackend.getHeadId(worktreePath);
  const remoteBase = await vcsBackend.resolveRef(worktreePath, `origin/${targetBranch}`);
  
  if (localBase !== remoteBase) {
    log.info(`Target branch ${targetBranch} has moved. Auto-rebasing...`);
    const result = await vcsBackend.rebase(worktreePath, `origin/${targetBranch}`);
    
    if (!result.success) {
      throw new Error(`Rebase failed before finalize: ${result.error}`);
    }
    
    store.logEvent(projectId, "worktree-rebased", {
      seedId,
      reason: "pre-finalize",
      from: localBase,
      to: remoteBase,
    }, runId);
  }
}
```

**Acceptance Criteria:**
- [ ] Given a finalize phase where `origin/dev` has moved since the test phase, when finalize starts, then the worktree is rebased before any commit is made
- [ ] After auto-rebase, the finalize phase proceeds normally with Target Integration marked SUCCESS

---

## 6. Non-Functional Requirements

### NFR-1: Performance
- Guardrail overhead per tool call: <5ms
- Heartbeat flush: non-blocking, async, <100ms
- Stale detection: <2 seconds before phase starts

### NFR-2: Storage
- Heartbeat events: ~500 bytes each, written every 60 seconds per active phase
- `ACTIVITY_LOG.json`: ~2-5KB per commit
- No growth in events table for completed runs (heartbeats are for active runs only)

### NFR-3: Compatibility
- Guardrail must work with all phase types: `prompt:`, `bash:`, `command:`, `skill:`
- Must not interfere with `resume` functionality
- Backward compatible: existing pipelines without heartbeats continue to work

### NFR-4: Fail-Safe
- If heartbeat writing fails (DB write error), log the error and continue — must not kill the agent session
- If guardrail misfires (false positive), the agent can continue via a special flag or operator can disable per-phase

### NFR-5: VCS Backend Agnostic
- All VCS operations must use `VcsBackend` interface — no direct `git`/`jj` calls
- Both GitBackend and JujutsuBackend must be supported

---

## 7. Configuration

```yaml
# .foreman/config.yaml

guardrails:
  # Directory verification guardrail
  directory:
    mode: auto-correct  # auto-correct | veto | disabled
    allowedPaths: []     # Optional: restrict to specific path prefixes

observability:
  # Heartbeat configuration
  heartbeat:
    enabled: true
    intervalSeconds: 60  # 0 to disable
  
  # Activity log
  activityLog:
    enabled: true
    includeGitDiffStat: true

staleWorktree:
  # Auto-rebase stale worktrees on dispatch
  autoRebase: true
  # Fail-fast if rebase would conflict
  failOnConflict: true
```

---

## 8. Implementation Plan

### Phase 1: Infrastructure (Foundation)

#### Task 1: VcsBackend Interface Updates
**File:** `src/lib/vcs/interface.ts`, `src/lib/vcs/git-backend.ts`, `src/lib/vcs/jujutsu-backend.ts`

Add missing methods:
- [ ] `isAncestor(repoPath, ancestorRef, descendantRef): Promise<boolean>` to GitBackend
- [ ] Verify `getHeadId()` exists in both backends

#### Task 2: Events Table Extensions
**File:** `src/lib/store.ts`

Add new event types via migration:
- [ ] `guardrail-veto`
- [ ] `guardrail-corrected`
- [ ] `worktree-rebased`
- [ ] `worktree-rebase-failed`

### Phase 2: Guardrails (FR-1)

#### Task 3: Guardrail Module
**File:** `src/orchestrator/guardrails.ts` (new)

- [ ] Create `GuardrailConfig` interface
- [ ] Implement `createDirectoryGuardrail(expectedCwd, mode)`
- [ ] Create pre-tool hook function for Pi SDK
- [ ] Add `guardrail-veto` and `guardrail-corrected` event logging

#### Task 4: Integrate Guardrail into Pi SDK Runner
**File:** `src/orchestrator/pi-sdk-runner.ts`

- [ ] Accept `guardrailConfig` in `PiSdkRunnerOptions`
- [ ] Register pre-tool hook with `createAgentSession`
- [ ] Wire up config from `PipelineRunConfig`

### Phase 3: Observability (FR-2, FR-3)

#### Task 5: Phase-Start Events
**File:** `src/orchestrator/pipeline-executor.ts`

- [ ] Add `phase-start` event logging before `runPhase()` call
- [ ] Include all required fields (seedId, phase, worktreePath, model, etc.)

#### Task 6: Heartbeat System
**File:** `src/orchestrator/pipeline-executor.ts`, `src/orchestrator/activity-logger.ts` (new)

- [ ] Create heartbeat interval manager
- [ ] Track tool call breakdown from Pi SDK session stats
- [ ] Track files changed via git diff
- [ ] Write `heartbeat` events every 60 seconds
- [ ] Clean up interval on phase completion

### Phase 4: Self-Documenting Commits (FR-4)

#### Task 7: Activity Log Generator
**File:** `src/orchestrator/activity-logger.ts` (new)

- [ ] Create `ActivityLog` interface matching schema
- [ ] Implement `generateActivityLog()` function
- [ ] Implement `PhaseRecord` tracking during pipeline execution
- [ ] Generate `ACTIVITY_LOG.json` before finalize staging

#### Task 8: FINALIZE_REPORT.md Updates
**File:** `src/orchestrator/agent-worker-finalize.ts`, `src/defaults/prompts/default/finalize.md`

- [ ] Add `git diff --stat` output to finalize prompt
- [ ] Include phase-by-phase summary in report
- [ ] Document total cost + turns

### Phase 5: Stale Worktree Handling (FR-5, FR-6)

#### Task 9: Stale Worktree Detection
**File:** `src/orchestrator/stale-worktree-check.ts` (new)

- [ ] Implement `checkAndRebaseStaleWorktree()`
- [ ] Add `worktree-rebased` and `worktree-rebase-failed` events
- [ ] Integrate into `pipeline-executor.ts` before fix phase

#### Task 10: Rebase-Before-Finalize
**File:** `src/orchestrator/agent-worker-finalize.ts`

- [ ] Add pre-finalize rebase check
- [ ] Log `worktree-rebased` if auto-rebase occurred
- [ ] Fail with clear message on rebase conflict

### Phase 6: Testing

#### Task 11: Unit Tests
**File:** `src/orchestrator/__tests__/guardrails.test.ts` (new)

- [ ] Test directory guardrail auto-correct mode
- [ ] Test directory guardrail veto mode
- [ ] Test heartbeat interval timing
- [ ] Test activity log generation
- [ ] Test stale worktree detection

#### Task 12: Integration Tests
**File:** `src/orchestrator/__tests__/pipeline-executor.test.ts`

- [ ] End-to-end test with all guardrails enabled
- [ ] Test rebase scenarios in finalize

---

## 9. Acceptance Criteria Summary

| ID | Criterion | Test Scenario |
|---|---|---|
| AC-1 | Guardrail intercepts wrong-directory edit | Agent in `/wrong/path` attempts `edit` → guardrail vetoes or corrects |
| AC-2 | `phase-start` event written before agent spawns | Start `fix` phase → query events → `phase-start` event exists |
| AC-3 | Heartbeat fires every 60s during active phase | Start `fix` phase, wait 65s → query events → `heartbeat` event exists |
| AC-4 | `ACTIVITY_LOG.json` committed with code | Complete pipeline → `git show HEAD:ACTIVITY_LOG.json` → valid JSON |
| AC-5 | Stale worktree auto-rebased on retry | Worktree behind `origin/dev` → dispatch → rebase → `worktree-rebased` event |
| AC-6 | Rebase-before-finalize prevents drift failures | `origin/dev` moves during test → finalize → auto-rebase → SUCCESS |
| AC-7 | `FINALIZE_REPORT.md` contains diff stat | Complete pipeline → `FINALIZE_REPORT.md` → `git diff --stat` output present |

---

## 10. Open Questions (Resolved)

| Question | Decision |
|---|---|
| Auto-correct vs. veto? | **Auto-correct by default.** Less disruptive. Operator can set `mode: veto` for stricter enforcement. |
| Heartbeat interval configurable? | **Yes.** `observability.heartbeat.intervalSeconds` in config. Default 60s. |
| `ACTIVITY_LOG.json` replace or supplement `FINALIZE_REPORT.md`? | **Both exist.** `FINALIZE_REPORT.md` is human-readable; `ACTIVITY_LOG.json` is machine-readable. |
| Stale worktree rebase automatic or approval? | **Automatic with event logging.** Add `dispatch --no-auto-rebase` flag if operator wants control. |

---

## 11. Related Documents

- [PRD-2026-004: VCS Backend Abstraction](PRD-2026-004-vcs-backend-abstraction.md) — VcsBackend interface reference
- [PRD-2026-005: Mid-Pipeline Rebase](PRD-2026-005-mid-pipeline-rebase-and-shared-worktree.md) — Related rebase functionality
- [Workflow YAML Reference](workflow-yaml-reference.md) — Configuration reference

---

## 12. Change Log

| Date | Author | Change |
|---|---|---|
| 2026-03-10 | Leo D'Angelo | Initial PRD creation |
| 2026-04-19 | Foreman Pipeline | Updated with current architecture details, resolved open questions, refined implementation plan |
