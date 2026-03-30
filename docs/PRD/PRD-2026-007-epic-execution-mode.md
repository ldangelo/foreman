---
document_id: PRD-2026-007
version: 1.0.0
status: Draft
date: 2026-03-30
scale_depth: STANDARD
total_requirements: 16
readiness_score: 4.25
---

# PRD-2026-007: Epic Execution Mode

## PRD Health Summary

| Metric | Value |
|--------|-------|
| Must | 10 |
| Should | 4 |
| Could | 2 |
| Won't | 0 |
| AC Coverage | 16/16 (100%) |
| Risk Flags | 3 |
| Dependencies | 8 cross-requirement |

## Readiness Scorecard

| Dimension | Score (1-5) | Notes |
|-----------|-------------|-------|
| Completeness | 4 | All feature areas covered; epic workflow, task loop, resume, and merge |
| Testability | 5 | ACs are specific and measurable with concrete targets |
| Clarity | 4 | Developer→QA loop and resume semantics clearly defined |
| Feasibility | 4 | Builds on existing pipeline-executor; main risk is Pi SDK session duration |
| **Overall** | **4.25** | **PASS** |

---

## 1. Executive Summary

Foreman currently treats every bead identically: one worktree, one 5-phase pipeline (explorer → developer → QA → reviewer → finalize), one merge. This model adds massive overhead for epics with many interdependent tasks — TRD-2026-006 (40 tasks) ran for 24+ hours at ~50% success rate, burning money on worktree setup, redundant exploration, merge-time test failures, and retry loops.

Epic Execution Mode introduces a second dispatch path: epics run as sequential task sessions in a single shared worktree, with a lightweight developer→QA loop per task. Tasks execute in dependency order, commits happen per-task, and push/merge happens only when the epic completes. The existing 5-phase pipeline remains for one-off tasks.

## 2. Problem Statement

**Who feels the pain:** Solo developers using foreman to execute TRD-derived work.

**The pain:**
- 40-task TRD took 24+ hours with ~50% success rate
- Each task creates a new worktree (~30s setup), runs 5 phases (~10-15 min), attempts merge (~2 min) — minimum 12 min per task even when everything works
- Explorer phase is redundant after the first task (agent already knows the codebase)
- Reviewer phase adds latency without proportional value for small, related changes
- Merge-time test failures are caused by concurrent branches diverging from dev
- Empty commits, stale workspace metadata, and blocked_issues_cache staleness compound failures
- $5+ burned on a single spinning QA agent with no circuit breaker

**Root cause:** Foreman's dispatch model assumes tasks are independent. Epics are not — they're sequential, interdependent, and benefit from shared context.

## 3. Goals and Non-Goals

### Goals
- Execute a 40-task TRD in under 2 hours with 95%+ first-attempt success rate
- Zero empty commits on the integration branch
- Maintain the existing 5-phase pipeline for one-off tasks (backward compatible)
- Support multiple epics running in parallel on separate worktrees
- Resume from the last completed task after a crash or rate limit
- Provide per-task progress visibility and traceability via beads

