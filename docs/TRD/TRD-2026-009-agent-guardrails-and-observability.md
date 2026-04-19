# TRD-2026-009: Agent Guardrails and Observability

| Field | Value |
|---|---|
| Document ID | TRD-2026-009 |
| PRD Reference | PRD-2026-009 |
| Version | 1.0.0 |
| Status | Draft |
| Date | 2026-04-19 |
| Design Readiness Score | 4.5 |

---

## Architecture Decision

### Approach: Pre-tool Hooks + Structured Event Emission

The Foreman pipeline runs agents via the Pi SDK using `runWithPiSdk()` in `pi-sdk-runner.ts`. The SDK provides an event subscription model (`session.subscribe()`) that receives `tool_execution_start` events before tools execute. This is the ideal interception point for guardrails.

For observability, the pipeline executor already has a `logEvent()` method on the store. We extend this pattern to emit structured events (`phase-start`, `heartbeat`, `guardrail-veto`) with well-defined schemas.

**Alternatives considered:**
- **Agent-side guardrail prompts**: Add guardrail instructions to the system prompt. Rejected — prompts can be ignored; we need enforced runtime checks.
- **Post-hoc log analysis**: Parse session logs after completion. Rejected — too late for fail-fast; no real-time value.
- **WebSocket streaming**: Real-time UI updates. Rejected — out of scope; this is a backend-only change.

**Rationale:** The Pi SDK's event subscription model is designed for this. We hook into `tool_execution_start` for guardrails and use SDK stats (`session.getSessionStats()`) for heartbeats. No new processes or IPC needed.

---

## Component Changes

```
src/orchestrator/pi-sdk-runner.ts
  + guardrailConfig?: { expectedCwd: string, onVeto?: (event) => void }
  + tool execution hook in session.subscribe()    ← FR-1
  + heartbeat tracking via turn_end events        ← FR-3

src/orchestrator/pipeline-executor.ts
  + writePhaseStartEvent() before runWithPiSdk()  ← FR-2
  + setInterval heartbeat writer during phase      ← FR-3
  + pass guardrailConfig to runWithPiSdk()         ← FR-1
  + logPhaseCompletion() helper                   ← FR-4

src/orchestrator/agent-worker-finalize.ts
  + generateActivityLog() → writes ACTIVITY_LOG.json  ← FR-4
  + verifyWorktreeRebased() before staging         ← FR-6
  + include diff stat in FINALIZE_REPORT.md        ← FR-4

src/orchestrator/dispatcher.ts
  + checkWorktreeStaleness() before spawn          ← FR-5
  + autoRebaseIfStale()                            ← FR-5

src/lib/store.ts
  + new event types: 'phase-start', 'heartbeat', 'guardrail-veto', 'worktree-rebased', 'worktree-rebase-failed'
```

---

## Data Flow

### Guardrail Flow (FR-1)
```
Agent calls edit/write/bash tool
    ↓
Pi SDK emits tool_execution_start event
    ↓
pi-sdk-runner guardrail hook checks process.cwd()
    ↓
cwd === expectedWorktree?
  ├── YES → allow tool to execute
  └── NO  → (option A) prepend cd, or (option B) veto + log guardrail-veto event
    ↓
Tool execution continues or is aborted
```

### Heartbeat Flow (FR-3)
```
Phase starts → setInterval(60s)
    ↓
On each interval:
  - Query session stats (turns, cost, toolCalls)
  - Query file tracking (files modified this phase)
  - Write heartbeat event to store
    ↓
Phase ends → clearInterval
```

### Activity Log Flow (FR-4)
```
Finalize phase starts
    ↓
Read all phase events from store for this run
    ↓
Generate ACTIVITY_LOG.json schema
    ↓
Write to worktree root
    ↓
Stage ACTIVITY_LOG.json with other changes
    ↓
Commit
```

---

## Master Task List

### Phase 1: Core Infrastructure (Guardrail + Events)

#### TRD-009-001: Guardrail Hook in Pi SDK Runner [4h]
[satisfies FR-1]

**Validates PRD ACs:** AC-1

Extend `PiRunOptions` with optional `guardrailConfig?: { expectedCwd: string, mode: 'auto-correct' | 'veto' }`. In `runWithPiSdk()`, add a `tool_execution_start` handler that checks `process.cwd()` against `expectedCwd`. If mismatched:
- `mode: 'auto-correct'` → prepend `cd {expectedCwd} &&` to the tool's arguments
- `mode: 'veto'` → log `guardrail-veto` event, invoke `onVeto` callback, abort tool

