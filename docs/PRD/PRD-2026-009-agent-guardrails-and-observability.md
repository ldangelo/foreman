# PRD-2026-009: Agent Guardrails and Observability

## Product Summary

### Problem Statement
Agents running in foreman pipelines operate with insufficient operator visibility and insufficient self-protection against common failure modes. When a pipeline is running, the operator has no real-time insight into what the agent is doing, where it is working, or whether it is on track. Problems are only discovered after failure or completion — by which point significant time and cost have been wasted.

### Solution Overview
Add guardrails that verify the agent's working context before each phase and during execution, and add structured activity reporting that gives operators real-time visibility into agent progress without requiring log file archaeology.

### Value Proposition
- Reduce wasted agent turns and cost from misdirected work
- Enable operators to intervene earlier when an agent goes off-track
- Produce self-documenting commits that survive without log files or DB queries
- Prevent cross-worktree contamination and stale-worktree failures

---

## User Analysis

### Primary Users
1. **Foreman operators (autonomous mode)** — Running pipelines without real-time monitoring, need the pipeline to be self-documenting and fail-fast on recoverable issues without human intervention
2. **Foreman operators (human-in-loop mode)** — Want visibility into agent progress before approving phase transitions or finalizing
3. **Foreman developers** — Debugging pipeline behavior, need to reconstruct what happened from commit metadata alone

### Pain Points

| Pain Point | Current Behavior | Impact |
|---|---|---|
| Agent `cd`s to wrong directory | All subsequent commands/edit tools operate in unexpected location; agent may edit files in main foreman dir instead of worktree | Wrong code changed; wasted turns; corrupted state |
| No real-time progress reporting | Operator must tail log files or poll SQLite events table | Operator blind during execution |
| Agent re-runs tests already done | `test` phase runs; then `finalize` re-runs type-check and npm ci, potentially failing | Wasted time; timeouts in finalize phase |
| Commit not self-documenting | Must query DB events + log files to reconstruct what happened | Can't understand history from `git log` alone |
| Worktree not rebased before retry | Agent sees stale uncommitted changes from previous run | Agent re-implements already-fixed code |
| No heartbeat | Foreman can't distinguish "alive but quiet" from "hung" | Time to detect stuck agent = minutes |

### User Journey

```
Operator dispatches bead
    │
    ▼
Pipeline spawns agent in worktree
    │
    ├── Agent starts → foreman logs "phase:fix workspace:/path/to/worktree"
    │
    ├── Agent reads/writes files → foreman tracks via heartbeat events
    │
    ├── Agent attempts to cd → guardrail intercepts, verifies, confirms/corrects
    │
    ├── Phase completes → structured summary written to worktree
    │
    └── Finalize → full activity log attached to commit as FINALIZE_REPORT.md
```

---

## Goals & Non-Goals

### Goals
1. **Directory verification guardrail** — Before any `edit`, `bash`, or `write` tool call, the agent confirms `pwd` matches the expected worktree. If not, the guardrail either corrects the path or aborts the operation with a clear error.
2. **Phase-entry announcement** — When a phase starts, write a structured event to the DB: `{phase, worktreePath, expectedWorktree, model, timestamp}` so the operator can poll for status without reading logs.
3. **Heartbeat events** — Every 60 seconds during an active phase, write a heartbeat event: `{phase, turns, toolCalls, filesChanged, costUsd, lastFileEdited, lastCommand}` to the events table.
4. **Self-documenting commits** — `FINALIZE_REPORT.md` (or a new `ACTIVITY_LOG.json`) is written to the worktree before commit and committed alongside the code. It contains: files changed, phases run with durations, total cost, edit counts, any retry loops.
5. **Stale-worktree detection** — Before the `fix` phase begins, verify the worktree is rebased onto the latest target branch. If not, fail-fast with a clear message and option to auto-rebase or abort.
6. **Rebase-before-finalize** — Before `finalize` phase, verify the worktree is rebased. If `dev` moved since `test`, offer to rebase before committing.