### Non-Goals
- Replacing the 5-phase pipeline entirely (it's appropriate for one-off, high-risk changes)
- Cross-epic task parallelism (tasks within an epic are sequential by design)
- Automatic TRD parsing (use `foreman sling` to create beads first, then dispatch the epic)
- Multi-agent collaboration within an epic (one agent session handles the full epic)

## 4. User Personas

**Foreman Operator (Solo Developer)**
- Runs `foreman sling` to create task hierarchies from TRDs
- Runs `foreman run` to dispatch work to AI agents
- Monitors progress via `foreman dashboard`
- Intervenes when agents get stuck or produce bad output
- Wants to go to bed and wake up to completed work

## 5. Solution Overview

```
                    ┌─────────────────────────────────┐
                    │         Dispatcher               │
                    │                                   │
                    │  Epic bead? ──yes──► Epic Runner  │
                    │      │                    │       │
                    │      no           shared worktree │
                    │      │            task 1 → task N │
                    │      ▼            dev→QA per task │
                    │  Pipeline Runner  commit per task │
                    │  (current model)  push at end     │
                    └─────────────────────────────────┘
```

**Epic Runner** creates one worktree, loads the epic's child tasks in dependency order (via `bv --robot-next` or topological sort), and executes each task through a lightweight developer→QA loop. On QA failure, it creates a bug bead for traceability and loops back to developer. After all tasks complete, it runs finalize once (commit, rebase, push, merge).

---

## 6. Requirements: Epic Detection and Dispatch

### REQ-001: Epic bead detection in dispatcher
**Priority:** Must | **Complexity:** Low

When the dispatcher encounters a bead of type `epic` with child tasks (parent-child dependents), it dispatches via the Epic Runner instead of the standard pipeline. One-off tasks (type `task`, `bug`, `chore`) continue using the standard pipeline.

- AC-001-1: Given a ready bead with type `epic` and 3+ child task beads, when `foreman run` executes, then the dispatcher creates a single worktree and spawns an Epic Runner process.
- AC-001-2: Given a ready bead with type `task`, when `foreman run` executes, then the dispatcher uses the standard 5-phase pipeline (no behavioral change).
- AC-001-3: Given a ready bead with type `epic` and 0 child tasks, when `foreman run` executes, then the dispatcher auto-closes it (existing behavior).

### REQ-002: Epic workflow YAML configuration
**Priority:** Must | **Complexity:** Medium

Epic execution uses a dedicated workflow YAML (`epic.yaml`) that defines the per-task phase loop. The workflow specifies which phases run per task (developer, QA), model selection, retry limits, and the finalize phase that runs once at the end.

- AC-002-1: Given a workflow file `src/defaults/workflows/epic.yaml` with `taskPhases: [developer, qa]` and `finalPhases: [finalize]`, when an epic is dispatched, then each task runs only developer→QA and finalize runs once after all tasks.
- AC-002-2: Given an epic workflow with `taskPhases.qa.retryOnFail: 2`, when QA fails on a task, then developer is retried up to 2 times before the task is marked failed.
- AC-002-3: Given no `epic.yaml` in the project or bundled defaults, when an epic is dispatched, then a sensible default is used: `taskPhases: [developer, qa]`, `retryOnFail: 2`, `finalPhases: [finalize]`.

### REQ-003: Parallel epic execution
**Priority:** Must | **Complexity:** Medium

Multiple epics can run simultaneously, each in its own worktree. The dispatcher treats epic runners as occupying one agent slot each (not one slot per task).

- AC-003-1: Given 2 ready epics and `maxAgents: 5`, when `foreman run` dispatches, then both epics start in parallel on separate worktrees, consuming 2 of 5 agent slots.
- AC-003-2: Given 1 running epic and 3 ready one-off tasks with `maxAgents: 5`, when `foreman run` dispatches, then all 4 are running (1 epic + 3 one-off tasks).

---

## 7. Requirements: Task Execution Loop

### REQ-004: Sequential task execution in dependency order
**Priority:** Must | **Complexity:** High | [RISK: bv availability]

Within an epic, tasks execute sequentially in dependency order. The Epic Runner queries `bv --robot-next` (or falls back to topological sort of child beads) to determine execution order.

- AC-004-1: Given an epic with tasks A→B→C (B depends on A, C depends on B), when the epic executes, then tasks run in order A, B, C.
- AC-004-2: Given `bv` is unavailable, when the epic determines task order, then it falls back to topological sort of parent-child dependencies with priority as tiebreaker.
- AC-004-3: Given an epic with 40 tasks, when all tasks complete successfully, then total execution time is under 2 hours (target: ~3 min per task average).

### REQ-005: Per-task developer→QA loop
**Priority:** Must | **Complexity:** Medium

Each task runs through a developer phase (implementation) followed by a QA phase (test verification). The QA phase parses a verdict from the QA artifact. On FAIL, it loops back to developer with the failure context.

- AC-005-1: Given a task in an epic, when the developer phase completes, then QA runs `npm test` and writes a verdict artifact.
- AC-005-2: Given a QA FAIL verdict with `retryOnFail: 2`, when the developer has not yet retried twice, then developer re-runs with the QA feedback as context.
- AC-005-3: Given a QA PASS verdict, when the task completes, then it is committed and the next task begins.

### REQ-006: Bug bead creation on QA failure
**Priority:** Must | **Complexity:** Low

When QA detects a test failure, a bug bead is created for traceability before looping back to developer. The bug bead links to the epic and the failing task.

- AC-006-1: Given a QA FAIL verdict on task N, when the retry loop fires, then a bug bead is created with title "QA failure in <task title>", type `bug`, and parent set to the epic.
- AC-006-2: Given a bug bead created by QA failure, when the developer fixes the issue and QA passes, then the bug bead is auto-closed.

### REQ-007: Per-task commits in shared worktree
**Priority:** Must | **Complexity:** Low

After each task passes QA, changes are committed to the shared worktree branch. Commits use the task title and bead ID as the commit message. No push until the epic completes.

- AC-007-1: Given task N passes QA, when the commit runs, then a git commit is created with message `<task title> (<bead-id>)`.
- AC-007-2: Given 10 tasks complete, when inspecting the worktree branch, then there are exactly 10 commits (no empty commits, no extra jj working revisions).

### REQ-008: Session continuity across tasks
**Priority:** Must | **Complexity:** Medium | [RISK: Pi SDK session token limits]

The Epic Runner maintains a single Pi SDK session across all tasks in the epic. Each task's prompt is injected into the existing session, preserving the agent's context about previous work.

- AC-008-1: Given task 5 is starting after tasks 1-4 completed, when the developer prompt is sent, then the agent has access to conversation history from tasks 1-4.
- AC-008-2: Given the Pi SDK session reaches a token limit, when the session must be refreshed, then the Epic Runner creates a new session with a summary of completed work and continues from the current task.

---

## 8. Requirements: Finalize and Merge

### REQ-009: Single finalize at epic completion
**Priority:** Must | **Complexity:** Medium

When all tasks in the epic pass QA, a single finalize phase runs: rebase onto the target branch, run full test suite, push, and trigger merge. This replaces the per-task finalize in the standard pipeline.

- AC-009-1: Given all 40 tasks completed and committed, when finalize runs, then it rebases onto dev, runs `npm test`, and pushes as a single branch.
- AC-009-2: Given finalize's test suite fails after rebase, when the verdict is FAIL, then the Epic Runner loops back to developer with the test output (same as standard pipeline verdict retry).
- AC-009-3: Given finalize pushes successfully, when the refinery merges the branch, then dev receives a single squash-merge commit for the entire epic.

---

## 9. Requirements: Resume and Recovery

### REQ-010: Resume from last completed task
**Priority:** Must | **Complexity:** High | [RISK: session state reconstruction]

When an epic run is interrupted (rate limit, crash, OOM), it can be resumed from the last completed task. The Epic Runner checks which tasks have commits in the worktree and skips them.

- AC-010-1: Given an epic run interrupted after task 15 of 40, when `foreman run` or `foreman retry` re-dispatches the epic, then tasks 1-15 are skipped (their commits exist in the worktree) and execution resumes from task 16.
- AC-010-2: Given a resumed epic with a partially completed task 16 (developer done, QA not run), when the epic resumes, then task 16 restarts from developer (partial tasks are not skipped).

### REQ-011: Per-task bead status updates
**Priority:** Should | **Complexity:** Low

As each task completes within an epic, its bead is updated to reflect progress. This provides visibility in `foreman status` and `foreman dashboard`.

- AC-011-1: Given task N starts, when the Epic Runner begins it, then the bead status is set to `in_progress`.
- AC-011-2: Given task N passes QA and is committed, when the next task starts, then task N's bead status is set to `completed` (or equivalent closed state after merge).

---

## 10. Requirements: Observability

### REQ-012: Epic progress in foreman status
**Priority:** Should | **Complexity:** Low

`foreman status` shows epic-level progress: total tasks, completed tasks, current task, elapsed time.

- AC-012-1: Given an epic with 40 tasks where 15 are complete, when `foreman status` runs, then it shows `bd-zcyl [EPIC] 15/40 tasks, current: bd-zcyl.3.1.2, elapsed: 42m`.

### REQ-013: Epic cost tracking
**Priority:** Should | **Complexity:** Low

Track and display aggregate cost across all tasks in the epic, broken down by task.

- AC-013-1: Given an epic that has completed 10 tasks, when `foreman status` displays the epic, then total cost and per-task cost breakdown are shown.

### REQ-014: onError behavior for epics
**Priority:** Should | **Complexity:** Low

The `onError: stop` workflow config applies to epic runs. If a task within an epic fails after exhausting retries, the epic stops and the bead is marked stuck.

- AC-014-1: Given a task that fails QA after max retries, when `onError: stop` is set, then the epic halts, the run is marked stuck, and `foreman status` shows which task failed.
- AC-014-2: Given a stuck epic, when `foreman retry <epic-id>` runs, then the epic resumes from the failed task.

---

## 11. Requirements: Configuration

### REQ-015: Epic workflow override per project
**Priority:** Could | **Complexity:** Low

Projects can override the default epic workflow via `.foreman/workflows/epic.yaml`.

- AC-015-1: Given a project-local `epic.yaml` with `taskPhases: [developer, qa, reviewer]`, when an epic runs in that project, then each task goes through developer→QA→reviewer instead of the default developer→QA.

### REQ-016: Max task duration timeout
**Priority:** Could | **Complexity:** Low

Individual tasks within an epic have a configurable timeout. If a task exceeds the timeout, it is marked as failed and the epic's onError policy applies.

- AC-016-1: Given `taskTimeout: 300` (seconds) in the epic workflow, when a task's developer phase exceeds 5 minutes, then the task is terminated, marked failed, and the epic's onError policy applies.

---

## 12. Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|-----|-------------|----------|------------|----------|
| REQ-001 | Epic bead detection | Must | Low | 3 |
| REQ-002 | Epic workflow YAML | Must | Medium | 3 |
| REQ-003 | Parallel epic execution | Must | Medium | 2 |
| REQ-004 | Sequential task execution | Must | High | 3 |
| REQ-005 | Per-task dev→QA loop | Must | Medium | 3 |
| REQ-006 | Bug bead on QA failure | Must | Low | 2 |
| REQ-007 | Per-task commits | Must | Low | 2 |
| REQ-008 | Session continuity | Must | Medium | 2 |
| REQ-009 | Single finalize | Must | Medium | 3 |
| REQ-010 | Resume from last task | Must | High | 2 |
| REQ-011 | Per-task bead status | Should | Low | 2 |
| REQ-012 | Epic progress display | Should | Low | 1 |
| REQ-013 | Epic cost tracking | Should | Low | 1 |
| REQ-014 | onError for epics | Should | Low | 2 |
| REQ-015 | Workflow override | Could | Low | 1 |
| REQ-016 | Task timeout | Could | Low | 1 |

## 13. Dependency Map

| REQ | Depends On | Notes |
|-----|-----------|-------|
| REQ-003 | REQ-001 | Can't run epics in parallel until detection works |
| REQ-004 | REQ-001, REQ-002 | Task ordering requires epic detection and workflow config |
| REQ-005 | REQ-004 | Dev→QA loop operates within the task execution loop |
| REQ-006 | REQ-005 | Bug beads created on QA failure |
| REQ-007 | REQ-005 | Commits happen after QA passes |
| REQ-008 | REQ-004 | Session continuity spans the task loop |
| REQ-009 | REQ-007 | Finalize runs after all per-task commits |
| REQ-010 | REQ-007, REQ-004 | Resume checks existing commits to determine start point |

## 14. Implementation Strategy

### Sprint 1: Core Epic Runner (REQ-001, REQ-002, REQ-004, REQ-005, REQ-007)
Dispatcher detects epics, creates shared worktree, Epic Runner executes tasks sequentially with dev→QA loop. Commits per task.

### Sprint 2: Finalize and Resume (REQ-009, REQ-010, REQ-008)
Single finalize at end, resume from last completed task, session continuity.

### Sprint 3: Observability and Polish (REQ-003, REQ-006, REQ-011-016)
Parallel epics, bug bead traceability, status display, cost tracking, configuration.

**Cross-cutting concern:** The existing `pipeline-executor.ts` phase loop can be reused for the per-task dev→QA execution — the Epic Runner orchestrates which tasks to run and calls the phase loop for each one.