**Schema for guardrail-veto event:**
```typescript
{
  event_type: 'guardrail-veto',
  details: {
    tool: string,
    expectedCwd: string,
    actualCwd: string,
    args: Record<string, unknown>,
    vetoedAt: string, // ISO 8601
    seedId: string,
    phase: string,
    runId: string,
  }
}
```

**Implementation ACs:**
- Given `guardrailConfig.mode: 'veto'` with `expectedCwd: '/worktrees/proj/seed-abc'`, when agent calls `edit` from `/worktrees/proj/seed-xyz`, then a `guardrail-veto` event is written to the store with `expectedCwd` and `actualCwd` fields.
- Given `guardrailConfig.mode: 'auto-correct'`, when agent calls `bash` with `cmd: 'git status'` from wrong directory, then the command is rewritten to `cd /expected && git status`.
- Guardrail hook adds <5ms overhead per tool call (measured via `console.time` in dev mode).

[depends: none]

---

#### TRD-009-001-TEST: Guardrail Hook Tests [2h]
[verifies TRD-009-001] [depends: TRD-009-001]

Write vitest tests for:
- Veto mode: mismatched cwd → guardrail-veto event written
- Veto mode: matching cwd → no event, tool executes normally
- Auto-correct mode: mismatched cwd → command rewritten with cd prefix
- Auto-correct mode: matching cwd → no rewrite
- Multiple consecutive vetoes → one event per veto, tool continues blocking
- Different tool types (edit, write, bash) all trigger guardrail

---

#### TRD-009-002: Phase-Start Event Emission [2h]
[satisfies FR-2]

**Validates PRD ACs:** AC-2

In `pipeline-executor.ts`, before calling `runWithPiSdk()` for any phase, call `store.logEvent('phase-start', { seedId, phase, worktreePath, expectedWorktree: worktreePath, model, runId, targetBranch, timestamp: new Date().toISOString() })`.

**Implementation ACs:**
- Given a pipeline running phases `fix → test → finalize`, when each phase starts, then a `phase-start` event with correct phase name is written before the agent prompt is sent.
- Given a `phase-start` event in the store, `SELECT * FROM events WHERE event_type = 'phase-start' AND details->>'$.runId' = ?` returns the event with all required fields non-null.

[depends: none]

---

#### TRD-009-003: Heartbeat Event System [4h]
[satisfies FR-3]

**Validates PRD ACs:** AC-3

In `pipeline-executor.ts`, after starting a Pi SDK session, set up a `setInterval` that fires every 60 seconds. On each fire:
1. Read session stats via `session.getSessionStats()` (turns, cost, tokens)
2. Track `filesChanged` via tool_execution_start events (accumulate file paths from edit/write tools)
3. Write a `heartbeat` event to the store

**Schema for heartbeat event:**
```typescript
{
  event_type: 'heartbeat',
  details: {
    seedId: string,
    phase: string,
    runId: string,
    turns: number,
    toolCalls: number,
    toolBreakdown: Record<string, number>,
    filesChanged: string[],
    costUsd: number,
    tokensIn: number,
    tokensOut: number,
    lastFileEdited: string | null,
    lastActivity: string, // ISO 8601
  }
}
```

**Implementation ACs:**
- Given an active `fix` phase running for >60 seconds, when heartbeats fire, then each `heartbeat` event has `turns >= 0`, `costUsd >= 0`, and `filesChanged` populated.
- Given a `heartbeat` event, all tracked fields (turns, toolCalls, costUsd, tokensIn, tokensOut) are non-null.
- `setInterval` is cleared when phase ends (success or failure).
- Heartbeat writing is non-blocking: if DB write fails, log error and continue.

[depends: TRD-009-001, TRD-009-002]

---

#### TRD-009-003-TEST: Heartbeat Tests [2h]
[verifies TRD-009-003] [depends: TRD-009-003]

Write vitest tests for:
- Heartbeat fires at 60s interval (mock `setInterval`, advance time)
- `toolBreakdown` correctly aggregates tool call counts
- `filesChanged` accumulates file paths from edit/write tools
- `lastFileEdited` tracks most recent edit/write target
- Interval cleared on phase end
- DB write failure in heartbeat does not crash agent session

---

### Phase 2: Activity Logging

#### TRD-009-004: ACTIVITY_LOG.json Generation [4h]
[satisfies FR-4]

**Validates PRD ACs:** AC-4, AC-7