### Non-Goals
1. Real-time streaming UI or WebSocket-based live view — this is a separate observability layer
2. Agent self-correction — the guardrail enforces constraints but does not direct agent behavior
3. Changing agent system prompts — this is done in the fix phase or via workflow config
4. Cross-platform worktree isolation — assumes single-machine operation

---

## Functional Requirements

### FR-1: Working Directory Verification Guardrail

**Description:** Before executing any `edit`, `bash`, or `write` tool call, the agent runtime verifies that the active working directory matches the expected worktree path. If the paths differ, the runtime either:
- (Preferred) Corrects the path transparently by prepending `cd /expected/path &&` to the command
- (Safe mode) Aborts the tool call and reports the mismatch via a `guardrail-veto` event

**Implementation:** Inject a guardrail wrapper around tool execution in the Pi SDK session configuration. The guardrail is a pre-tool hook that checks `process.cwd()` or equivalent before allowing the tool to execute.

**Acceptance Criteria:**
- [ ] Given an agent session with expected worktree `/worktrees/project/seed-abc`, when the agent runs `edit` while `pwd` is `/worktrees/project/seed-xyz`, then the guardrail either corrects the path or vetoes the edit
- [ ] Given a guardrail veto, when it fires, then a `guardrail-veto` event is written to the events table with details: `{tool, expectedCwd, actualCwd, vetoedAt}`
- [ ] Guardrail does not add measurable latency (<5ms overhead per tool call)

### FR-2: Phase-Entry Announcement

**Description:** When a phase begins, write a structured `phase-start` event to the events table before the agent session is spawned.

**Schema:**
```typescript
{
  event_type: "phase-start",
  details: {
    seedId: string,
    phase: string,          // "fix" | "test" | "finalize" | etc.
    worktreePath: string,
    expectedWorktree: string,
    model: string,
    runId: string,
    targetBranch: string,
    timestamp: string,      // ISO 8601
  }
}
```

**Acceptance Criteria:**
- [ ] Given a pipeline with phases `fix → test → finalize`, when the `test` phase starts, then a `phase-start` event is written before the agent prompt is sent
- [ ] Given a `phase-start` event, when the operator queries `SELECT * FROM events WHERE event_type = 'phase-start' AND run_id = ?`, all phase transitions are visible

### FR-3: Structured Heartbeat Events

**Description:** During any active phase, write a `heartbeat` event every 60 seconds to the events table.

**Schema:**
```typescript
{
  event_type: "heartbeat",
  details: {
    seedId: string,
    phase: string,
    runId: string,
    turns: number,
    toolCalls: number,
    toolBreakdown: Record<string, number>,  // {read: 40, edit: 5, bash: 12, ...}
    filesChanged: string[],                  // Absolute paths of files modified this phase
    costUsd: number,
    tokensIn: number,
    tokensOut: number,
    lastFileEdited: string | null,
    lastActivity: string,   // ISO 8601
  }
}
```

**Implementation:** The heartbeat is written by the pipeline executor, not the agent. The executor tracks tool calls via the Pi SDK `tool_use` events and updates the `progress` field on the run, then periodically flushes a heartbeat event.

**Acceptance Criteria:**
- [ ] Given an active `fix` phase running for >60 seconds, when a heartbeat fires, then the `heartbeat` event is visible in the events table
- [ ] Given a `heartbeat` event, when it is queried, all tracked fields are non-null and reasonable
- [ ] Heartbeat does not interfere with agent execution (no blocking, no IPC latency)

### FR-4: Self-Documenting Commits

**Description:** Before `finalize` commits, write an `ACTIVITY_LOG.json` to the worktree root containing the full activity record. Commit it alongside the code changes.

