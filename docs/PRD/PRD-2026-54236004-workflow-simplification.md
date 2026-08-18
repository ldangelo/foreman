---
document_id: PRD-2026-54236004
label: prd-workflow-simplification
version: 1.0.0
status: Draft
date: 2026-08-17
scale_depth: STANDARD
author: Lead Agent (PRD Phase via ensemble:create-prd)
total_requirements: 19
readiness_score: 4.0
readiness_gate: PASS
---

# PRD-2026-54236004: Workflow Simplification — Curated Run Queue Dispatch

## PRD Health Summary

| Metric | Value |
|--------|-------|
| **Total Requirements** | 19 (REQ-001 through REQ-019) |
| **Must** | 15 |
| **Should** | 3 |
| **Could** | 1 |
| **Won't (this release)** | 0 |
| **AC Coverage** | 19/19 (100%) |
| **Risk Flags** | 6 |
| **Cross-Requirement Dependencies** | 8 |
| **Readiness Score** | 4.0 / 5.0 |
| **Ambiguity Markers** | 0 |

---

## 1. Executive Summary

### 1.1 Problem Statement

Foreman currently requires multiple steps (task create → task approve → ...) to dispatch work. The task-based dispatch mechanism is too slow and cumbersome for day-to-day use. A lightweight dispatch path is needed that lets an operator go from "I have a feature idea" to "PR created" in one operator step.

### 1.2 Solution Overview

Replace the multi-step task-based dispatch with a curated set of three workflows (PRD, TRD, FIX) dispatched via a single command. Work is queued through the run queue, executed by JIDO (the Elixir AI backend), and automatically creates a PR when complete. The three curated workflows supersede all existing workflows.

- **PRD workflow:** feature prompt → create-prd → refine-prd (autonomous) → create-trd → implement-trd → PR
- **TRD workflow:** existing PRD → create-trd → implement-trd → PR
- **FIX workflow:** bug/issue prompt → ensemble-fix-issue → PR

### 1.3 Value Proposition

- **One operator step:** `foreman run submit` replaces task create → approve → ...
- **Lightweight dispatch:** prompt + workflow name + optional backend = queued run
- **Autonomous refinement:** no operator interruption during PRD refinement
- **Automatic PR:** each phase checkpoints; PR created at workflow end
- **Worktree preserved:** operator reviews before cleanup
- **JIDO-native:** leverages existing jido-integration for model provider switching

---

## 2. User Analysis

### 2.1 Primary Users

| Role | Description | Pain Point |
|------|-------------|------------|
| **Individual contributor** | Wants to quickly dispatch a feature or fix | Tasks too heavy; one-step dispatch needed |
| **Team lead** | Orchestrates work across developers | Fast turn-around from idea to PR |

### 2.2 Current Workflow (Problem)

```text
foreman task create --project <id> --title <title> --workflow-type <type>
→ foreman task approve --id <task-id>
→ [run executes]
→ [manual PR if applicable]
```

Multiple steps, too slow to set up.

### 2.3 Desired Workflow (Solution)

```text
foreman run submit --workflow prd --prompt "implement X" [--backend claude]
→ queued, then executed in worktree via JIDO
→ each phase checkpoints to branch
→ PR auto-created on completion
→ worktree kept for review
```

One operator step.

---

## 3. Goals and Non-Goals

### 3.1 Goals

| ID | Goal | Success Metric |
|----|------|----------------|
| G-1 | Replace multi-step task dispatch with one-step run submission | Single `foreman run submit` command queues and starts a run |
| G-2 | Provide three curated workflows (PRD, TRD, FIX) | Each workflow executes its full chain and creates a PR |
| G-3 | Execute runs via JIDO (always) with configurable model backend | `foreman run submit --backend pi` (default), `--backend claude`, etc. |
| G-4 | Preserve worktree after run completion for operator review | Worktree persists until operator manually cleans up |
| G-5 | Checkpoint after each phase | Each phase push to branch; PR created after final phase |
| G-6 | Recover runs from event stream after interruption | Interrupted runs restart from beginning via event stream |
| G-7 | Remove legacy workflows | Only three curated workflows remain |