In `agent-worker-finalize.ts`, before staging changes:
1. Query all events for this run from the store (phase-start, heartbeat, phase-end, guardrail-veto)
2. Aggregate into the `ACTIVITY_LOG.json` schema from the PRD
3. Write `ACTIVITY_LOG.json` to worktree root

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
      editsByFile: Record<string, number>,
      commandsRun: string[],
      verdict: "pass" | "fail" | "skipped" | "unknown",
    }
  ],
  totalCostUsd: number,
  totalTurns: number,
  totalToolCalls: number,
  filesChangedTotal: string[],
  commits: [{ hash: string, message: string, timestamp: string }],
  warnings: string[],
  retryLoops: number,
}
```

Also update `FINALIZE_REPORT.md` template to include `git diff --stat` output.

**Implementation ACs:**
- Given a completed pipeline for a seed, when finalize commits, then `ACTIVITY_LOG.json` is present in the commit with all required fields populated.
- Given `git show HEAD:ACTIVITY_LOG.json`, the operator can see all phases, costs, and file changes without querying the DB.
- `FINALIZE_REPORT.md` includes `git diff --stat` output section.

[depends: TRD-009-003]

---

#### TRD-009-004-TEST: ACTIVITY_LOG Tests [2h]
[verifies TRD-009-004] [depends: TRD-009-004]

Write vitest tests for:
- ACTIVITY_LOG.json generated with correct schema
- `filesChangedTotal` deduplicates files across phases
- `editsByFile` correctly counts edits per file
- `totalCostUsd` equals sum of phase costs
- `warnings` array populated from guardrail vetoes
- `retryLoops` counts phase retries correctly
- JSON is valid and parseable

---

### Phase 3: Worktree Safety

#### TRD-009-005: Stale Worktree Detection and Auto-Rebase [3h]
[satisfies FR-5]

**Validates PRD ACs:** AC-5

In `dispatcher.ts`, before spawning a worker for an existing worktree (retry case):
1. Get the worktree's current base commit via `vcs.getBaseCommit(worktreePath)`
2. Get `origin/{target}` commit via `vcs.resolveRef(worktreePath, 'origin/{target}')`
3. If they differ → worktree is stale:
   - Attempt auto-rebase via `vcs.rebase(worktreePath, 'origin/{target}')`
   - On success: log `worktree-rebased` event with `{ seedId, from: localBase, to: remoteBase, runId }`
   - On failure: log `worktree-rebase-failed` event, fail the dispatch with clear message

**For fresh worktrees (first dispatch):** skip staleness check.

**Implementation ACs:**
- Given a worktree at commit `abc123` where `origin/dev` is at `def456`, when dispatch starts, then the worktree is auto-rebased before the `fix` phase and a `worktree-rebased` event is written.
- Given a rebase conflict, when it occurs, then a `worktree-rebase-failed` event is written and the pipeline fails with message "Stale worktree rebase failed: [git error]".
- Given a fresh worktree (no prior commits), no staleness check or rebase is attempted.

[depends: none]

---

#### TRD-009-005-TEST: Stale Worktree Tests [2h]
[verifies TRD-009-005] [depends: TRD-009-005]

Write vitest tests for:
- Stale worktree → auto-rebase triggered
- Stale worktree with rebase conflict → `worktree-rebase-failed` event, dispatch fails
- Fresh worktree → no staleness check attempted
- Already-rebased worktree → no rebase attempted
- `worktree-rebased` event contains correct `from` and `to` commit SHAs

---

#### TRD-009-006: Rebase-Before-Finalize [3h]
[satisfies FR-6]

**Validates PRD ACs:** AC-6

In `agent-worker-finalize.ts`, at the start of finalize phase:
1. Check if `origin/{target}` has moved since the test phase completed
2. If moved → attempt auto-rebase before any git operations
3. Log `worktree-rebased` event on success
4. If rebase needed and fails → fail with clear message

This prevents the "target branch drifted" finalize failures observed in `foreman-fc1ed`.

**Implementation ACs:**
- Given a finalize phase where `origin/dev` has moved since the test phase, when finalize starts, then the worktree is rebased before any commit is made.
- After auto-rebase, finalize proceeds normally and Target Integration is marked SUCCESS.
- If rebase fails, finalize fails with message mentioning the drift and the git error.

[depends: TRD-009-005]

---

#### TRD-009-006-TEST: Rebase-Before-Finalize Tests [2h]
[verifies TRD-009-006] [depends: TRD-009-006]

Write vitest tests for:
- Finalize with stale target → auto-rebase before staging
- Finalize with up-to-date target → no rebase attempted
- Finalize with rebase conflict → graceful failure with clear message
- Finalize proceeds to SUCCESS after auto-rebase

---

### Phase 4: Integration

#### TRD-009-007: End-to-End Integration Tests [4h]
[satisfies all FRs]

**Validates PRD ACs:** AC-1 through AC-7

Write integration tests that simulate a complete pipeline run:
1. Dispatch a bead → verify `phase-start` event written
2. Agent runs → verify heartbeat events fire at interval
3. Guardrail veto fires (if agent goes to wrong dir) → verify event
4. Complete pipeline → verify `ACTIVITY_LOG.json` in commit
5. Retry with stale worktree → verify auto-rebase
6. Target drift during test → verify finalize rebase

Use mocked VCS backend and in-memory store for isolation.

**Implementation ACs:**
- All 7 acceptance criteria from PRD are verifiable via test assertions.
- Integration tests run in <30 seconds total (mock external calls).

[depends: TRD-009-001, TRD-009-002, TRD-009-003, TRD-009-004, TRD-009-005, TRD-009-006]

---

## File Inventory

| File | Change |
|---|---|
| `src/orchestrator/pi-sdk-runner.ts` | Add guardrailConfig option and tool execution hook |
| `src/orchestrator/pipeline-executor.ts` | Add phase-start, heartbeat, and file tracking |
| `src/orchestrator/agent-worker-finalize.ts` | Add ACTIVITY_LOG.json generation, finalize rebase |
| `src/orchestrator/dispatcher.ts` | Add stale worktree detection and auto-rebase |
| `src/lib/store.ts` | Add new event types to EventType union |
| `src/orchestrator/__tests__/guardrail.test.ts` | New: guardrail hook tests |
| `src/orchestrator/__tests__/heartbeat.test.ts` | New: heartbeat tests |
| `src/orchestrator/__tests__/activity-log.test.ts` | New: activity log tests |
| `src/orchestrator/__tests__/stale-worktree.test.ts` | New: stale worktree tests |
| `src/orchestrator/__tests__/finalize-rebase.test.ts` | New: finalize rebase tests |

---

## Dependencies

```
TRD-009-001: Guardrail Hook ─────────────┐
  └─ TRD-009-001-TEST                   │
                                         │