**Schema:**
```typescript
{
  seedId: string,
  runId: string,
  phases: [
    {
      name: string,
      startedAt: string,
      completedAt: string,
      durationSeconds: number,
      turns: number,
      costUsd: number,
      toolCalls: number,
      toolBreakdown: Record<string, number>,
      filesChanged: string[],
      editsByFile: Record<string, number>,  // file → number of edits
      commandsRun: string[],               // bash commands run
      verdict: "pass" | "fail" | "skipped" | "unknown",
    }
  ],
  totalCostUsd: number,
  totalTurns: number,
  totalToolCalls: number,
  filesChangedTotal: string[],
  commits: [
    { hash: string, message: string, timestamp: string }
  ],
  warnings: string[],   // e.g. "worktree was stale, rebased before finalize"
  retryLoops: number,   // count of phase retries
}
```

**Also update `FINALIZE_REPORT.md`** to include:
- File diff summary (files changed, lines added/removed per file — `git diff --stat`)
- Phase-by-phase summary table
- Total cost + turns
- Any warnings about worktree state, retry loops, or guardrail vetoes

**Acceptance Criteria:**
- [ ] Given a completed pipeline for a seed, when `finalize` commits, then `ACTIVITY_LOG.json` is present in the commit
- [ ] Given a `git show` of the merge commit, the operator can see all files changed, all phases run, and total cost without querying the DB
- [ ] `FINALIZE_REPORT.md` includes `git diff --stat` output

### FR-5: Stale Worktree Detection and Auto-Rebase

**Description:** Before the `fix` phase begins on a retry (existing worktree), verify the worktree is rebased onto the latest target branch. If `origin/<target>` has moved since the worktree's base commit, offer to rebase or fail-fast.

**Implementation:** In `runPipeline()` or the dispatcher, before spawning the worker:
```typescript
const localBase = await vcs.getBaseCommit(worktreePath);
const remoteBase = await vcs.resolveRef(worktreePath, `origin/${targetBranch}`);
if (localBase !== remoteBase) {
  // Worktree is stale — offer auto-rebase
  const rebased = await vcs.rebase(worktreePath, `origin/${targetBranch}`);
  if (!rebased) throw new Error("Stale worktree: rebase failed");
  logEvent("worktree-rebased", { seedId, from: localBase, to: remoteBase });
}
```