### 3.2 Non-Goals

- Full removal of task-based dispatch (remains as fallback per fix-workflows.md)
- Full removal of existing workflows in Phase 1 (deprecated with `--force` confirmation; recoverable from git)
- Backend-agnostic YAML manifests in Phase 1 (deferred to Phase 2; Phase 1 ships JIDO+Pi)
- Full removal of JIDO (JIDO is the constant orchestration layer)

---

## 4. Proposed Architecture

### 4.1 Dispatch Path

```text
Operator
  └── foreman run submit (Go CLI)
        └── foreman_work_submit MCP tool
              └── work.submit command
                    └── WorkRequest aggregate
                          └── RunExecutor (source: :work_request)
                                └── JIDO (orchestration layer, always)
                                      └── Model backend (pi/claude/codex/opencode via jido-integration)
                                            └── Worktree
                                                  └── Ensemble workflow phases
                                                        └── Phase checkpoint push (each phase)
                                                            └── PR auto-created (final phase)
```

### 4.2 JIDO Role

JIDO is the constant orchestration layer. It owns:
- Worktree lifecycle
- Phase execution
- Event stream persistence
- Run recovery

Model provider switching is handled via jido-integration (https://jido.run/ecosystem/jido_integration). Default model backend is Pi. Other providers (claude, codex, opencode) are selectable via `--backend`.

### 4.3 Phase 1 vs Phase 2

**Phase 1 (this PRD):**
- JIDO + Pi (default via jido-integration)
- Backend selection CLI (`--backend`) implemented
- Three curated workflows: prd, trd, fix

**Phase 2 (future):**
- Backend-agnostic YAML manifests
- Full multi-backend agnostic support (claude/codex/opencode natively)

---

## 5. Feature Areas

1. Run submit CLI command (`foreman run submit`)
2. Model backend selection (pi/claude/codex/opencode via jido-integration)
3. PRD curated workflow (create-prd → refine-prd → create-trd → implement-trd)
4. TRD curated workflow (create-trd → implement-trd)
5. FIX curated workflow (ensemble-fix-issue)
6. Worktree lifecycle (create → execute → preserve for review)
7. Phase checkpoint push (each phase pushes to branch)
8. Automatic PR creation (after final phase)
9. Run recovery (event stream restart from beginning)
10. Concurrency queue (existing limits apply)
11. Legacy workflow removal (interactive confirmation required)

---

## 6. Functional Requirements

### REQ-001: Run Submit CLI Command

**Priority:** Must
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: new CLI surface must integrate with existing Go CLI patterns]

Foreman shall provide a `foreman run submit` command that accepts workflow name, prompt, and optional backend.

- AC-001-1: Given `foreman run submit --workflow <name> --prompt <text> --project-id <id>`, when the command is valid, then a run is queued and a run ID is returned.
- AC-001-2: Given `--backend <name>` is specified, when the backend is available, then the run uses that model backend.
- AC-001-3: Given `--backend <name>` is omitted, when the command is valid, then the run uses foreman's configured default model backend.

```text
Usage: foreman run submit [flags]
  --work-id string     Work ID (required)
  --project-id string  Project ID (required)
  --workflow string    Workflow name: prd, trd, fix (required)
  --prompt string      Input prompt (required)
  --backend string     Model backend: pi (default), claude, codex, opencode (optional)
```

### REQ-002: Backend Availability Check

**Priority:** Must
**Complexity:** Low
**Type:** Functional

Foreman shall verify the selected model backend is installed and configured before queuing.

- AC-002-1: Given `foreman run submit` with an unknown `--backend`, when the backend is not installed, then the command fails with a descriptive error including installation instructions.
- AC-002-2: Given `foreman_work_submit` is called with an unknown `backend` field, when the backend is unknown, then the command fails with a descriptive error.
- AC-002-3: Given no `--backend` is specified, when the default backend is unavailable, then the command fails with a descriptive error.

### REQ-003: Three Curated Workflows