TRD-009-002: Phase-Start ────────────────┤
  └─ TRD-009-003: Heartbeat             │
        └─ TRD-009-003-TEST             │
              └─ TRD-009-004: ACTIVITY_LOG
                    └─ TRD-009-004-TEST │

TRD-009-005: Stale Worktree ─────────────┤
  └─ TRD-009-005-TEST                   │
        └─ TRD-009-006: Finalize Rebase  │
              └─ TRD-009-006-TEST        │

All phases ───────────────────────────────┴─ TRD-009-007: Integration Tests
```

---

## Open Questions (from PRD)

| Question | Resolution |
|---|---|
| Guardrail auto-correct vs. veto? | Default to `mode: 'auto-correct'`; allow workflow config override per phase |
| Configurable heartbeat interval? | Add `heartbeatIntervalSeconds` to workflow YAML, default 60 |
| ACTIVITY_LOG.json vs FINALIZE_REPORT.md? | Both exist; JSON is machine-readable, REPORT is human-readable |
| Auto-rebase or operator approval? | Automatic with event logging; add `--no-auto-rebase` dispatch flag for opt-out |

---

## Verification Matrix

| FR | Requirement | Implementation | Test | Verified |
|---|---|---|---|---|
| FR-1 | Directory guardrail | TRD-009-001 | TRD-009-001-TEST | ☐ |
| FR-2 | Phase-start events | TRD-009-002 | Implicit in TRD-009-007 | ☐ |
| FR-3 | Heartbeat events | TRD-009-003 | TRD-009-003-TEST | ☐ |
| FR-4 | ACTIVITY_LOG.json | TRD-009-004 | TRD-009-004-TEST | ☐ |
| FR-5 | Stale worktree rebase | TRD-009-005 | TRD-009-005-TEST | ☐ |
| FR-6 | Finalize rebase | TRD-009-006 | TRD-009-006-TEST | ☐ |
| All | End-to-end | TRD-009-007 | TRD-009-007 | ☐ |

---

## Rollout Plan

**Sprint 1:** TRD-009-001 through TRD-009-003 (guardrail + events)
**Sprint 2:** TRD-009-004 through TRD-009-006 (activity log + worktree safety)
**Sprint 3:** TRD-009-007 (integration tests) + dogfood in foreman itself

**Rollback:** Each feature is independently deployable. If FR-1 guardrail causes issues, disable via `guardrailConfig: undefined` until fixed.
