> ⚠️ Historical Context
> This document describes Foreman's beads-first architecture, which has been
> superseded by native task management (TRD-2026-006). Some instructions,
> configurations, or comparisons in this document may no longer reflect
> current behavior.

# TRD-2026-005: Mid-Pipeline Rebase

**Document ID:** TRD-2026-005
**Version:** 1.0
**Status:** Draft
**Date:** 2026-03-29
**PRD Reference:** PRD-2026-005 v1.0
**Author:** Tech Lead (AI-assisted)

---

## Version History

| Version | Date       | Author    | Changes       |
|---------|------------|-----------|---------------|
| 1.0     | 2026-03-29 | Tech Lead | Initial draft: 19 implementation tasks + 19 paired test tasks (38 total). 7 phases across event-driven pipeline foundation + rebase feature delivery. Full AC traceability for 18 PRD requirements / 48 acceptance criteria. |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Architecture Decision](#2-architecture-decision)
3. [System Architecture](#3-system-architecture)
4. [Data Architecture](#4-data-architecture)
5. [Master Task List](#5-master-task-list)
6. [Sprint Planning](#6-sprint-planning)
7. [Quality Requirements](#7-quality-requirements)
8. [Acceptance Criteria Traceability](#8-acceptance-criteria-traceability)
9. [Open Questions](#9-open-questions)
10. [Design Readiness Scorecard](#10-design-readiness-scorecard)

---

## 1. Executive Summary

This TRD translates PRD-2026-005 into an implementable plan for inserting a mid-pipeline rebase step after a configurable phase, surfacing merge conflicts before QA runs and enabling in-place resolution by the troubleshooter agent. The feature spans 7 delivery phases over approximately 8 working days, producing 19 implementation tasks and 19 paired verification tasks (38 total).

**Key architectural changes:**

- New `PipelineEventBus` typed event emitter (`src/orchestrator/pipeline-events.ts`) wrapping Node `EventEmitter` with a `safeEmit` pattern that routes handler errors to `pipeline:error` without crashing the executor.
- Refactored `pipeline-executor.ts` emitting structured `PipelineEvent` values at each phase lifecycle boundary, replacing the existing `onPipelineComplete`/`onPipelineFailure` callbacks with registered event handlers.
- New `RebaseHook` class (`src/orchestrator/rebase-hook.ts`) that registers on `phase:complete` events, executes `vcs.rebase()` when `workflow.rebaseAfterPhase` matches the completed phase, handles clean and conflict branches, sends `rebase-context` mail to QA, and escalates to the troubleshooter on conflict.
- SQLite migration adding `rebase_conflict` and `rebase_resolving` to the `runs.status` field.
- Workflow YAML schema extension adding `rebaseAfterPhase` (optional string) and `rebaseTarget` (optional string) top-level keys with phase-name validation in `workflow-loader.ts`.
- Observable pipeline states surfaced in `foreman status`, `foreman dashboard`, and `foreman inbox --type`.

**Existing VcsBackend interface is complete.** `rebase()`, `getConflictingFiles()`, and `abortRebase()` already exist in `src/lib/vcs/interface.ts` (delivered in TRD-2026-004). No new VcsBackend methods are required.

**Shared worktree mode (REQ-010, REQ-011) is deferred to v2** per the PRD's Could/Won't classification. These requirements are excluded from this TRD's task list.

---

## 2. Architecture Decision

### 2.1 Options Considered

**Option A — Minimal callback in pipeline-executor**

Add a `onPhaseComplete` callback to the existing `PipelineExecutorConfig` interface. The rebase logic is implemented inline in `pipeline-executor.ts` or in a helper called directly from the executor's phase loop.

*Rejected.* Pipeline executor accumulates responsibility. Rebase logic is tightly coupled to the executor, making it difficult to test the rebase pathway without running a full pipeline. Every future pipeline hook (e.g., cost threshold checks, phase-level notifications) requires modifying `pipeline-executor.ts` again.

**Option B — RebaseHook class with direct injection**

Define a `RebaseHook` class that is passed a reference to the pipeline executor's internals. The executor calls `rebaseHook?.afterPhase(phase, worktreePath)` at the appropriate point.

*Not chosen.* Better than Option A (hook is independently testable), but still imperative coupling. Adding a second hook type requires another `hook?.afterPhase` call site in the executor. Doesn't enable future hooks without further modifying the executor.

**Option C — Event-Driven Pipeline (Chosen)**

Refactor `pipeline-executor.ts` to emit typed `PipelineEvent` values via a `PipelineEventBus`. All handlers (including the rebase hook, the existing `onPipelineComplete`/`onPipelineFailure` callbacks, future hooks) register as event listeners. The executor emits; it does not call anything directly.

*Chosen.* Matches the direction already established by `onPipelineComplete`/`onPipelineFailure` callbacks in `agent-worker.ts`. Enables all future pipeline hooks to register without touching `pipeline-executor.ts`. Each handler is independently testable. `safeEmit` ensures handler errors never crash the executor.

### 2.2 Option C Design Constraints

- The sequential phase loop in `pipeline-executor.ts` is **unchanged**. Events are emitted at existing lifecycle boundaries; no new asynchronous dispatch is introduced.
- `safeEmit` catches all synchronous and asynchronous handler errors and routes them to a `pipeline:error` event. The pipeline executor never `await`s handler side effects directly.
- The existing `onPipelineComplete` and `onPipelineFailure` callback parameters on `pipeline-executor.ts` are replaced by registered `pipeline:complete` and `pipeline:fail` event handlers in `agent-worker.ts`. The public API of `agent-worker.ts` is unchanged.

---

## 3. System Architecture

### 3.1 Component Diagram

```
foreman run
  |
  +-- Dispatcher
  |     |-- VcsBackend (from TRD-2026-004)
  |     +-- AgentWorker (spawned process)
  |           |
  |           +-- PipelineEventBus (new)
  |           |     |-- emit('phase:start', ...)
  |           |     |-- emit('phase:complete', ...)
  |           |     |-- emit('pipeline:complete', ...)
  |           |     |-- emit('pipeline:fail', ...)
  |           |
  |           +-- PipelineExecutor (refactored)
  |           |     |-- Sequential phase loop (unchanged)
  |           |     |-- Emits events via PipelineEventBus
  |           |     |-- No direct rebase logic
  |           |
  |           +-- RebaseHook (new)
  |                 |-- Registers on: phase:complete
  |                 |-- Checks: workflow.rebaseAfterPhase
  |                 |-- Calls: vcs.rebase(target)
  |                 |-- Clean path: sends rebase-context mail to QA
  |                 |-- Conflict path:
  |                 |     |-- vcs.getConflictingFiles()
  |                 |     |-- store.updateRunStatus('rebase_conflict')
  |                 |     |-- emit('rebase:conflict', conflictingFiles)
  |                 |     +-- sends mail to troubleshooter
  |                 |
  |                 +-- Registers on: rebase:resolved
  |                       |-- Re-dispatches developer phase
  |                       +-- Forwards EXPLORER_REPORT.md
  |
  +-- SQLite Store
  |     |-- runs.status: + rebase_conflict, rebase_resolving
  |
  +-- foreman status / dashboard / inbox
        |-- Display new status values
```

### 3.2 Event Taxonomy

```typescript
type PipelineEvent =
  | { type: 'phase:start';       runId: string; phase: string; worktreePath: string }
  | { type: 'phase:complete';    runId: string; phase: string; worktreePath: string; cost: number }
  | { type: 'phase:fail';        runId: string; phase: string; error: string; retryable: boolean }
  | { type: 'rebase:start';      runId: string; phase: string; target: string }
  | { type: 'rebase:clean';      runId: string; phase: string; upstreamCommits: number; changedFiles: string[] }
  | { type: 'rebase:conflict';   runId: string; phase: string; conflictingFiles: string[] }
  | { type: 'rebase:resolved';   runId: string; resumePhase: string }
  | { type: 'pipeline:complete'; runId: string; status: string }
  | { type: 'pipeline:fail';     runId: string; error: string }
  | { type: 'pipeline:error';    runId: string; handlerError: Error; sourceEvent: string }
```

### 3.3 Data Flow: Clean Rebase Path

```
1. PipelineExecutor finishes developer phase
2. emit('phase:complete', { phase: 'developer', ... })
3. RebaseHook.onPhaseComplete() fires
4.   -- workflow.rebaseAfterPhase === 'developer' -> proceed
5.   -- emit('rebase:start', { target })
6.   -- vcs.rebase(worktreePath, target)            [VcsBackend call]
7.   -- RebaseResult.hasConflicts === false
8.   -- emit('rebase:clean', { upstreamCommits, changedFiles })
9.   -- if upstreamCommits > 0: send rebase-context mail to QA
10.  -- hook resolves (no status change)
11. PipelineExecutor dispatches QA phase
```

### 3.4 Data Flow: Conflict Rebase Path

```
1. PipelineExecutor finishes developer phase
2. emit('phase:complete', { phase: 'developer', ... })
3. RebaseHook.onPhaseComplete() fires
4.   -- vcs.rebase(worktreePath, target)
5.   -- RebaseResult.hasConflicts === true
6.   -- vcs.getConflictingFiles(worktreePath)
7.   -- store.updateRunStatus(runId, 'rebase_conflict')
8.   -- emit('rebase:conflict', { conflictingFiles })
9.   -- send mail to troubleshooter: worktreePath, conflictingFiles, target, resumePhase:'developer'
10.  -- store.updateRunStatus(runId, 'rebase_resolving')
11.  -- PipelineExecutor suspends (no next phase dispatched)

--- troubleshooter resolves ---

12. Troubleshooter signals resolution via mail to pipeline
13. RebaseHook.onRebaseResolved() fires
14.  -- emit('rebase:resolved', { resumePhase: 'developer' })
15.  -- Forward EXPLORER_REPORT.md to developer mail
16.  -- Re-run developer phase from resolved worktree state
17.  -- store.updateRunStatus(runId, 'running')

--- second conflict at same point ---

18. If developer re-run fails QA a second time:
19.   -- run transitions to 'failed' (no second troubleshooter escalation)
```

### 3.5 Module Structure (New Files)

```
src/orchestrator/
  pipeline-events.ts          -- PipelineEventBus class, PipelineEvent union type, safeEmit
  rebase-hook.ts              -- RebaseHook class; registers phase:complete and rebase:resolved handlers
  pipeline-executor.ts        -- (modified) emits events; removes onPipelineComplete/onPipelineFailure callbacks
  agent-worker.ts             -- (modified) registers pipeline:complete, pipeline:fail as event handlers

src/orchestrator/__tests__/
  pipeline-events.test.ts     -- PipelineEventBus unit tests
  rebase-hook.test.ts         -- RebaseHook clean and conflict path tests
  rebase-hook-conflict.test.ts
  rebase-hook-escalation.test.ts
  rebase-hook-resume.test.ts
  pipeline-executor-events.test.ts
  rebase-integration.test.ts
  rebase-conflict-integration.test.ts
  rebase-regression.test.ts

src/lib/
  workflow-loader.ts          -- (modified) rebaseAfterPhase, rebaseTarget keys + validation
  store.ts                    -- (modified) SQLite migration for new status values

src/cli/commands/
  status.ts                   -- (modified) display rebase_conflict / rebase_resolving labels
  dashboard.ts                -- (modified) amber/blue row indicators
  inbox.ts                    -- (modified) --type filter support for rebase-context, rebase-conflict

src/defaults/workflows/
  default.yaml                -- (modified) add commented-out rebaseAfterPhase example
```

### 3.6 VcsBackend Compatibility

The existing `VcsBackend` interface (TRD-2026-004) provides all necessary methods:

| Method | Used By | Purpose |
|--------|---------|---------|
| `rebase(worktreePath, onto)` | RebaseHook | Execute mid-pipeline rebase |
| `getConflictingFiles(worktreePath)` | RebaseHook | Enumerate files on conflict |
| `abortRebase(worktreePath)` | RebaseHook (permanent failure path) | Clean up aborted rebase state |

No new `VcsBackend` methods are required. This satisfies REQ-006.

---

## 4. Data Architecture

### 4.1 WorkflowConfig Extension (`src/lib/workflow-loader.ts`)

```typescript
export interface WorkflowPhaseConfig {
  name: string;
  prompt: string;
  models?: { default?: string; P0?: string };
  maxTurns?: number;
  artifact?: string;
  skipIfArtifact?: string;
  verdict?: boolean;
  retryWith?: string;
  retryOnFail?: number;
  mail?: { onStart?: boolean; onComplete?: boolean; onFail?: string; forwardArtifactTo?: string };
}

export interface WorkflowConfig {
  name: string;
  vcs?: 'git' | 'jujutsu' | 'auto';       // from TRD-2026-004
  rebaseAfterPhase?: string;                // NEW: phase name after which mid-pipeline rebase fires
  rebaseTarget?: string;                    // NEW: remote ref; defaults to origin/<defaultBranch>
  setup?: WorkflowSetupStep[];
  setupCache?: WorkflowSetupCache;
  phases: WorkflowPhaseConfig[];
}
```

**Validation rule:** If `rebaseAfterPhase` is present, `workflow-loader.ts` must verify the named phase exists in `phases`. Throws with message: `"rebaseAfterPhase names unknown phase '<name>'. Valid phases: <list>."`.

### 4.2 SQLite Migration (`src/lib/store.ts`)

**Migration:** Add `rebase_conflict` and `rebase_resolving` to the `runs.status` check constraint.

```sql
-- Migration: add rebase status values to runs table
ALTER TABLE runs RENAME TO runs_old;

CREATE TABLE runs (
  id TEXT PRIMARY KEY,
  seedId TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN (
    'pending', 'running', 'completed', 'failed', 'stuck', 'merged',
    'conflict', 'test-failed', 'pr-created', 'reset',
    'rebase_conflict',    -- NEW: mid-pipeline rebase hit unresolvable conflicts
    'rebase_resolving'    -- NEW: troubleshooter is actively resolving
  )),
  -- ... all other columns preserved unchanged
);

INSERT INTO runs SELECT * FROM runs_old;
DROP TABLE runs_old;
```

**TypeScript Run type extension:**

```typescript
export type RunStatus =
  | 'pending' | 'running' | 'completed' | 'failed' | 'stuck'
  | 'merged' | 'conflict' | 'test-failed' | 'pr-created' | 'reset'
  | 'rebase_conflict'    // NEW
  | 'rebase_resolving';  // NEW
```

### 4.3 Agent Mail: rebase-context Payload

New mail type sent from `RebaseHook` to the QA agent after a clean rebase with upstream changes:

```typescript
interface RebaseContextMail {
  type: 'rebase-context';
  from: 'pipeline';
  to: 'qa';
  subject: `[rebase-context] ${upstreamCommits} upstream commit(s) integrated before QA`;
  body: {
    rebaseTarget: string;            // e.g. 'origin/dev'
    upstreamCommits: number;
    changedFiles: string[];          // capped at 100 entries
    truncated: boolean;              // true if > 100 files
    note: string;                    // "The worktree has been rebased onto <target>. Review upstream changes for test impact."
  };
}
```

### 4.4 Agent Mail: rebase-conflict Payload

Mail sent from `RebaseHook` to the troubleshooter agent on conflict:

```typescript
interface RebaseConflictMail {
  type: 'rebase-conflict';
  from: 'pipeline';
  to: 'troubleshooter';
  subject: `[rebase-conflict] ${conflictCount} files conflicted in run ${runId}`;
  body: {
    runId: string;
    worktreePath: string;
    rebaseTarget: string;
    conflictingFiles: string[];
    resumePhase: 'developer';
    note: string;   // "Resolve all conflicts and reply to resume the pipeline from the developer phase."
  };
}
```

### 4.5 Default Workflow YAML Update (`src/defaults/workflows/default.yaml`)

```yaml
# Mid-pipeline rebase (opt-in). Uncomment to activate.
# rebaseAfterPhase: developer    # Rebase onto target after developer phase, before QA
# rebaseTarget: origin/dev       # Defaults to origin/<defaultBranch> when absent
```

No behavior change when lines remain commented.

---

## 5. Master Task List

### Legend

- `[satisfies REQ-NNN]` — links to PRD requirement
- `Validates PRD ACs: AC-NNN-M` — specific acceptance criteria covered
- `[verifies TRD-NNN]` — test task verifying an implementation task
- `[depends: TRD-NNN]` — task dependency
- Checkbox: ( ) not started, (>) in progress, (x) completed

---

### Phase 0: Event-Driven Pipeline Foundation

---

#### TRD-001: PipelineEventBus
`[satisfies ARCH]`
**File:** `src/orchestrator/pipeline-events.ts`
**Estimate:** 3h
**Depends:** None

Define the `PipelineEvent` discriminated union type covering all 9 event variants in section 3.2. Implement `PipelineEventBus` class wrapping Node `EventEmitter` with:
- `emit<T extends PipelineEvent>(event: T): void` — typed emit
- `on<T extends PipelineEvent['type']>(type: T, handler: (event: Extract<PipelineEvent, {type: T}>) => void | Promise<void>): void` — typed listener registration
- `safeEmit<T extends PipelineEvent>(event: T): void` — catches all synchronous and asynchronous handler errors and re-emits them as `pipeline:error` events, never propagating to the caller

**Implementation ACs:**
- ( ) AC-I-001-1: Given `PipelineEventBus`, when compiled, then `npx tsc --noEmit` produces zero errors.
- ( ) AC-I-001-2: Given a handler registered for `phase:complete`, when `safeEmit({ type: 'phase:complete', ... })` is called, then the handler receives a correctly typed event object.
- ( ) AC-I-001-3: Given a handler that throws synchronously, when `safeEmit` calls it, then the error is caught and emitted as `pipeline:error` without propagating to the caller.
- ( ) AC-I-001-4: Given a handler that returns a rejected Promise, when `safeEmit` calls it, then the rejection is caught and emitted as `pipeline:error`.

---

#### TRD-001-TEST: Verify PipelineEventBus
`[verifies TRD-001] [satisfies ARCH] [depends: TRD-001]`
**File:** `src/orchestrator/__tests__/pipeline-events.test.ts`
**Estimate:** 2h

- ( ) AC-T-001-1: Given a registered `phase:complete` handler, when emitted, then handler receives the full event object with all fields.
- ( ) AC-T-001-2: Given a synchronously throwing handler, when `safeEmit` fires, then a `pipeline:error` event is emitted and the original emit call does not throw.
- ( ) AC-T-001-3: Given a rejected async handler, when `safeEmit` fires, then `pipeline:error` is emitted (not an unhandled promise rejection).
- ( ) AC-T-001-4: Given all 9 `PipelineEvent` variants, when each is emitted and received, then TypeScript narrows the type correctly in each handler.

---

#### TRD-002: Refactor pipeline-executor to emit events
`[satisfies ARCH, REQ-017]`
**File:** `src/orchestrator/pipeline-executor.ts`
**Estimate:** 4h
**Depends:** TRD-001

Modify `pipeline-executor.ts` to:
- Accept a `PipelineEventBus` instance in its constructor/config (replacing the `onPipelineComplete`/`onPipelineFailure` callback fields).
- Emit `phase:start` before each phase runs.
- Emit `phase:complete` after each phase returns success.
- Emit `phase:fail` when a phase fails (including retry-exhaustion failures).
- Emit `pipeline:complete` after the final phase succeeds.
- Emit `pipeline:fail` on unrecoverable pipeline failure.
- The sequential phase loop logic is otherwise unchanged. No rebase logic introduced here.

**Implementation ACs:**
- ( ) AC-I-002-1: Given a 3-phase pipeline run, when all phases succeed, then events are emitted in order: `phase:start`, `phase:complete` (×3), `pipeline:complete`.
- ( ) AC-I-002-2: Given a phase that fails, when emitted, then `phase:fail` carries `retryable: true` for transient errors and `retryable: false` for permanent failures.
- ( ) AC-I-002-3: Given the refactored executor, when compiled, then no `onPipelineComplete` or `onPipelineFailure` fields exist on the config type.
- ( ) AC-I-002-4: Given `safeEmit` is used for all events, when a handler throws, then the executor does not crash and the next phase dispatches normally.

---

#### TRD-002-TEST: Verify pipeline-executor event emission
`[verifies TRD-002] [satisfies ARCH, REQ-017] [depends: TRD-002]`
**File:** `src/orchestrator/__tests__/pipeline-executor-events.test.ts`
**Estimate:** 3h

- ( ) AC-T-002-1: Given a mock 2-phase pipeline, when run, then `phase:start` fires before each phase and `phase:complete` fires after.
- ( ) AC-T-002-2: Given a phase mock that throws, when run, then `phase:fail` is emitted with the error message and the `pipeline:fail` event follows.
- ( ) AC-T-002-3: Given the existing pipeline-executor test suite (if any), when run against the refactored executor, then all existing tests pass without modification.
- ( ) AC-T-002-4: Given a handler registered on `phase:complete` that throws, when a phase completes, then the executor emits the next `phase:start` normally (handler error does not block execution).

---

### Phase A: Workflow YAML Schema

---

#### TRD-003: workflow-loader.ts schema update
`[satisfies REQ-007, REQ-008]`
**File:** `src/lib/workflow-loader.ts`
**Estimate:** 2h
**Depends:** None

Extend `WorkflowConfig` and `WorkflowPhaseConfig` with `rebaseAfterPhase?: string` and `rebaseTarget?: string` as defined in section 4.1. Add post-parse validation: if `rebaseAfterPhase` is present, verify the named phase appears in `phases`; throw a descriptive error if not. Parse `rebaseTarget` as-is (no URL validation required; arbitrary remote ref strings are valid).

**Validates PRD ACs:** AC-007-1, AC-007-2, AC-007-3, AC-008-1, AC-008-2

**Implementation ACs:**
- ( ) AC-I-003-1: Given a workflow YAML with `rebaseAfterPhase: developer`, when loaded, then `config.rebaseAfterPhase === 'developer'`.
- ( ) AC-I-003-2: Given a workflow YAML with no `rebaseAfterPhase`, when loaded, then `config.rebaseAfterPhase` is `undefined`.
- ( ) AC-I-003-3: Given `rebaseAfterPhase: nonexistent-phase`, when loaded, then `workflow-loader.ts` throws with message containing `"rebaseAfterPhase names unknown phase"` and the valid phase names.
- ( ) AC-I-003-4: Given a workflow with `rebaseTarget: origin/main`, when loaded, then `config.rebaseTarget === 'origin/main'`.
- ( ) AC-I-003-5: Given no `rebaseTarget`, when loaded, then `config.rebaseTarget` is `undefined` (caller resolves default at runtime via `VcsBackend.detectDefaultBranch()`).

---

#### TRD-003-TEST: Verify workflow-loader changes
`[verifies TRD-003] [satisfies REQ-007, REQ-008] [depends: TRD-003]`
**File:** `src/lib/__tests__/workflow-loader-rebase.test.ts`
**Estimate:** 2h

- ( ) AC-T-003-1: Given valid YAML with `rebaseAfterPhase: developer` (and `developer` in phases), when loaded, then `config.rebaseAfterPhase === 'developer'`.
- ( ) AC-T-003-2: Given YAML without `rebaseAfterPhase`, when loaded, then `config.rebaseAfterPhase` is `undefined`.
- ( ) AC-T-003-3: Given `rebaseAfterPhase: bogus` where `bogus` is not in phases, when loaded, then an error is thrown matching `/rebaseAfterPhase names unknown phase/`.
- ( ) AC-T-003-4: Given `rebaseTarget: origin/feature-branch`, when loaded, then `config.rebaseTarget === 'origin/feature-branch'`.
- ( ) AC-T-003-5: Given YAML with no `rebaseTarget`, when loaded, then `config.rebaseTarget` is `undefined`.

---

#### TRD-004: Default workflow YAML update
`[satisfies REQ-009]`
**File:** `src/defaults/workflows/default.yaml`
**Estimate:** 0.5h
**Depends:** TRD-003

Add the opt-in comment block shown in section 4.5. The two lines are commented out. No functional behavior change. Document that uncommenting `rebaseAfterPhase: developer` activates mid-pipeline rebase on subsequent runs.

**Validates PRD ACs:** AC-009-1, AC-009-2

**Implementation ACs:**
- ( ) AC-I-004-1: Given the default workflow YAML as-is (comments present, keys absent), when a pipeline runs, then no rebase step fires.
- ( ) AC-I-004-2: Given an operator uncomments both keys, when the workflow is loaded, then `config.rebaseAfterPhase === 'developer'` and `config.rebaseTarget === 'origin/dev'`.

---

#### TRD-004-TEST: Verify default workflow unchanged
`[verifies TRD-004] [satisfies REQ-009] [depends: TRD-004]`
**File:** `src/orchestrator/__tests__/rebase-regression.test.ts` (partial)
**Estimate:** 0.5h

- ( ) AC-T-004-1: Given the default workflow loaded without modification, when `config.rebaseAfterPhase` is checked, then it is `undefined`.
- ( ) AC-T-004-2: Given a pipeline run using the default workflow, when all phases execute, then no `rebase:start` event is emitted.

---

### Phase B: SQLite Schema Migration

---

#### TRD-005: store.ts migration — new status values
`[satisfies REQ-012]`
**File:** `src/lib/store.ts`
**Estimate:** 2h
**Depends:** None

Add `rebase_conflict` and `rebase_resolving` to the SQLite `runs.status` check constraint via a versioned migration. Extend the `RunStatus` TypeScript union type. Update all `switch`/`case` and `if`/`else` status handlers in `store.ts` to handle the new values (at minimum: a `default` case or explicit handling). Ensure `updateRunStatus()` accepts both new values.

**Validates PRD ACs:** AC-012-1, AC-012-2, AC-012-3

**Implementation ACs:**
- ( ) AC-I-005-1: Given a run record, when `updateRunStatus(runId, 'rebase_conflict')` is called, then the record's status field is `'rebase_conflict'` without a SQLite constraint error.
- ( ) AC-I-005-2: Given a run record, when `updateRunStatus(runId, 'rebase_resolving')` is called, then the record's status field is `'rebase_resolving'` without a SQLite constraint error.
- ( ) AC-I-005-3: Given the migration applied to an existing database with existing runs, when queried, then all pre-existing runs retain their original status values.
- ( ) AC-I-005-4: Given the `RunStatus` type, when `'rebase_conflict'` and `'rebase_resolving'` are passed to `updateRunStatus()`, then TypeScript accepts them without type errors.

---

#### TRD-005-TEST: Verify status migration
`[verifies TRD-005] [satisfies REQ-012] [depends: TRD-005]`
**File:** `src/lib/__tests__/store-rebase-status.test.ts`
**Estimate:** 1h

- ( ) AC-T-005-1: Given a fresh in-memory SQLite database with migration applied, when `updateRunStatus(id, 'rebase_conflict')` is called, then `getRun(id).status === 'rebase_conflict'`.
- ( ) AC-T-005-2: Given the same database, when `updateRunStatus(id, 'rebase_resolving')` is called, then `getRun(id).status === 'rebase_resolving'`.
- ( ) AC-T-005-3: Given a database with pre-existing `running` status runs, when migration is applied, then those rows remain `running`.
- ( ) AC-T-005-4: Given `updateRunStatus(id, 'invalid_status' as RunStatus)`, when TypeScript compiles, then a type error is raised (compile-time guard).

---

### Phase C: Pipeline Executor Rebase Hook

---

#### TRD-006: RebaseHook — clean path implementation
`[satisfies REQ-001, REQ-006]`
**File:** `src/orchestrator/rebase-hook.ts`
**Estimate:** 4h
**Depends:** TRD-001, TRD-002, TRD-003

Implement `RebaseHook` class:

- Constructor accepts `{ workflow: WorkflowConfig, vcs: VcsBackend, store: Store, mailClient: SqliteMailClient, eventBus: PipelineEventBus }`.
- `register()` method registers `phase:complete` handler on the event bus.
- On `phase:complete`: if `workflow.rebaseAfterPhase !== event.phase` skip silently.
- Resolve target: `workflow.rebaseTarget ?? ('origin/' + await vcs.detectDefaultBranch(worktreePath))`.
- Emit `rebase:start`.
- Call `await vcs.rebase(worktreePath, target)` — returns `RebaseResult`.
- **Clean path** (`hasConflicts === false`): compute upstream commit count via `vcs.diff()`; emit `rebase:clean`; if `upstreamCommits > 0`, send `rebase-context` mail to QA.

**Validates PRD ACs:** AC-001-1, AC-001-2, AC-001-3, AC-006-1, AC-006-2

**Implementation ACs:**
- ( ) AC-I-006-1: Given `rebaseAfterPhase: developer` and a developer phase that completes, when `vcs.rebase()` returns `{hasConflicts: false}`, then `rebase:clean` is emitted and no status change occurs.
- ( ) AC-I-006-2: Given `rebaseAfterPhase: qa` and a developer phase completing, when the hook fires, then `vcs.rebase()` is NOT called (phase name mismatch).
- ( ) AC-I-006-3: Given no `rebaseAfterPhase` in workflow, when any phase completes, then `vcs.rebase()` is NOT called.
- ( ) AC-I-006-4: Given a clean rebase with 0 upstream commits, when hook fires, then no `rebase-context` mail is sent to QA.
- ( ) AC-I-006-5: Given a clean rebase with 3 upstream commits, when hook fires, then a `rebase-context` mail is sent to QA containing the upstream commit count and changed file list.

---

#### TRD-006-TEST: Verify RebaseHook clean path
`[verifies TRD-006] [satisfies REQ-001, REQ-006] [depends: TRD-006]`
**File:** `src/orchestrator/__tests__/rebase-hook.test.ts`
**Estimate:** 2h

- ( ) AC-T-006-1: Given a mock VcsBackend returning `{hasConflicts: false, upstreamCommits: 2}`, when `phase:complete` fires for the configured phase, then `rebase:clean` is emitted with `upstreamCommits: 2`.
- ( ) AC-T-006-2: Given `phase:complete` for a different phase name, when hook fires, then `vcs.rebase()` is not called (spy assertion).
- ( ) AC-T-006-3: Given `upstreamCommits: 0` on clean rebase, when hook fires, then `mailClient.send()` is not called.
- ( ) AC-T-006-4: Given `upstreamCommits: 5` and `changedFiles: ['a.ts', 'b.ts', ...]`, when hook fires, then `mailClient.send()` receives a payload with `type: 'rebase-context'` addressed to `'qa'`.

---

#### TRD-007: RebaseHook — conflict path
`[satisfies REQ-002]`
**File:** `src/orchestrator/rebase-hook.ts`
**Estimate:** 2h
**Depends:** TRD-006

Extend `RebaseHook` to handle `RebaseResult.hasConflicts === true`:
- Call `vcs.getConflictingFiles(worktreePath)` to enumerate conflicting paths.
- Call `store.updateRunStatus(runId, 'rebase_conflict')`.
- Emit `rebase:conflict` with conflicting file list.
- The pipeline executor's phase loop is suspended by the hook not resolving the `phase:complete` processing (see implementation note: the hook throws a `RebaseConflictError` caught by the executor, which suspends further phase dispatch).

**Validates PRD ACs:** AC-002-1, AC-002-2, AC-002-3, AC-002-4

**Implementation ACs:**
- ( ) AC-I-007-1: Given `vcs.rebase()` returns `{hasConflicts: true}`, when hook fires, then `vcs.getConflictingFiles()` is called and its result is attached to the `rebase:conflict` event.
- ( ) AC-I-007-2: Given `hasConflicts: true`, when hook fires, then `store.updateRunStatus(runId, 'rebase_conflict')` is called before `rebase:conflict` is emitted.
- ( ) AC-I-007-3: Given `rebase:conflict` emitted, when the executor catches the suspension signal, then no further phase is dispatched (QA does not start).

---

#### TRD-007-TEST: Verify RebaseHook conflict path
`[verifies TRD-007] [satisfies REQ-002] [depends: TRD-007]`
**File:** `src/orchestrator/__tests__/rebase-hook-conflict.test.ts`
**Estimate:** 2h

- ( ) AC-T-007-1: Given mock `vcs.rebase()` returning `{hasConflicts: true}` and `vcs.getConflictingFiles()` returning `['src/foo.ts']`, when hook fires, then `rebase:conflict` carries `conflictingFiles: ['src/foo.ts']`.
- ( ) AC-T-007-2: Given the conflict path, when triggered, then `store.updateRunStatus` is called with `'rebase_conflict'` (verified via mock).
- ( ) AC-T-007-3: Given the conflict path, when hook fires, then a `phase:start` event for the next phase is never emitted (pipeline suspended assertion).

---

#### TRD-008: Troubleshooter escalation from RebaseHook
`[satisfies REQ-003]`
**File:** `src/orchestrator/rebase-hook.ts`
**Estimate:** 3h
**Depends:** TRD-007

After emitting `rebase:conflict`, call `vcs.abortRebase()` immediately to restore the worktree to a clean pre-rebase state. Then send the `rebase-conflict` mail payload (section 4.4) to the troubleshooter's `resolve-rebase-conflict` skill (TRD-020) via `mailClient.send()`, including the conflicting files list and the upstream diff that would have been pulled in. Then call `store.updateRunStatus(runId, 'rebase_resolving')`. Register a `rebase:resolved` handler that will trigger pipeline resume (implemented in TRD-009).

**Validates PRD ACs:** AC-003-1, AC-003-2, AC-003-3

**Implementation ACs:**
- ( ) AC-I-008-1: Given a conflict detected, when escalation fires, then `vcs.abortRebase()` is called first (restoring clean worktree), then `mailClient.send()` is called with a payload matching `RebaseConflictMail` structure including `conflictingFiles` and `upstreamDiff`.
- ( ) AC-I-008-2: Given abort + mail sent to troubleshooter, when `store.updateRunStatus` is called, then the transition is `rebase_conflict -> rebase_resolving` (in that order).
- ( ) AC-I-008-3: Given troubleshooter signals permanent failure (rejected resolution), when hook receives failure signal, then run is marked `failed` and no resume occurs (rebase already aborted in AC-I-008-1).

---

#### TRD-008-TEST: Verify troubleshooter escalation
`[verifies TRD-008] [satisfies REQ-003] [depends: TRD-008]`
**File:** `src/orchestrator/__tests__/rebase-hook-escalation.test.ts`
**Estimate:** 2h

- ( ) AC-T-008-1: Given conflict detection, when escalation fires, then `vcs.abortRebase()` spy is called before `mailClient.send()` — abort precedes handoff.
- ( ) AC-T-008-2: Given abort + mail sent, when escalation fires, then `mailClient.send()` is called once with `to: 'troubleshooter'`, skill `resolve-rebase-conflict`, subject matching `[rebase-conflict]`, `body.conflictingFiles` non-empty, and `body.upstreamDiff` present.
- ( ) AC-T-008-3: Given escalation fires, when status transitions are observed, then `store.updateRunStatus` is called with `'rebase_conflict'` before `'rebase_resolving'` (order verified).
- ( ) AC-T-008-4: Given troubleshooter signals permanent failure, when hook handles it, then `store.updateRunStatus(id, 'failed')` is the final status call (no second abortRebase needed — already aborted).

---

#### TRD-009: Pipeline resume after conflict resolution
`[satisfies REQ-004]`
**File:** `src/orchestrator/rebase-hook.ts`
**Estimate:** 3h
**Depends:** TRD-008

Implement the `rebase:resolved` handler:
- Forward `EXPLORER_REPORT.md` artifact content to the developer via `mailClient.send()` with note that a conflict was resolved and the pipeline is resuming.
- Re-dispatch the developer phase from the resolved worktree state via `eventBus.emit('phase:start', { phase: 'developer', ... })` triggering the executor to re-run.
- Call `store.updateRunStatus(runId, 'running')`.
- Enforce single-resolution-attempt limit: if the resumed developer phase fails QA a second time (after max `retryOnFail` exhausted), transition to `failed` — no second troubleshooter escalation (AC-004-3).

**Validates PRD ACs:** AC-004-1, AC-004-2, AC-004-3

**Implementation ACs:**
- ( ) AC-I-009-1: Given `rebase:resolved` fires, when resume executes, then `mailClient.send()` is called to developer with `EXPLORER_REPORT.md` content and a conflict-resolution context note.
- ( ) AC-I-009-2: Given resume, when the developer re-run succeeds and QA passes, then `store.updateRunStatus(runId, 'running')` is set and the pipeline continues normally.
- ( ) AC-I-009-3: Given the resumed developer phase fails QA twice (hitting `retryOnFail` limit), when the retry counter is exhausted, then the run is marked `failed` (not another `rebase_conflict` / escalation).

---

#### TRD-009-TEST: Verify pipeline resume
`[verifies TRD-009] [satisfies REQ-004] [depends: TRD-009]`
**File:** `src/orchestrator/__tests__/rebase-hook-resume.test.ts`
**Estimate:** 2h

- ( ) AC-T-009-1: Given `rebase:resolved` emitted, when resume handler fires, then a mail is sent to `'developer'` containing the `EXPLORER_REPORT.md` path and a conflict-resolved context note.
- ( ) AC-T-009-2: Given resume fires, when `store.updateRunStatus` is called, then `'running'` is the argument.
- ( ) AC-T-009-3: Given the resumed developer phase exhausts `retryOnFail`, when the pipeline fails, then `store.updateRunStatus` is called with `'failed'` (not `'rebase_conflict'`).

---

### Phase D: QA Rebase-Context Mail

---

#### TRD-010: Diff computation after clean rebase
`[satisfies REQ-005]`
**File:** `src/orchestrator/rebase-hook.ts`
**Estimate:** 2h
**Depends:** TRD-006

After a clean rebase, compute the upstream file-level diff by calling `vcs.diff(worktreePath, priorHead, target)` where `priorHead` is the commit hash before rebase and `target` is the rebase target ref. Parse the diff output to enumerate added/modified/deleted file paths. Cap the list at 100 files; set `truncated: true` if the actual count exceeds 100. If `upstreamCommits === 0`, skip diff computation and send no mail.

**Validates PRD ACs:** AC-005-1, AC-005-2, AC-005-3

**Implementation ACs:**
- ( ) AC-I-010-1: Given a clean rebase that advances 3 upstream commits, when diff is computed, then `changedFiles` contains the file paths modified in those 3 commits.
- ( ) AC-I-010-2: Given a clean rebase with 0 upstream commits (already up to date), when hook fires, then diff is not computed and no `rebase-context` mail is sent.
- ( ) AC-I-010-3: Given a clean rebase with 150 changed files, when diff is computed, then `changedFiles` contains exactly 100 entries and `truncated` is `true`.

---

#### TRD-010-TEST: Verify diff computation
`[verifies TRD-010] [satisfies REQ-005] [depends: TRD-010]`
**File:** `src/orchestrator/__tests__/rebase-hook.test.ts` (extended)
**Estimate:** 2h

- ( ) AC-T-010-1: Given a mock `vcs.diff()` returning a 5-file diff, when clean rebase fires with `upstreamCommits: 3`, then `mailClient.send()` payload contains exactly 5 `changedFiles` entries.
- ( ) AC-T-010-2: Given `upstreamCommits: 0`, when hook fires, then `vcs.diff()` is NOT called (spy assertion).
- ( ) AC-T-010-3: Given a mock `vcs.diff()` returning 120 file paths, when hook fires, then payload has `changedFiles.length === 100` and `truncated === true`.

---

#### TRD-011: rebase-context mail delivery
`[satisfies REQ-005, REQ-014]`
**File:** `src/orchestrator/rebase-hook.ts`
**Estimate:** 1h
**Depends:** TRD-010

Send the assembled `RebaseContextMail` payload via `mailClient.send()` to the QA agent before the QA phase is dispatched. Mail is sent only when `upstreamCommits > 0`. The QA phase dispatch (next `phase:start` emission) occurs after the mail send completes.

**Validates PRD ACs:** AC-005-1, AC-014-1

**Implementation ACs:**
- ( ) AC-I-011-1: Given a clean rebase with upstream changes, when `rebase-context` mail is sent, then `mailClient.send()` is called with `to: 'qa'`, `type: 'rebase-context'`, and `subject` containing the upstream commit count.
- ( ) AC-I-011-2: Given mail is sent, when QA phase starts, then the QA agent's inbox contains the `rebase-context` mail (order guaranteed by sequential send-then-dispatch).

---

#### TRD-011-TEST: Verify rebase-context mail delivery
`[verifies TRD-011] [satisfies REQ-005, REQ-014] [depends: TRD-011]`
**File:** `src/orchestrator/__tests__/rebase-hook.test.ts` (extended)
**Estimate:** 1h

- ( ) AC-T-011-1: Given `upstreamCommits: 2`, when clean rebase fires, then `mailClient.send()` payload has `to: 'qa'` and `subject` matching `/\[rebase-context\]/`.
- ( ) AC-T-011-2: Given `mailClient.send()` called before `phase:start` for QA is emitted, when event order is inspected, then send precedes dispatch.

---

### Phase E: Observability

---

#### TRD-012: foreman status display for rebase statuses
`[satisfies REQ-012, REQ-013]`
**File:** `src/cli/commands/status.ts`
**Estimate:** 2h
**Depends:** TRD-005

Extend the `foreman status` command to display human-readable labels for the new status values:
- `rebase_conflict`: display label `REBASE CONFLICT` with conflicting file count (from run metadata).
- `rebase_resolving`: display label `RESOLVING` with duration in current state.

**Validates PRD ACs:** AC-012-1, AC-012-2, AC-012-3, AC-013-1

**Implementation ACs:**
- ( ) AC-I-012-1: Given a run with `status: 'rebase_conflict'`, when `foreman status` runs, then output contains `REBASE CONFLICT`.
- ( ) AC-I-012-2: Given a run with `status: 'rebase_resolving'`, when `foreman status` runs, then output contains `RESOLVING`.
- ( ) AC-I-012-3: Given a status transition from `rebase_conflict` to `rebase_resolving`, when `foreman status` is polled, then each transition is reflected without manual refresh.

---

#### TRD-012-TEST: Verify status display
`[verifies TRD-012] [satisfies REQ-012, REQ-013] [depends: TRD-012]`
**File:** `src/cli/__tests__/status-rebase.test.ts`
**Estimate:** 1h

- ( ) AC-T-012-1: Given a mock store returning a run with `status: 'rebase_conflict'`, when status command renders, then output includes `REBASE CONFLICT`.
- ( ) AC-T-012-2: Given `status: 'rebase_resolving'`, when rendered, then output includes `RESOLVING`.

---

#### TRD-013: foreman dashboard indicators
`[satisfies REQ-013]`
**File:** `src/cli/commands/dashboard.ts`
**Estimate:** 2h
**Depends:** TRD-005

Add visual indicators for the two new run statuses in the live dashboard:
- `rebase_conflict`: amber/yellow row color, label `REBASE CONFLICT` — distinct from `failed` (red) and `running` (green).
- `rebase_resolving`: blue row color, label `RESOLVING` — distinct from `in_progress` (green) and `rebase_conflict` (amber).

**Validates PRD ACs:** AC-013-1, AC-013-2

**Implementation ACs:**
- ( ) AC-I-013-1: Given a run in `rebase_conflict`, when dashboard renders, then the run row is displayed with amber/yellow coloring and the text `REBASE CONFLICT`.
- ( ) AC-I-013-2: Given a run in `rebase_resolving`, when dashboard renders, then the run row is displayed with blue coloring and the text `RESOLVING`.

---

#### TRD-013-TEST: Verify dashboard indicators
`[verifies TRD-013] [satisfies REQ-013] [depends: TRD-013]`
**File:** `src/cli/__tests__/dashboard-rebase.test.ts`
**Estimate:** 1h

- ( ) AC-T-013-1: Given a mock run with `status: 'rebase_conflict'`, when dashboard renders, then output string contains `REBASE CONFLICT` and the amber/yellow ANSI code.
- ( ) AC-T-013-2: Given `status: 'rebase_resolving'`, when dashboard renders, then output contains `RESOLVING` and the blue ANSI code.

---

#### TRD-014: foreman inbox --type filter
`[satisfies REQ-015]`
**File:** `src/cli/commands/inbox.ts`
**Estimate:** 1h
**Depends:** None (additive to existing --type flag if present, or new flag)

Extend `foreman inbox` to support filtering by mail type via `--type <type>`. Supported type values include `rebase-context` and `rebase-conflict` (in addition to any existing mail types). When `--type rebase-context` is specified, only `rebase-context` mails are returned. Combined with `--bead <id>`, shows the full rebase event chain for a given run in chronological order.

**Validates PRD ACs:** AC-015-1, AC-015-2

**Implementation ACs:**
- ( ) AC-I-014-1: Given a mailbox containing `rebase-context`, `rebase-conflict`, and other mail types, when `foreman inbox --type rebase-context` runs, then only `rebase-context` mails are shown.
- ( ) AC-I-014-2: Given `foreman inbox --bead <id>`, when a run has both `rebase-context` and `rebase-conflict` mails, then all rebase-related mails for that run appear in chronological order.

---

#### TRD-014-TEST: Verify inbox filtering
`[verifies TRD-014] [satisfies REQ-015] [depends: TRD-014]`
**File:** `src/cli/__tests__/inbox-rebase-filter.test.ts`
**Estimate:** 1h

- ( ) AC-T-014-1: Given a seeded mailbox with 3 mail types, when `inbox --type rebase-context` runs, then only mails with `type === 'rebase-context'` are returned.
- ( ) AC-T-014-2: Given `inbox --bead <id>` with multiple rebase event mails, when rendered, then mails are sorted ascending by `createdAt`.

---

#### TRD-015: Operator mail notifications
`[satisfies REQ-014]`
**File:** `src/orchestrator/rebase-hook.ts`
**Estimate:** 1.5h
**Depends:** TRD-008

Send operator-facing (or pipeline-log) mail notifications at each key rebase transition:
1. **Rebase start:** mail with subject `[rebase-start] rebasing run <runId> onto <target>`.
2. **Conflict detected:** mail already sent to troubleshooter (TRD-008); also emit a structured log entry.
3. **Resolution outcome:** mail with subject `[rebase-resolved] run <runId> resuming from developer` on success, or `[rebase-failed] run <runId> permanent conflict, pipeline failed` on permanent failure.

**Validates PRD ACs:** AC-014-1, AC-014-2, AC-014-3

**Implementation ACs:**
- ( ) AC-I-015-1: Given rebase fires, when `rebase:start` is emitted, then a structured log entry (or operator mail) is created with the target ref.
- ( ) AC-I-015-2: Given rebase produces conflicts, when troubleshooter is escalated, then the escalation mail subject matches `[rebase-conflict] <N> files conflicted in run <runId>`.
- ( ) AC-I-015-3: Given conflict resolved, when pipeline resumes, then a resolution notification is logged with subject matching `[rebase-resolved]`.

---

#### TRD-015-TEST: Verify operator notifications
`[verifies TRD-015] [satisfies REQ-014] [depends: TRD-015]`
**File:** `src/orchestrator/__tests__/rebase-hook-escalation.test.ts` (extended)
**Estimate:** 1h

- ( ) AC-T-015-1: Given rebase fires for phase `developer`, when `rebase:start` emits, then a notification is logged with the target ref string.
- ( ) AC-T-015-2: Given conflict path, when escalation fires, then `mailClient.send()` subject contains `[rebase-conflict]` and `conflicted`.
- ( ) AC-T-015-3: Given resolution success, when `rebase:resolved` fires, then a notification contains `[rebase-resolved]` and `resuming`.

---

### Phase F: Integration Tests and Performance

---

#### TRD-016: Integration test — clean rebase path
`[satisfies REQ-016, REQ-017, REQ-018]`
**File:** `src/orchestrator/__tests__/rebase-integration.test.ts`
**Estimate:** 3h
**Depends:** TRD-006, TRD-010, TRD-011

End-to-end integration test using a real git repository in a temp directory:
1. Create two diverging branches simulating upstream progress since developer started.
2. Configure workflow with `rebaseAfterPhase: developer`.
3. Run pipeline through mock developer phase completion.
4. Verify `vcs.rebase()` is called, resolves cleanly, `rebase-context` mail appears in QA inbox, and the QA phase proceeds.
5. Verify total rebase step latency < 30s on a clean path (REQ-016).

**Validates PRD ACs:** AC-001-1, AC-001-2, AC-005-1, AC-005-2, AC-016-1

**Implementation ACs:**
- ( ) AC-I-016-1: Given a real git repo with 2 upstream commits diverged since branch creation, when developer phase completes and rebase fires, then QA inbox contains a `rebase-context` mail with `upstreamCommits: 2`.
- ( ) AC-I-016-2: Given the integration test, when rebase step executes, then elapsed time is < 30s.
- ( ) AC-I-016-3: Given a pipeline run with no `rebaseAfterPhase` configured, when all phases complete, then no rebase event fires and behavior is identical to pre-feature.

---

#### TRD-016-TEST: Verify integration test assertions
`[verifies TRD-016] [satisfies REQ-016, REQ-017, REQ-018] [depends: TRD-016]`
**File:** `src/orchestrator/__tests__/rebase-integration.test.ts` (assertions section)
**Estimate:** 1h (included in TRD-016 estimate above as assertion authoring; listed separately for tracking)

- ( ) AC-T-016-1: Given clean rebase integration test, when run, then all assertions pass with a real git repository.
- ( ) AC-T-016-2: Given `upstreamCommits: 2` in the QA inbox mail, then `mailClient` received exactly 1 `rebase-context` send call.

---

#### TRD-017: Integration test — conflict path
`[satisfies REQ-003, REQ-004, REQ-018]`
**File:** `src/orchestrator/__tests__/rebase-conflict-integration.test.ts`
**Estimate:** 3h
**Depends:** TRD-008, TRD-009

End-to-end integration test using a real git repository with a genuine conflict (same line modified on both branches):
1. Configure `rebaseAfterPhase: developer`.
2. Run pipeline through developer phase completion.
3. Verify rebase produces `RebaseResult.hasConflicts === true`.
4. Verify troubleshooter receives escalation mail with correct `conflictingFiles`.
5. Simulate troubleshooter resolution signal.
6. Verify pipeline resumes from developer phase with `EXPLORER_REPORT.md` forwarded.
7. Verify second conflict at the same point marks run `failed` (no second escalation).

**Validates PRD ACs:** AC-002-1, AC-003-1, AC-003-2, AC-003-3, AC-004-1, AC-004-2, AC-004-3

**Implementation ACs:**
- ( ) AC-I-017-1: Given a real git conflict, when rebase fires, then troubleshooter mail arrives with `conflictingFiles` listing the conflicted file(s).
- ( ) AC-I-017-2: Given troubleshooter resolves and signals success, when pipeline resumes, then developer phase re-runs with explorer artifact forwarded.
- ( ) AC-I-017-3: Given the resumed developer fails QA twice, when `retryOnFail` exhausted, then run status is `failed` (not `rebase_conflict`).

---

#### TRD-017-TEST: Verify conflict integration assertions
`[verifies TRD-017] [satisfies REQ-003, REQ-004, REQ-018] [depends: TRD-017]`
**File:** `src/orchestrator/__tests__/rebase-conflict-integration.test.ts` (assertions section)
**Estimate:** 1h (included in TRD-017 estimate above)

- ( ) AC-T-017-1: Given conflict integration test, when run against a real conflicting git repo, then all state transition assertions pass.
- ( ) AC-T-017-2: Given second-conflict scenario, when run, then final `store.getRun(id).status === 'failed'`.

---

#### TRD-018: Regression test — full existing pipeline suite
`[satisfies REQ-017]`
**File:** `src/orchestrator/__tests__/rebase-regression.test.ts`
**Estimate:** 1h
**Depends:** TRD-002, TRD-004

Verify that pipelines with no `rebaseAfterPhase` configured (the default) produce zero behavioral change:
- Run the existing pipeline test suite (or a representative subset) against the refactored event-emitting executor.
- Assert no `rebase:start`, `rebase:clean`, or `rebase:conflict` events are emitted.
- Assert pipeline outcome (phases run, order, final status) is identical to pre-refactor behavior.

**Validates PRD ACs:** AC-009-1, AC-017-1

**Implementation ACs:**
- ( ) AC-I-018-1: Given the default workflow (no `rebaseAfterPhase`), when a full pipeline runs end-to-end, then no rebase-related events are emitted.
- ( ) AC-I-018-2: Given the refactored pipeline executor, when existing pipeline tests run, then all pass with zero test modifications.

---

#### TRD-018-TEST: Verify regression suite
`[verifies TRD-018] [satisfies REQ-017] [depends: TRD-018]`
**File:** `src/orchestrator/__tests__/rebase-regression.test.ts` (assertions)
**Estimate:** 0.5h (included in TRD-018 estimate)

- ( ) AC-T-018-1: Given the default workflow, when pipeline completes, then event log contains zero events with type matching `/^rebase:/`.
- ( ) AC-T-018-2: Given the existing test suite, when run after all Phase 0-E changes, then test pass rate is 100%.

---

#### TRD-019: Performance validation
`[satisfies REQ-016]`
**File:** `src/orchestrator/__tests__/rebase-integration.test.ts` (performance assertions)
**Estimate:** 1.5h
**Depends:** TRD-016, TRD-017

Validate the two performance targets from REQ-016:
1. **Clean rebase step latency:** The wall-clock time from `rebase:start` emission to `rebase:clean` emission is < 30s on a repo with 100 commits.
2. **Conflict detection + escalation:** The time from `rebase:start` to troubleshooter mail sent is < 10s (local only; excludes troubleshooter agent execution time).

**Validates PRD ACs:** AC-016-1, AC-016-2

**Implementation ACs:**
- ( ) AC-I-019-1: Given a real git repo with 100 commits on the base branch, when clean rebase fires, then time from `rebase:start` to `rebase:clean` is < 30s.
- ( ) AC-I-019-2: Given a real conflict, when rebase fires, then time from `rebase:start` to `mailClient.send()` (troubleshooter mail) is < 10s.

---

#### TRD-019-TEST: Verify performance targets
`[verifies TRD-019] [satisfies REQ-016] [depends: TRD-019]`
**File:** `src/orchestrator/__tests__/rebase-integration.test.ts` (performance section)
**Estimate:** 0.5h (included in TRD-019 estimate)

- ( ) AC-T-019-1: Given clean rebase performance test, when timed, then elapsed milliseconds < 30,000.
- ( ) AC-T-019-2: Given conflict detection performance test, when timed, then elapsed milliseconds < 10,000.

---

#### TRD-020: `resolve-rebase-conflict` troubleshooter skill
`[satisfies REQ-003]`
**Files:** `src/defaults/prompts/default/resolve-rebase-conflict.md`, `src/orchestrator/pi-sdk-tools.ts`
**Estimate:** 3h
**Depends:** TRD-008

Implement a new troubleshooter skill specifically for mid-pipeline rebase conflicts. Unlike `resolve-conflict` (which operates on a failed finalize push), this skill receives a **clean worktree** (rebase already aborted by TRD-008) plus the upstream diff that caused the conflict. The skill must:

1. Apply the upstream changes manually to the clean worktree.
2. Resolve any semantic conflicts between the developer's uncommitted work and the upstream changes.
3. Signal success or failure via mail reply.

**Prompt file:** Context includes worktree path, conflicting files list, upstream diff summary. Guardrails: do not commit; do not push; only resolve and signal.

**Registration:** Add `resolve-rebase-conflict` to the troubleshooter skill registry in `pi-sdk-tools.ts`.

**Validates PRD ACs:** AC-003-1, AC-003-2, AC-003-3

**Implementation ACs:**
- ( ) AC-I-020-1: Given the troubleshooter receives a `rebase-conflict` mail with skill `resolve-rebase-conflict`, when the skill executes, then it operates on the clean (post-abort) worktree and attempts to apply upstream changes.
- ( ) AC-I-020-2: Given the skill resolves all conflicts, when it signals success, then a reply mail with `type: rebase-resolved` is sent, triggering the `rebase:resolved` handler in TRD-009.
- ( ) AC-I-020-3: Given the skill cannot resolve conflicts within its max-turns budget, when it signals failure, then a reply mail with `type: rebase-failed` is sent, causing the run to transition to `failed`.

---

#### TRD-020-TEST: Verify `resolve-rebase-conflict` skill
`[verifies TRD-020] [satisfies REQ-003] [depends: TRD-020]`
**File:** `src/orchestrator/__tests__/resolve-rebase-conflict-skill.test.ts`
**Estimate:** 2h

- ( ) AC-T-020-1: Given a mock troubleshooter session receiving a `rebase-conflict` mail, when skill is invoked, then it targets the worktree path from the mail payload.
- ( ) AC-T-020-2: Given skill resolves conflicts successfully, when it completes, then a `rebase-resolved` reply mail is sent and the `rebase:resolved` event fires in the pipeline event bus.
- ( ) AC-T-020-3: Given skill fails to resolve (budget exhausted), when it completes, then a `rebase-failed` reply mail is sent and the run transitions to `failed`.

---

## 6. Sprint Planning

### Phase 0: Event-Driven Pipeline Foundation — 2 days

| Task | Estimate | Dependencies | Status |
|------|----------|-------------|--------|
| TRD-001: PipelineEventBus | 3h | -- | ( ) |
| TRD-001-TEST | 2h | TRD-001 | ( ) |
| TRD-002: Refactor pipeline-executor | 4h | TRD-001 | ( ) |
| TRD-002-TEST | 3h | TRD-002 | ( ) |

**Phase 0 Total:** 12h (~1.5 days)
**Gate:** `npx tsc --noEmit` clean. All existing pipeline tests pass unchanged. Event emission verified.

---

### Phase A: Workflow YAML Schema — 1 day

| Task | Estimate | Dependencies | Status |
|------|----------|-------------|--------|
| TRD-003: workflow-loader schema update | 2h | -- | ( ) |
| TRD-003-TEST | 2h | TRD-003 | ( ) |
| TRD-004: Default workflow YAML update | 0.5h | TRD-003 | ( ) |
| TRD-004-TEST | 0.5h | TRD-004 | ( ) |

**Phase A Total:** 5h (~0.6 days)
**Gate:** `rebaseAfterPhase` and `rebaseTarget` parsed correctly. Validation error thrown for unknown phase name. Default workflow behavior unchanged.

---

### Phase B: SQLite Schema Migration — 0.5 days

| Task | Estimate | Dependencies | Status |
|------|----------|-------------|--------|
| TRD-005: store.ts migration | 2h | -- | ( ) |
| TRD-005-TEST | 1h | TRD-005 | ( ) |

**Phase B Total:** 3h (~0.4 days)
**Gate:** New status values accepted by SQLite and TypeScript. Existing data unaffected.

*Note: Phases A and B can proceed in parallel — neither depends on Phase 0.*

---

### Phase C: Pipeline Executor Rebase Hook — 3 days

| Task | Estimate | Dependencies | Status |
|------|----------|-------------|--------|
| TRD-006: RebaseHook clean path | 4h | TRD-001, TRD-002, TRD-003 | ( ) |
| TRD-006-TEST | 2h | TRD-006 | ( ) |
| TRD-007: RebaseHook conflict path | 2h | TRD-006 | ( ) |
| TRD-007-TEST | 2h | TRD-007 | ( ) |
| TRD-008: Troubleshooter escalation | 3h | TRD-007 | ( ) |
| TRD-008-TEST | 2h | TRD-008 | ( ) |
| TRD-009: Pipeline resume | 3h | TRD-008 | ( ) |
| TRD-009-TEST | 2h | TRD-009 | ( ) |
| TRD-020: `resolve-rebase-conflict` skill | 3h | TRD-008 | ( ) |
| TRD-020-TEST | 2h | TRD-020 | ( ) |

**Phase C Total:** 25h (~3 days)
**Gate:** Clean and conflict paths verified with mocked VcsBackend. Troubleshooter escalation aborts rebase first, then sends correct mail to `resolve-rebase-conflict` skill. Pipeline resume re-runs developer phase. Single-escalation-per-run limit enforced. New skill registered and tested.

---

### Phase D: QA Rebase-Context Mail — 1 day

| Task | Estimate | Dependencies | Status |
|------|----------|-------------|--------|
| TRD-010: Diff computation | 2h | TRD-006 | ( ) |
| TRD-010-TEST | 2h | TRD-010 | ( ) |
| TRD-011: rebase-context mail delivery | 1h | TRD-010 | ( ) |
| TRD-011-TEST | 1h | TRD-011 | ( ) |

**Phase D Total:** 6h (~0.75 days)
**Gate:** QA inbox receives `rebase-context` mail before phase dispatch. 100-file cap enforced. Zero-upstream-commit path sends no mail.

---

### Phase E: Observability — 1.5 days

| Task | Estimate | Dependencies | Status |
|------|----------|-------------|--------|
| TRD-012: foreman status display | 2h | TRD-005 | ( ) |
| TRD-012-TEST | 1h | TRD-012 | ( ) |
| TRD-013: foreman dashboard indicators | 2h | TRD-005 | ( ) |
| TRD-013-TEST | 1h | TRD-013 | ( ) |
| TRD-014: foreman inbox --type filter | 1h | -- | ( ) |
| TRD-014-TEST | 1h | TRD-014 | ( ) |
| TRD-015: Operator mail notifications | 1.5h | TRD-008 | ( ) |
| TRD-015-TEST | 1h | TRD-015 | ( ) |

**Phase E Total:** 10.5h (~1.3 days)
**Gate:** `foreman status` shows `REBASE CONFLICT` / `RESOLVING`. Dashboard shows amber/blue indicators. Inbox `--type` filter returns correct mails.

---

### Phase F: Integration Tests and Performance — 2 days

| Task | Estimate | Dependencies | Status |
|------|----------|-------------|--------|
| TRD-016: Integration test — clean path | 3h | TRD-006, TRD-010, TRD-011 | ( ) |
| TRD-016-TEST | (included) | TRD-016 | ( ) |
| TRD-017: Integration test — conflict path | 3h | TRD-008, TRD-009 | ( ) |
| TRD-017-TEST | (included) | TRD-017 | ( ) |
| TRD-018: Regression test | 1h | TRD-002, TRD-004 | ( ) |
| TRD-018-TEST | (included) | TRD-018 | ( ) |
| TRD-019: Performance validation | 1.5h | TRD-016, TRD-017 | ( ) |
| TRD-019-TEST | (included) | TRD-019 | ( ) |

**Phase F Total:** 8.5h (~1.1 days)
**Gate:** Clean rebase latency < 30s. Conflict detection + escalation < 10s. Full pipeline regression passes. No behavioral change on workflows without `rebaseAfterPhase`.

---

### Summary

| Phase | Description | Tasks (impl + test) | Estimated Hours | Calendar Days |
|-------|-------------|---------------------|-----------------|---------------|
| 0 | Event-Driven Foundation | 4 (2 + 2) | 12h | 1.5 |
| A | Workflow YAML Schema | 4 (2 + 2) | 5h | 0.6 |
| B | SQLite Migration | 2 (1 + 1) | 3h | 0.4 |
| C | Rebase Hook | 8 (4 + 4) | 20h | 2.5 |
| D | QA Mail | 4 (2 + 2) | 6h | 0.75 |
| E | Observability | 8 (4 + 4) | 10.5h | 1.3 |
| F | Integration + Perf | 8 (4 + 4) | 8.5h | 1.1 |
| **Total** | | **38 (19 + 19)** | **65h** | **~8 days** |

*Phases A and B can proceed in parallel with each other and independently of Phase 0 (no shared dependencies). Phase C is the critical path: it depends on Phases 0, A, and B.*

---

## 7. Quality Requirements

### 7.1 Testing Strategy

| Level | Coverage Target | Tools | Scope |
|-------|----------------|-------|-------|
| Unit | >= 80% | Vitest | PipelineEventBus, RebaseHook, workflow-loader changes, store migration, status/dashboard rendering |
| Integration | >= 70% | Vitest + real git repo | Clean rebase path, conflict path, resume path, regression against default workflow |
| E2E | Phase F | Vitest + real git CLI | Full pipeline cycle with `rebaseAfterPhase` active on a real local repository |
| Performance | Per REQ-016 | Vitest timed assertions | Rebase step < 30s; conflict + escalation < 10s |

### 7.2 Testing Conventions

- **RebaseHook unit tests:** Use mock `VcsBackend` (vi.fn() stubs). No real git operations.
- **PipelineEventBus tests:** No mocks needed — test pure event propagation and `safeEmit` error isolation.
- **Integration tests:** Use `mkdtemp` for temporary real git repos. Create commits programmatically via `GitBackend` (not shell scripts) to avoid test brittleness.
- **Performance tests:** Run in a `describe` block with `.skip` guard unless `process.env.FOREMAN_PERF_TESTS === '1'`, to avoid slow tests in standard CI.
- **TDD cycle:** RED (write failing test) → GREEN (minimal implementation) → REFACTOR.

### 7.3 Performance Targets

| Metric | Target | Measurement |
|--------|--------|-------------|
| Clean rebase step latency | < 30s | Wall clock from `rebase:start` to `rebase:clean` |
| Conflict detection + escalation latency | < 10s | Wall clock from `rebase:start` to troubleshooter mail sent |
| Event bus overhead | < 1ms per emit | No measurable pipeline throughput impact |
| Pipeline regression | 0% change on default workflow | All existing pipeline tests pass |

### 7.4 Backward Compatibility Gates

| Gate | Validation | Blocks |
|------|------------|--------|
| Default workflow has no `rebaseAfterPhase` | Regression test TRD-018 | Phase F completion |
| All existing pipeline tests pass | TRD-002-TEST | Phase 0 completion |
| No new VcsBackend methods required | Code review gate | Phase C start |
| New run statuses do not break existing status consumers | TRD-005-TEST | Phase B completion |

### 7.5 Security Considerations

- No new secrets or credentials introduced.
- `rebaseTarget` is a string passed to `vcs.rebase()` which already sanitizes inputs via `execFileAsync` argument array (no shell interpolation).
- Agent mail payloads containing worktree paths are internal-only (not user-facing API).
- `rebaseAfterPhase` and `rebaseTarget` are validated by `workflow-loader.ts` before reaching the executor.

---

## 8. Acceptance Criteria Traceability

### 8.1 Traceability Matrix: PRD Requirements to TRD Tasks

| REQ ID | Requirement | Priority | Implementation Tasks | Test Tasks |
|--------|-------------|----------|---------------------|------------|
| REQ-001 | Mid-Pipeline Rebase Execution | P0 | TRD-006 | TRD-006-TEST |
| REQ-002 | Conflict Detection and Run Status Transition | P0 | TRD-007 | TRD-007-TEST |
| REQ-003 | Troubleshooter Escalation | P0 | TRD-008, TRD-020 | TRD-008-TEST, TRD-020-TEST |
| REQ-004 | Pipeline Resume After Conflict Resolution | P0 | TRD-009 | TRD-009-TEST |
| REQ-005 | QA Rebase-Context Mail | P1 | TRD-010, TRD-011 | TRD-010-TEST, TRD-011-TEST |
| REQ-006 | VcsBackend Rebase Method Compatibility | P1 | TRD-006 (interface use) | TRD-006-TEST |
| REQ-007 | rebaseAfterPhase Configuration Key | P0 | TRD-003, TRD-004 | TRD-003-TEST, TRD-004-TEST |
| REQ-008 | rebaseTarget Configuration Key | P1 | TRD-003 | TRD-003-TEST |
| REQ-009 | Default Workflow Update | P2 | TRD-004 | TRD-004-TEST, TRD-018 |
| REQ-010 | Shared Worktree Dispatcher Queuing | P3 | (deferred to v2) | (deferred) |
| REQ-011 | Shared Worktree Serial Finalize | P3 | (deferred to v2) | (deferred) |
| REQ-012 | New Run Status Values | P1 | TRD-005 | TRD-005-TEST |
| REQ-013 | Dashboard Visibility | P2 | TRD-012, TRD-013 | TRD-012-TEST, TRD-013-TEST |
| REQ-014 | Agent Mail Notifications | P1 | TRD-011, TRD-015 | TRD-011-TEST, TRD-015-TEST |
| REQ-015 | foreman inbox Rebase Mail Filtering | P2 | TRD-014 | TRD-014-TEST |
| REQ-016 | Performance — Rebase Step Latency | P1 | TRD-019 | TRD-019-TEST |
| REQ-017 | Reliability — No Regression on Clean Pipelines | P0 | TRD-002, TRD-018 | TRD-002-TEST, TRD-018-TEST |
| REQ-018 | Test Coverage | P1 | TRD-016, TRD-017, TRD-018, TRD-019 | (all F-phase tests) |

### 8.2 PRD Acceptance Criteria Coverage

| AC ID | PRD AC Description | TRD Task | Test Task |
|-------|-------------------|----------|-----------|
| AC-001-1 | `vcs.rebase('origin/dev')` called after developer phase | TRD-006 | TRD-006-TEST |
| AC-001-2 | Rebase fires before QA phase dispatch | TRD-006 | TRD-006-TEST |
| AC-001-3 | No `rebaseAfterPhase` → no mid-pipeline rebase | TRD-006 | TRD-006-TEST, TRD-018 |
| AC-002-1 | Conflict → run status `rebase_conflict` | TRD-007 | TRD-007-TEST |
| AC-002-2 | Conflict → QA not dispatched | TRD-007 | TRD-007-TEST |
| AC-002-3 | `getConflictingFiles()` result in `rebase:conflict` event | TRD-007 | TRD-007-TEST |
| AC-002-4 | Clean rebase → no status change | TRD-006 | TRD-006-TEST |
| AC-003-1 | Troubleshooter receives worktreePath, target, conflictingFiles | TRD-008 | TRD-008-TEST |
| AC-003-2 | Resolved → pipeline resumes from developer (not explorer) | TRD-009 | TRD-009-TEST |
| AC-003-3 | Permanent failure → `abortRebase()`, run `failed` | TRD-008 | TRD-008-TEST |
| AC-004-1 | Resume → developer receives EXPLORER_REPORT.md + note | TRD-009 | TRD-009-TEST |
| AC-004-2 | Resumed developer succeeds → pipeline continues normally | TRD-009 | TRD-017 |
| AC-004-3 | Resumed developer fails QA twice → `failed` (no second escalation) | TRD-009 | TRD-009-TEST, TRD-017 |
| AC-005-1 | Clean rebase with upstream changes → `rebase-context` mail to QA | TRD-010, TRD-011 | TRD-010-TEST, TRD-011-TEST |
| AC-005-2 | Mail contains upstream commit count and file diff | TRD-010 | TRD-010-TEST |
| AC-005-3 | Zero-upstream-commit rebase → no mail sent | TRD-010 | TRD-010-TEST |
| AC-007-1 | `rebaseAfterPhase: developer` parsed correctly | TRD-003 | TRD-003-TEST |
| AC-007-2 | No key → `undefined`, no mid-pipeline rebase | TRD-003 | TRD-003-TEST |
| AC-007-3 | Unknown phase name → validation error | TRD-003 | TRD-003-TEST |
| AC-008-1 | `rebaseTarget: origin/main` → `vcs.rebase('origin/main')` | TRD-003, TRD-006 | TRD-003-TEST, TRD-006-TEST |
| AC-008-2 | No `rebaseTarget` → `origin/<detectDefaultBranch()>` | TRD-006 | TRD-006-TEST |
| AC-009-1 | Default workflow: no mid-pipeline rebase by default | TRD-004, TRD-018 | TRD-004-TEST, TRD-018-TEST |
| AC-009-2 | Uncommenting keys activates rebase | TRD-004 | TRD-004-TEST |
| AC-012-1 | `rebase_conflict` accepted by store | TRD-005 | TRD-005-TEST |
| AC-012-2 | `rebase_resolving` accepted by store | TRD-005 | TRD-005-TEST |
| AC-012-3 | Status transitions reflected in `foreman status` | TRD-012 | TRD-012-TEST |
| AC-013-1 | `rebase_conflict` → amber/REBASE CONFLICT in dashboard | TRD-013 | TRD-013-TEST |
| AC-013-2 | `rebase_resolving` → blue/RESOLVING in dashboard | TRD-013 | TRD-013-TEST |
| AC-014-1 | Rebase start notification logged | TRD-015 | TRD-015-TEST |
| AC-014-2 | Conflict escalation mail subject format correct | TRD-008, TRD-015 | TRD-008-TEST, TRD-015-TEST |
| AC-014-3 | Resolution outcome notification logged | TRD-015 | TRD-015-TEST |
| AC-015-1 | `inbox --type rebase-context` filters correctly | TRD-014 | TRD-014-TEST |
| AC-015-2 | `inbox --bead <id>` shows rebase event chain in order | TRD-014 | TRD-014-TEST |
| AC-016-1 | Clean rebase step < 30s | TRD-019 | TRD-019-TEST |
| AC-016-2 | Conflict detection + escalation < 10s | TRD-019 | TRD-019-TEST |
| AC-017-1 | Default workflow pipelines: zero behavioral change | TRD-002, TRD-018 | TRD-002-TEST, TRD-018-TEST |

---

## 9. Open Questions

| ID | Question | Status | Technical Impact |
|----|----------|--------|-----------------|
| OQ-6 | Does the troubleshooter's `resolve-conflict` skill require changes for mid-pipeline use? | **Resolved** | The troubleshooter expects a **clean worktree** (abort-and-retry model). TRD-008 calls `vcs.abortRebase()` before handing off. A new dedicated skill `resolve-rebase-conflict` (TRD-020) is created rather than reusing `resolve-conflict`, since the context differs: this skill receives an aborted-rebase clean worktree + upstream diff, not a failed-push scenario. |
| OQ-7 | Should `rebaseAfterPhase` support multiple phases (e.g., after explorer AND after developer)? v1 schema is a single string. Supporting an array would be a minor `workflow-loader.ts` extension but changes how the `RebaseHook` constructor is parameterized. **Does not affect Phase 0 or B.** Recommend committing to single-phase for v1; can extend to `string | string[]` post-release without breaking existing configs. | Open (deferred) | TRD-003 (minor) |

---

## 10. Design Readiness Scorecard

| Dimension | Score (1-5) | Rationale |
|-----------|-------------|-----------|
| Architecture completeness | 5 | All components, interfaces, data flows, and event taxonomy defined. VcsBackend compatibility confirmed (no new methods needed). Module structure fully specified. |
| Task coverage | 5 | Every REQ-NNN has at least one implementation task and a paired test task. REQ-010 and REQ-011 (deferred v2) are explicitly excluded with rationale. |
| Dependency clarity | 4 | Linear phase dependencies (0 → A,B → C → D,E → F) are clear. Phases A and B can parallelize. One open question (OQ-6) may shift TRD-008 approach but does not block earlier phases. |
| Estimate confidence | 4 | Estimates consistent with TRD-2026-004 patterns. Phase C is highest risk (novel RebaseHook design, troubleshooter interaction protocol). Phase 0 executor refactor carries moderate risk (wide surface area in pipeline-executor.ts). |

**Overall: 4.5 — PASS**

Total estimates: 65h across 19 implementation tasks + 19 test tasks = 38 tasks total.