**Priority:** Must
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: prd workflow chains 4 ensemble steps in one worktree]

Foreman shall provide three named workflows: `prd`, `trd`, and `fix`.

- AC-003-1: Given `--workflow prd` and a feature prompt, when the run starts, then it executes create-prd → refine-prd (autonomous) → create-trd → implement-trd in one worktree and creates a PR.
- AC-003-2: Given `--workflow trd` and a path to an existing PRD, when the run starts, then it executes create-trd → implement-trd in one worktree and creates a PR.
- AC-003-3: Given `--workflow fix` and a bug/issue prompt, when the run starts, then it executes `ensemble-fix-issue` in one worktree and creates a PR.

### REQ-004: Worktree-Based Execution

**Priority:** Must
**Complexity:** Medium
**Type:** Functional

Runs shall execute inside a worktree created for the run.

- AC-004-1: Given a run starts, when no suitable worktree exists, then Foreman creates a new worktree for the run.
- AC-004-2: Given a run completes or fails, when the operator is absent, then the worktree is preserved with run artifacts until the operator reviews it.

### REQ-005: Run Recovery

**Priority:** Must
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: event stream must contain sufficient state for restart]

Foreman shall persist sufficient run state to the event stream to enable recovery after interruption.

- AC-005-1: Given a run is interrupted (JIDO backend failure, network loss), when the operator resumes, then Foreman restarts the run from the beginning using the event stream.
- AC-005-2: Given recovery is attempted, when run state is insufficient, then Foreman reports the failure clearly and does not silently lose work.
- AC-005-3: Given a run is in progress, when the operator checks status, then `foreman run get <id>` returns current state.

### REQ-006: Concurrency Limits

**Priority:** Must
**Complexity:** Low
**Type:** Functional

Foreman shall queue runs that exceed the parallel run limit. (Uses existing concurrency limit mechanism.)

- AC-006-1: Given a run is queued, when the number of active runs equals the concurrency limit, then the run waits for an available slot.
- AC-006-2: Given the concurrency limit is reached, when an active run completes, then queued runs are started in FIFO order.

### REQ-007: Logs and Artifacts

**Priority:** Must
**Complexity:** Low
**Type:** Functional

Run logs and artifacts shall be persisted and accessible.

- AC-007-1: Given a run is executing or complete, when the operator requests logs, then logs are available at `~/.foreman/logs/{run-id}`.
- AC-007-2: Given a run completes, when artifacts are produced, then they are accessible via `foreman run get <id>`.

### REQ-008: No Artificial Timeout

**Priority:** Should
**Complexity:** Low
**Type:** Non-Functional

Runs shall not be terminated by an artificial time limit.

- AC-008-1: Given a run is actively progressing (modifying files, executing phases), when it runs for an extended period, then Foreman does not terminate it automatically.

### REQ-009: Autonomous Recommendation Selection

**Priority:** Should
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: autonomous selection may not always be deterministically correct]

The PRD workflow shall autonomously select ensemble refinement recommendations without prompting the operator.

- AC-009-1: Given `--workflow prd` is executing, when refinement recommendations are available, then the workflow selects the top recommendation automatically.
- AC-009-2: Given autonomous selection is made, then Foreman logs the selection for operator review in run artifacts. If the operator disagrees, they cancel the run and queue a new one.
- AC-009-3: Given autonomous selection is not possible for a given step, when the workflow cannot determine the best path, then it logs the choice and proceeds with the default.

### REQ-010: JIDO as Orchestration Layer

**Priority:** Must
**Complexity:** Medium
**Type:** Functional

Foreman shall use JIDO as the constant orchestration layer for all run execution. The `--backend` field selects the model backend (pi/claude/codex/opencode/etc.) via jido-integration.

- AC-010-1: Given a run is submitted, when it starts, then JIDO is the orchestration layer (worktree, phases, event stream, recovery).
- AC-010-2: Given `--backend pi` (default), when the run executes, then jido-integration routes to the Pi model provider.
- AC-010-3: Given `--backend claude` (or other supported provider), when the run executes, then jido-integration routes to the named model provider.