**Acceptance Criteria:**
- [ ] Given a worktree at commit `abc123` where `origin/dev` is now at `def456` (different from the worktree's base), when the pipeline starts, then the worktree is auto-rebased onto `origin/dev` before the `fix` phase
- [ ] Given a rebase conflict, when it occurs, then a `worktree-rebase-failed` event is written and the pipeline fails with a clear message (not a cryptic git error)
- [ ] Given a fresh worktree (no prior commits), no rebase is attempted

### FR-6: Rebase-Before-Finalize

**Description:** Before the `finalize` phase commits, verify the worktree is rebased onto the latest target. If `origin/<target>` has moved since the `test` phase completed, either auto-rebase or fail with a clear message.

**Note:** This is a simpler version of FR-5 applied at finalize time, not dispatch time. It prevents the "target branch drifted" finalize failures observed in the `foreman-fc1ed` retry.

**Acceptance Criteria:**
- [ ] Given a finalize phase where `origin/dev` has moved since the test phase, when finalize starts, then the worktree is rebased before any commit is made
- [ ] After auto-rebase, the finalize phase proceeds normally with Target Integration marked SUCCESS

---

## Non-Functional Requirements

### NFR-1: Performance
- Guardrail overhead per tool call: <5ms
- Heartbeat flush: non-blocking, async, <100ms
- FR-5 (stale detection): <2 seconds before phase starts

### NFR-2: Storage
- Heartbeat events: ~500 bytes each, written every 60 seconds per active phase
- `ACTIVITY_LOG.json`: ~2-5KB per commit
- No growth in events table for completed runs (heartbeats are for active runs only)

### NFR-3: Compatibility
- Guardrail must work with all phase types: `prompt:`, `bash:`, `command:`, `skill:`
- Must not interfere with `resume` functionality
- Backward compatible: existing pipelines without heartbeats continue to work

### NFR-4: Fail-Safe
- If heartbeat writing fails (DB write error), it must not kill the agent session — log the error and continue
- If guardrail misfires (false positive), the agent can override via a special flag or the operator can disable the guardrail per-phase via workflow config

---

## Acceptance Criteria Summary

| ID | Criterion | Test Scenario |
|---|---|---|
| AC-1 | Guardrail intercepts wrong-directory edit | Agent in `/wrong/path` attempts `edit(file=/worktree/X/src/foo.ts)` → guardrail vetoes or corrects |
| AC-2 | `phase-start` event written before agent spawns | Start `fix` phase → query events table → `phase-start` event exists |
| AC-3 | Heartbeat fires every 60s during active phase | Start `fix` phase, wait 65s → query events → `heartbeat` event exists |
| AC-4 | `ACTIVITY_LOG.json` committed with code | Complete pipeline → `git show HEAD:ACTIVITY_LOG.json` → valid JSON with all phases |
| AC-5 | Stale worktree auto-rebased on retry | Worktree behind `origin/dev` → dispatch → rebase → `worktree-rebased` event |
| AC-6 | Rebase-before-finalize prevents drift failures | `origin/dev` moves during test → finalize → auto-rebase → SUCCESS |
| AC-7 | `FINALIZE_REPORT.md` contains diff stat | Complete pipeline → `FINALIZE_REPORT.md` → `git diff --stat` output present |

---

## Technical Notes

### Implementation Location
- **FR-1 (Guardrail):** `src/orchestrator/phase-runner.ts` — inject pre-tool hook into Pi SDK session config
- **FR-2 (Phase announcement):** `src/orchestrator/pipeline-executor.ts` — write `phase-start` before `runWithPi()`
- **FR-3 (Heartbeat):** `src/orchestrator/pipeline-executor.ts` — add interval timer in the phase loop
- **FR-4 (Self-doc commits):** `src/orchestrator/agent-worker-finalize.ts` — generate `ACTIVITY_LOG.json` before commit
- **FR-5 (Stale worktree):** `src/orchestrator/dispatcher.ts` — in `spawnWorkerProcess()` or `runPipeline()`
- **FR-6 (Rebase before finalize):** `src/orchestrator/agent-worker-finalize.ts` — check and rebase before staging

### Open Questions
1. Should guardrail auto-correct (transparent `cd`) or always veto and let the agent self-correct? Auto-correct is less disruptive but may mask real issues.
2. Should heartbeat interval be configurable per workflow? A long-running `fix` phase might want 2-minute heartbeats; a short `finalize` might not need any.
3. Should `ACTIVITY_LOG.json` replace `FINALIZE_REPORT.md` or supplement it? Current design: both exist, `FINALIZE_REPORT.md` is human-readable, `ACTIVITY_LOG.json` is machine-readable.
4. Should the stale-worktree rebase (FR-5) be automatic or require operator approval? Current design: automatic with event logging. If operator wants control, add a `dispatch --no-auto-rebase` flag.

---

## Epic Structure (for foreman dispatch)

This PRD should be dispatched as an epic with the following child tasks:

| Task | Description | Phase |
|---|---|---|
| TRD- Guardrail | Implement directory verification guardrail (FR-1) | explorer → developer → qa |
| TRD- Heartbeat | Implement phase-start and heartbeat events (FR-2, FR-3) | explorer → developer → qa |
| TRD- Activity Log | Generate and commit ACTIVITY_LOG.json (FR-4) | explorer → developer → qa |
| TRD- Stale Rebase | Auto-rebase stale worktrees on dispatch (FR-5) | explorer → developer → qa |
| TRD- Finalize Rebase | Rebase before finalize to prevent drift failures (FR-6) | explorer → developer → qa |
| TRD- Integration Test | End-to-end test of full guardrails + observability stack | qa |