### REQ-011: Automatic PR Creation

**Priority:** Must
**Complexity:** Medium
**Type:** Functional

Foreman shall automatically create a PR when a curated workflow completes.

- AC-011-1: Given a curated workflow (prd/trd/fix) reaches the final phase, when the phase completes, then Foreman creates a PR with the worktree branch.
- AC-011-2: Given PR creation fails, when the workflow ends, then the failure is logged and the operator is notified.

### REQ-012: Worktree Lifecycle — Preserve for Review

**Priority:** Must
**Complexity:** Low
**Type:** Functional

Foreman shall keep the worktree after run completion for operator review.

- AC-012-1: Given a run completes, when the operator is absent, then the worktree is preserved with all artifacts intact.
- AC-012-2: Given the operator is ready to clean up, when they invoke worktree cleanup, then the worktree is removed.

### REQ-013: Single Worktree for PRD Chain

**Priority:** Must
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: one worktree through 4 steps requires state carry-through]

The PRD workflow (create-prd → refine-prd → create-trd → implement-trd) shall execute in one worktree, carrying state throughout all four steps.

- AC-013-1: Given `--workflow prd` is executing, when step 1 (create-prd) completes, then the worktree carries the PRD artifact into step 2 without recreation.
- AC-013-2: Given step 2 (refine-prd) completes, when it selects recommendations autonomously, then the worktree carries the refined PRD into step 3.
- AC-013-3: Given step 3 (create-trd) completes, when the TRD is written, then the worktree carries the TRD into step 4.

### REQ-014: Backend-Agnostic Workflow Manifests (Phase 2)

**Priority:** Could
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: Phase 2 — requires ensemble modification]

The three curated workflows shall be expressible as single YAML manifests that work across all model backends without modification.

- AC-014-1: Phase 1 ships with JIDO + Pi (default via jido-integration). Backend-agnostic YAML manifests are Phase 2.

### REQ-015: Remove Legacy Workflows

**Priority:** Must
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: irreversible; requires interactive confirmation]

Foreman shall remove all existing workflow manifests and prompts. Only the three curated workflows (prd, trd, fix) remain.

- AC-015-1: Given the removal command is invoked, when the operator confirms interactively, then all legacy workflows are removed.
- AC-015-2: Given the operator does not confirm, when the removal command is invoked, then the command fails and no changes are made.
- AC-015-3: Given legacy workflows are removed, when recovery is needed, then the workflows can be restored from git.

### REQ-016: Work Submit CLI Command (Go)

**Priority:** Must
**Complexity:** Medium
**Type:** Functional

Foreman's Go CLI shall expose the `foreman_work_submit` MCP tool as `foreman run submit`.

- AC-016-1: Given valid arguments, when `foreman run submit` is called, then it POSTs to the server's MCP endpoint via the existing client.
- AC-016-2: Given invalid arguments, when `foreman run submit` is called, then it prints usage and exits non-zero.

### REQ-017: Phase Checkpoint Push

**Priority:** Must
**Complexity:** Medium
**Type:** Functional

After each phase completes, Foreman shall push the worktree state to the branch before proceeding.

- AC-017-1: Given a phase completes, when the next phase is ready to start, then the worktree state is pushed to the branch.
- AC-017-2: Given the final phase completes, when the workflow ends, then the push is followed by PR creation.

### REQ-018: Ensemble Backend-Agnostic Support (Phase 2)

**Priority:** Should
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: Phase 2 — requires ensemble modification in separate worktree]

Foreman's curated workflows require modifications to ensemble to support multi-backend execution. This workstream must be completed before Phase 2 curated workflows are operational. Any modifications to ensemble require a separate worktree (per operator instruction).

- AC-018-1: Phase 1 ships with JIDO + Pi only. Ensemble multi-backend support is Phase 2.

### REQ-019: PR Lifecycle

**Priority:** Must
**Complexity:** Low
**Type:** Functional

Foreman shall create a PR with a named branch targeting the appropriate base.

- AC-019-1: Given a curated workflow completes, when PR creation is triggered, then Foreman creates a PR with a branch named from workflow+work-id.
- AC-019-2: Given PR creation is triggered, when the base is determined, then the target/base is derived from run/worktree context or config (not hardcoded to default branch).
- AC-019-3: Given the PR is created, when review assignment is needed, then it is handled by existing GitHub/board integration.

---

## 7. Non-Functional Requirements

### NFR-001: Performance

**Priority:** Must

- Small features: idea-to-PR in <4 hours
- Medium/large features: scale proportionally with scope
- Time-to-first-worktree for a queued run: <60 seconds after a slot becomes available

### NFR-002: Observability

**Priority:** Must

- Every run state transition shall be visible via `foreman run get <id>`
- Run logs shall be persisted at `~/.foreman/logs/{run-id}` during and after execution
- Autonomous recommendation selections shall be logged in run artifacts

### NFR-003: Reliability

**Priority:** Must

- Runs shall survive JIDO backend restarts via event stream recovery
- Runs shall not be silently lost due to server crashes
- Worktree state shall be preserved for operator review after run completion

### NFR-004: Concurrency

**Priority:** Must**

- Existing concurrency limits apply: runs above the limit queue automatically
- FIFO ordering for queued runs when slots free up

---

## 8. Dependency Map

| REQ | Depends On | Notes |
|-----|------------|-------|
| REQ-003 (prd workflow) | REQ-013 | Must execute in one worktree |
| REQ-003 (prd workflow) | REQ-017 | Phase checkpoint push required |
| REQ-003 (prd workflow) | REQ-011 | PR auto-created |
| REQ-010 (JIDO orchestration) | REQ-002 | Backend must be available |
| REQ-011 (PR creation) | REQ-017 | After final phase push |
| REQ-013 (one worktree) | REQ-004 | Worktree created for run |
| REQ-014 (backend-agnostic) | REQ-018 | Ensemble Phase 2 dependency |
| REQ-016 (Go CLI) | REQ-001 | CLI wraps submit command |

---

## 9. Open Questions (Resolved)

| # | Question | Resolution |
|---|----------|------------|
| 1 | Backend selection mechanism | `--backend` CLI flag on `foreman run submit`; defaults to Pi (via jido-integration) |
| 2 | PR creation | Automatic at workflow end, after final phase push |
| 3 | Worktree cleanup | Worktree preserved for review; manual cleanup by operator |
| 4 | PRD workflow chaining | One worktree through all 4 steps |
| 5 | Existing workflows | Remove all legacy workflows with interactive confirmation |
| 6 | Backend-agnostic implementation | Phase 1: JIDO+Pi; Phase 2: full backend-agnostic |

---

## 10. Phase 1 Scope Summary

**In Scope (Phase 1):**
- `foreman run submit` Go CLI command
- `foreman_work_submit` MCP tool with `--backend` field
- Three curated workflows: prd, trd, fix
- JIDO orchestration layer (constant)
- Pi model backend (default via jido-integration)
- Phase checkpoint push after each phase
- Automatic PR creation after final phase
- Worktree preserved for review
- Run recovery via event stream (restart from beginning)
- Legacy workflow removal (interactive `--force` confirmation)
- Concurrency queue (existing mechanism)

**Out of Scope (Phase 2):**
- Backend-agnostic YAML manifests
- Full multi-backend support (claude/codex/opencode native routing)
- Ensemble modifications for multi-backend

---

## 11. Migration Notes

### Removing Legacy Workflows

1. List all workflows via `foreman workflow list`
2. Invoke `foreman workflow remove --all` (interactive confirmation required)
3. On confirmation: all legacy workflows deleted from catalog
4. On refusal: command exits, no changes
5. Recovery: `git checkout <commit>` of the removal to restore

### Task Dispatch (Retained)

Task-based dispatch (task create → task approve → ...) remains as a fallback. It is NOT removed. Operators may use either path.

---

*Generated via ensemble:create-prd — Phase 1 scope.*
