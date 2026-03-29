# PRD-2026-005: Mid-Pipeline Rebase and Shared Worktree Mode

**Document ID:** PRD-2026-005
**Version:** 1.0
**Status:** Draft
**Date:** 2026-03-29
**Author:** Product Management
**Stakeholders:** Engineering (Foreman maintainers), Foreman operators
**Requirements:** 19 (REQ-001 through REQ-019)

---

## Version History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-03-29 | Product Management | Initial draft. Covers mid-pipeline rebase (v1), workflow YAML configuration, shared worktree mode (v2 scoping), and observability. 19 requirements, 48 acceptance criteria. Adversarial review pre-resolved. |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Statement](#2-problem-statement)
3. [Goals and Non-Goals](#3-goals-and-non-goals)
4. [User Personas](#4-user-personas)
5. [Current State Analysis](#5-current-state-analysis)
6. [Solution Overview](#6-solution-overview)
7. [Functional Requirements -- Part 1: Mid-Pipeline Rebase](#7-functional-requirements----part-1-mid-pipeline-rebase)
8. [Functional Requirements -- Part 2: Workflow YAML Configuration](#8-functional-requirements----part-2-workflow-yaml-configuration)
9. [Functional Requirements -- Part 3: Shared Worktree Mode (v2 Scoping)](#9-functional-requirements----part-3-shared-worktree-mode-v2-scoping)
10. [Functional Requirements -- Part 4: Observability](#10-functional-requirements----part-4-observability)
11. [Non-Functional Requirements](#11-non-functional-requirements)
12. [Implementation Strategy](#12-implementation-strategy)
13. [Risks and Mitigations](#13-risks-and-mitigations)
14. [Acceptance Criteria Summary](#14-acceptance-criteria-summary)
15. [Success Metrics](#15-success-metrics)
16. [Release Plan](#16-release-plan)
17. [Open Questions](#17-open-questions)

---

## 1. Executive Summary

Approximately 50% of Foreman pipeline runs currently fail at the finalize or merge stage due to merge conflicts with the `dev` branch. Each failure requires a manual `foreman reset` or `foreman retry`, burning all prior pipeline phases (explorer, developer, QA, reviewer) for zero new output. Because Foreman is operated solo, the operator bears the full remediation cost in both time and token spend.

This PRD introduces **mid-pipeline rebase** (v1): a rebase step inserted after the developer phase and before QA that surfaces merge conflicts while the developer agent still has context to resolve them. Auto-resolvable conflicts are handled immediately; conflicts that cannot be auto-resolved escalate to the troubleshooter agent (introduced in PRD phase bd-xfyh). If resolved, the pipeline resumes from the developer phase -- not from scratch. QA then tests the already-rebased worktree, naturally validating the merged result.

A second complementary approach, **shared worktree mode** (v2), is scoped in this PRD for future delivery: tasks within the same story share one branch and execute serially, eliminating intra-story conflicts entirely at the cost of parallelism. v2 is marked Could/Won't for this release.

The primary success metric is reducing conflict-driven retries from ~50% to under 10% of pipeline runs.

---

## 2. Problem Statement

### 2.1 Late Conflict Detection

The current Foreman pipeline inserts a rebase step only during finalize, immediately before pushing the completed branch. By this point, the developer agent has finished its work, QA has run, and the reviewer has signed off. If the rebase conflicts:

1. The pipeline fails with status `failed` or `stuck`.
2. The operator runs `foreman reset --bead <id>` and then `foreman retry <seed>`.
3. The retry re-runs every phase from explorer onward, including the developer, QA, and reviewer -- phases whose work was entirely valid before the conflict.
4. Token cost per retry is substantial (explorer + developer + QA + reviewer = 4 phase budgets consumed for no new value).

At a ~50% conflict rate, roughly half of all successful pipeline completions are immediately discarded and re-run, doubling average token spend per delivered task.

### 2.2 No Developer Context at Conflict Time

When a rebase conflict is detected at finalize, the developer agent session has long since ended. The only available response is pipeline failure. The developer agent cannot be consulted because its session context is gone.

If the rebase were to occur earlier -- while the developer agent is still active or can be cheaply resumed -- the conflict can be resolved in-place and the pipeline can continue.

### 2.3 QA Tests Stale State

When QA runs today, it tests the developer's worktree before the finalize rebase. If the rebase later changes the test surface (upstream additions, behavior changes), QA's pass verdict may not reflect the merged state. Moving the rebase before QA ensures QA always tests the actual combined result.

### 2.4 Intra-Story Conflicts (Secondary)

Tasks within the same story frequently modify the same files. Because each task gets its own worktree and executes in parallel, two sibling tasks will diverge from each other and conflict at merge time regardless of whether they conflict with `dev`. This is a separate problem not fully addressed by mid-pipeline rebase alone. Shared worktree mode (v2) addresses this by serializing execution within a story.

---

## 3. Goals and Non-Goals

### 3.1 Goals

1. **Add a mid-pipeline rebase step** after the developer phase and before QA in the default pipeline, using the existing `VcsBackend.rebase()` interface.
2. **Auto-resolve the rebase** and continue transparently when there are no conflicts.
3. **Surface conflicts to the developer agent** while context is still relevant, by marking the run `rebase_conflict` and resuming from the developer phase if the troubleshooter resolves the conflict.
4. **Enrich QA with rebase context** by sending a diff summary of upstream changes to the QA agent after rebase, enabling QA to detect stale or redundant work.
5. **Make mid-pipeline rebase configurable** per workflow via a `rebaseAfterPhase` key in workflow YAML, defaulting to off for backward compatibility.
6. **Scope shared worktree mode** as a future v2 feature with clear interface pre-requisites.
7. **Add run status and dashboard visibility** for the new `rebase_conflict` state.

### 3.2 Non-Goals

1. **Pre-flight conflict prediction** (file-lock analysis, speculative diff checking) -- not attempted; mid-pipeline rebase is the chosen approach.
2. **Automatic conflict resolution without developer agent involvement** -- auto-merge of non-conflicting changes only; conflicted files always escalate.
3. **Changing the finalize rebase** -- the existing finalize rebase-before-push is retained as a safety net. This PRD adds a second, earlier rebase, not a replacement.
4. **Implementing shared worktree mode (v2) in this release** -- scoped for future delivery; this PRD defines the interface constraints only.
5. **Multi-operator support** -- Foreman is a solo-operator tool; no concurrency controls for multiple humans are needed.
6. **Non-default workflow changes** -- workflows not using `rebaseAfterPhase` are entirely unaffected.

---

## 4. User Personas

### 4.1 Solo Operator (Primary)

**Name:** Lane, Solo Engineering Operator
**Context:** Runs Foreman continuously on a TypeScript monorepo. Dispatches 10-20 tasks per day. Tolerates agent imperfection but not systematic waste. Each failed retry costs ~$0.50-$2.00 in API tokens and 15-30 minutes of wall-clock time.
**Pain Point:** Approximately half of all pipeline completions trigger a conflict-driven retry. The operator's evening is routinely spent re-running pipelines that failed at finalize over a conflict that could have been caught and fixed mid-flight.
**Needs:** Pipelines that surface conflicts early, resolve them automatically where possible, and resume without re-running all phases from scratch.

### 4.2 Workflow Author

**Name:** Jamie, Platform Engineer
**Context:** Maintains custom workflow YAML files for different task types. Some workflows target high-parallelism (many concurrent tasks on different files); others are sequential within a story.
**Needs:** Opt-in control over mid-pipeline rebase per workflow. Ability to set rebase target per workflow. Ability to configure shared worktree mode for story-level workflows in the future.

---

## 5. Current State Analysis

### 5.1 Pipeline Execution Flow (Today)

```
Dispatcher
  └─> createWorkspace(seedId)          # VcsBackend.createWorkspace()
        └─> explorer phase             # EXPLORER_REPORT.md
              └─> developer phase      # DEVELOPER_REPORT.md
                    └─> QA phase       # QA_REPORT.md (PASS/FAIL)
                          └─> reviewer phase    # REVIEW.md (PASS/FAIL)
                                └─> finalize phase
                                      ├─> git fetch + rebase onto origin/dev   <-- ONLY rebase today
                                      ├─> git push
                                      └─> refinery merges to dev
```

**Failure mode:** If `origin/dev` has diverged significantly between workspace creation and finalize, the rebase in finalize conflicts. The pipeline fails, and the operator retries from scratch.

### 5.2 Relevant Source Locations

| Component | Path | Relevance |
|-----------|------|-----------|
| Pipeline executor | `src/orchestrator/pipeline-executor.ts` | YAML-driven phase sequence; must insert rebase between phases |
| Agent worker | `src/orchestrator/agent-worker.ts` | Orchestrates phases; calls `onPipelineComplete` and `onPipelineFailure` |
| Finalize | `src/orchestrator/agent-worker-finalize.ts` | Current rebase-before-push logic (retained) |
| VCS interface | `src/lib/vcs/interface.ts` | `rebase()`, `getConflictingFiles()`, `abortRebase()` already present |
| Run store | `src/lib/store.ts` | `runs` table; `status` field needs `rebase_conflict` value |
| Agent mail | `src/lib/sqlite-mail-client.ts` | `send_mail` tool; new `rebase-context` mail type needed |
| Dispatcher | `src/orchestrator/dispatcher.ts` | Creates workspaces; must check for shared-branch active runs (v2) |
| Troubleshooter | `onFailure.troubleshooter` | Existing resolve-conflict skill; target for mid-pipeline escalation |

### 5.3 Conflict Rate Baseline

- Observed conflict rate at finalize: ~50% of pipeline runs
- Recovery path today: manual `foreman reset` + `foreman retry` (full re-run)
- Target conflict-driven retry rate: < 10% after mid-pipeline rebase ships

---

## 6. Solution Overview

### 6.1 Mid-Pipeline Rebase Architecture

```
... developer phase completes ...
           |
           v
  pipeline-executor: rebaseAfterPhase hook
           |
           v
  vcs.rebase(target: origin/<targetBranch>)
           |
      no conflicts?
           |
     YES   |   NO
     |     |   |
     v         v
  send rebase-context    mark run status: rebase_conflict
  mail to QA agent       escalate to troubleshooter
     |                          |
     v                    resolved? YES -> resume from developer
  QA phase continues      resolved? NO  -> pipeline fails (permanent)
```

### 6.2 Key Design Decisions

**Decision: Trigger via `rebaseAfterPhase` YAML key**
Pipeline-executor checks after each phase whether a `rebaseAfterPhase` matches the completed phase name. If it matches, the rebase is performed before dispatching the next phase. No hardcoded phase names in the executor.

**Decision: Resume from developer, not from scratch**
When the troubleshooter resolves a `rebase_conflict`, the pipeline re-runs the developer phase with the resolved worktree state. Explorer output is preserved and forwarded. This avoids re-running the most expensive phases.

**Decision: Rebase target defaults to `origin/dev`**
Consistent with the finalize rebase target today. Configurable per workflow via `rebaseTarget` key. Respects the `VcsBackend` abstraction -- no direct git/jj calls outside the backend.

**Decision: QA receives upstream diff summary**
After a clean rebase (no conflicts), pipeline-executor computes the diff of upstream changes pulled in by the rebase and sends it to the QA agent as a `rebase-context` mail. QA can then assess whether upstream changes affect the test plan. This is new behavior -- QA currently tests the developer's original worktree without awareness of what changed upstream.

### 6.3 Shared Worktree Mode (v2 Overview)

In v2, the dispatcher checks whether a task belongs to a story that has an active shared worktree. If so, the task is queued until the worktree is free, then dispatched to the existing branch/worktree in serial. One finalize per story. Intra-story conflicts are eliminated because tasks never run concurrently on the same branch.

v2 is **Could/Won't** for this release. Interface constraints (dispatcher queuing API, shared workspace registry in SQLite) are documented here to avoid design rework.

---

## 7. Functional Requirements -- Part 1: Mid-Pipeline Rebase

### REQ-001: Mid-Pipeline Rebase Execution

**Priority:** P0 (critical)
**MoSCoW:** Must
**Type:** Feature

After the phase named in `rebaseAfterPhase` completes successfully, the pipeline executor shall call `vcs.rebase(target)` via the `VcsBackend` interface before dispatching the next phase. The rebase shall fetch from the remote before rebasing to ensure the target ref is current.

**Acceptance Criteria:**

- **AC-001-1:** Given a workflow with `rebaseAfterPhase: developer`, when the developer phase completes with status `success`, then `vcs.rebase('origin/dev')` is called before the QA phase begins.
- **AC-001-2:** Given the mid-pipeline rebase returns no conflicts, when the next phase (QA) is dispatched, then the phase runs against the rebased worktree state -- not the pre-rebase state.
- **AC-001-3:** Given no `rebaseAfterPhase` is configured in the workflow YAML, when any phase completes, then no mid-pipeline rebase is performed and pipeline behavior is identical to today.
- **AC-001-4:** Given the mid-pipeline rebase call, when `vcs.rebase()` is invoked, then it uses the `VcsBackend` interface exclusively -- no direct `git rebase` or `jj rebase` calls in `pipeline-executor.ts`.

### REQ-002: Conflict Detection and Run Status Transition

**Priority:** P0 (critical)
**MoSCoW:** Must
**Type:** Feature

When `vcs.rebase()` returns a non-empty conflict list, the pipeline executor shall immediately halt phase progression, mark the run status as `rebase_conflict` in the SQLite store, and emit a structured conflict event.

**Acceptance Criteria:**

- **AC-002-1:** Given a mid-pipeline rebase that produces conflicting files, when `vcs.getConflictingFiles()` returns a non-empty array, then the run's `status` field in the `runs` table is updated to `rebase_conflict` before any further action is taken.
- **AC-002-2:** Given the run is marked `rebase_conflict`, when `foreman status` is run, then the run appears with status `rebase_conflict` and the list of conflicting files is shown.
- **AC-002-3:** Given a `rebase_conflict` run, when `foreman reset --bead <id>` is run, then the run is reset to `open` status (consistent with existing reset behavior for failed runs).

### REQ-003: Troubleshooter Escalation

**Priority:** P0 (critical)
**MoSCoW:** Must
**Type:** Feature

When a mid-pipeline rebase conflict is detected, the pipeline executor shall trigger the troubleshooter agent's `resolve-conflict` skill, passing the list of conflicting files and the worktree path. The troubleshooter operates within the same worktree.

**Acceptance Criteria:**

- **AC-003-1:** Given a `rebase_conflict` run, when the troubleshooter is invoked, then it receives the worktree path, the rebase target branch, and the full list of conflicting file paths from `vcs.getConflictingFiles()`.
- **AC-003-2:** Given the troubleshooter resolves all conflicts and signals success, when the pipeline resumes, then it re-runs the developer phase using the resolved worktree state (not explorer -- explorer output is preserved and forwarded).
- **AC-003-3:** Given the troubleshooter fails to resolve all conflicts (permanent failure), when the troubleshooter signals failure, then `vcs.abortRebase()` is called, the run is marked `failed`, and no further phase dispatch occurs.

### REQ-004: Pipeline Resume After Conflict Resolution

**Priority:** P0 (critical)
**MoSCoW:** Must
**Type:** Feature

After a successful mid-pipeline conflict resolution, the pipeline shall resume from the developer phase without re-running the explorer phase. The existing `EXPLORER_REPORT.md` artifact shall be forwarded to the resumed developer phase as context.

**Acceptance Criteria:**

- **AC-004-1:** Given a `rebase_conflict` run where the troubleshooter succeeds, when the pipeline resumes, then the developer phase receives a mail containing the original `EXPLORER_REPORT.md` artifact content and a note that a conflict was resolved.
- **AC-004-2:** Given the pipeline resumes from developer, when the developer completes, then the mid-pipeline rebase step fires again (the rebase hook is not skipped on resume -- it must re-verify the resolved state is clean).
- **AC-004-3:** Given a resume attempt, when the resumed developer phase fails QA a second time after the max `retryOnFail` count, then the run transitions to `failed` (not another troubleshooter escalation -- one conflict resolution attempt per run).

### REQ-005: QA Rebase-Context Mail

**Priority:** P1 (high)
**MoSCoW:** Must
**Type:** Feature

After a clean mid-pipeline rebase (no conflicts), the pipeline executor shall send a `rebase-context` mail to the QA agent containing a summary of upstream changes introduced by the rebase. The QA agent shall use this to assess whether upstream changes affect the test plan.

**Acceptance Criteria:**

- **AC-005-1:** Given a clean mid-pipeline rebase, when the QA phase is dispatched, then the QA agent's mailbox contains a `rebase-context` message before its session begins.
- **AC-005-2:** Given the `rebase-context` mail, when it is delivered, then it includes: the rebase target ref, the number of upstream commits pulled in, and a file-level diff summary (list of files changed upstream with change type: added/modified/deleted).
- **AC-005-3:** Given the mid-pipeline rebase pulls in zero upstream commits (already up-to-date), when QA is dispatched, then no `rebase-context` mail is sent (no noise for trivial rebases).

### REQ-006: VcsBackend Rebase Method Compatibility

**Priority:** P1 (high)
**MoSCoW:** Must
**Type:** Architecture

The mid-pipeline rebase shall use only methods already defined in `VcsBackend`: `rebase()`, `getConflictingFiles()`, and `abortRebase()`. No new interface methods are required for v1. Both `GitBackend` and `JujutsuBackend` implementations shall support mid-pipeline rebase without modification to their core logic.

**Acceptance Criteria:**

- **AC-006-1:** Given `GitBackend` is active, when the mid-pipeline rebase fires, then `GitBackend.rebase()` is called and behaves identically to the finalize rebase call today (fetch + rebase onto target).
- **AC-006-2:** Given `JujutsuBackend` is active, when the mid-pipeline rebase fires, then `JujutsuBackend.rebase()` is called and the jj-specific rebase logic executes without modification to the pipeline executor.
- **AC-006-3:** Given `vcs.rebase()` returns a `RebaseResult` with `conflicts: true`, when `vcs.getConflictingFiles()` is called immediately after, then it returns a non-empty list of conflicting file paths for both backends.

---

## 8. Functional Requirements -- Part 2: Workflow YAML Configuration

### REQ-007: `rebaseAfterPhase` Configuration Key

**Priority:** P0 (critical)
**MoSCoW:** Must
**Type:** Configuration

The workflow YAML schema shall support a top-level `rebaseAfterPhase` key that names the phase after which the mid-pipeline rebase fires. The key is optional; omitting it disables mid-pipeline rebase entirely.

```yaml
name: default
rebaseAfterPhase: developer     # optional; mid-pipeline rebase fires after this phase
rebaseTarget: origin/dev        # optional; defaults to origin/<defaultBranch>
phases:
  - name: explorer
    ...
  - name: developer
    ...
  - name: qa
    ...
```

**Acceptance Criteria:**

- **AC-007-1:** Given a workflow YAML with `rebaseAfterPhase: developer`, when the workflow is loaded by `workflow-loader.ts`, then the parsed workflow object includes `rebaseAfterPhase: 'developer'`.
- **AC-007-2:** Given a workflow YAML with no `rebaseAfterPhase` key, when the workflow is loaded, then `rebaseAfterPhase` is `undefined` and the pipeline executor performs no mid-pipeline rebase.
- **AC-007-3:** Given a workflow YAML where `rebaseAfterPhase` names a phase that does not exist in the `phases` list, when the workflow is loaded, then `workflow-loader.ts` throws a validation error identifying the unknown phase name.

### REQ-008: `rebaseTarget` Configuration Key

**Priority:** P1 (high)
**MoSCoW:** Should
**Type:** Configuration

The workflow YAML schema shall support an optional `rebaseTarget` key specifying the full remote ref to rebase onto. When absent, the target defaults to `origin/<defaultBranch>` where `defaultBranch` is the value returned by `VcsBackend.detectDefaultBranch()`.

**Acceptance Criteria:**

- **AC-008-1:** Given a workflow with `rebaseTarget: origin/main`, when the mid-pipeline rebase fires, then `vcs.rebase('origin/main')` is called regardless of what `detectDefaultBranch()` returns.
- **AC-008-2:** Given a workflow with no `rebaseTarget` key, when the mid-pipeline rebase fires, then the target is constructed as `origin/<VcsBackend.detectDefaultBranch()>`.
- **AC-008-3:** Given a workflow with `rebaseTarget: origin/dev`, when the finalize phase runs its own rebase, then the finalize rebase also uses `origin/dev` as the target (rebaseTarget applies to both rebase invocations for consistency).

### REQ-009: Default Workflow Update

**Priority:** P2 (medium)
**MoSCoW:** Should
**Type:** Configuration

The default workflow (`src/defaults/workflows/default.yaml`) shall be updated to include `rebaseAfterPhase: developer` and `rebaseTarget: origin/dev` as opt-in examples in a comment block, but shall NOT enable them by default. Existing behavior is preserved unless the operator explicitly opts in.

**Acceptance Criteria:**

- **AC-009-1:** Given the default workflow YAML as shipped, when a pipeline runs with no project-level overrides, then no mid-pipeline rebase occurs (backward compatibility guaranteed).
- **AC-009-2:** Given the default workflow YAML, when an operator uncomments `rebaseAfterPhase: developer`, then the mid-pipeline rebase activates on all subsequent pipeline runs using that workflow.

---

## 9. Functional Requirements -- Part 3: Shared Worktree Mode (v2 Scoping)

### REQ-010: Shared Worktree Mode -- Dispatcher Queuing Interface (Pre-Requisite Spec)

**Priority:** P3 (low)
**MoSCoW:** Could (Won't in this release)
**Type:** Architecture

The dispatcher shall support a future `sharedWorktree: true` mode per workflow in which all tasks belonging to the same story share a single branch and worktree. Dispatch of subsequent tasks in the story is queued until the worktree is idle. This requirement specifies the interface contract only; implementation is deferred.

**Acceptance Criteria:**

- **AC-010-1:** Given `sharedWorktree: true` in the workflow YAML, when the dispatcher encounters a task whose story already has an active run, then the task is placed in a `queued` state in the runs table rather than immediately dispatched.
- **AC-010-2:** Given a shared worktree run completes, when the next queued task for the same story is dispatched, then it receives the existing worktree path and branch name rather than creating a new workspace.
- **AC-010-3:** Given the SQLite `runs` table, when shared worktree mode is implemented, then a `story_workspace_id` column links runs sharing a worktree, enabling status queries across the story.

### REQ-011: Shared Worktree Mode -- Serial Finalize

**Priority:** P3 (low)
**MoSCoW:** Could (Won't in this release)
**Type:** Architecture

In shared worktree mode, finalize shall run once after the last task in the story completes, not after each individual task. The final finalize push covers all accumulated commits on the shared branch.

**Acceptance Criteria:**

- **AC-011-1:** Given a story with three tasks in shared worktree mode, when the third task completes QA and reviewer phases, then finalize runs exactly once and pushes all three tasks' commits in a single branch push.
- **AC-011-2:** Given a story where one task fails mid-pipeline, when the story is retried, then only the failed task's phases are re-run; previously completed tasks' commits on the shared branch are preserved.

---

## 10. Functional Requirements -- Part 4: Observability

### REQ-012: New Run Status Values

**Priority:** P1 (high)
**MoSCoW:** Must
**Type:** Observability

The SQLite `runs` table `status` field shall support two new values: `rebase_conflict` (mid-pipeline rebase hit unresolvable conflicts, troubleshooter invoked) and `rebase_resolving` (troubleshooter is actively working on the conflict).

**Acceptance Criteria:**

- **AC-012-1:** Given the `runs` table schema, when the migration adds `rebase_conflict` and `rebase_resolving` as valid status values, then all existing `status` constraints and indexes continue to function.
- **AC-012-2:** Given a run in `rebase_conflict` status, when `foreman status` displays it, then the status is shown with the label `REBASE CONFLICT` and the list of conflicting files from the last conflict detection.
- **AC-012-3:** Given a run transitions from `rebase_conflict` to `rebase_resolving` when the troubleshooter begins, and from `rebase_resolving` to `in_progress` when the pipeline resumes, then `foreman status` reflects each transition without manual refresh.

### REQ-013: Dashboard Visibility

**Priority:** P2 (medium)
**MoSCoW:** Should
**Type:** Observability

The `foreman dashboard` live UI shall display runs in `rebase_conflict` and `rebase_resolving` states with distinct visual indicators, distinguishing them from both normal `in_progress` runs and terminal `failed` runs.

**Acceptance Criteria:**

- **AC-013-1:** Given a run in `rebase_conflict` state, when the dashboard renders, then the run row displays a yellow/amber indicator and the text "REBASE CONFLICT" alongside the conflicting file count.
- **AC-013-2:** Given a run in `rebase_resolving` state, when the dashboard renders, then the run row displays a blue indicator and the text "RESOLVING" to distinguish active troubleshooter work from pipeline phases.

### REQ-014: Agent Mail Notifications

**Priority:** P1 (high)
**MoSCoW:** Must
**Type:** Observability

The pipeline executor shall send agent mail notifications at key mid-pipeline rebase events: rebase start, rebase success (with upstream change count), rebase conflict detected, and troubleshooter resolution outcome.

**Acceptance Criteria:**

- **AC-014-1:** Given `mail.onStart: true` is set for the developer phase and a mid-pipeline rebase is configured, when the rebase begins, then a mail is sent to the operator inbox with subject `[rebase] starting rebase onto <target>` and the run ID.
- **AC-014-2:** Given a mid-pipeline rebase that produces conflicts, when the pipeline transitions to `rebase_conflict`, then a mail is sent to the troubleshooter with subject `[rebase-conflict] <conflictCount> files conflicted in run <runId>` and the full list of conflicting file paths in the body.
- **AC-014-3:** Given the troubleshooter resolves the conflict and the pipeline resumes, when the developer phase restarts, then a mail is sent to the operator inbox indicating the conflict was resolved and the phase that is resuming.

### REQ-015: `foreman inbox` Rebase Mail Filtering

**Priority:** P2 (medium)
**MoSCoW:** Should
**Type:** Observability

`foreman inbox` shall support filtering by mail type `rebase-context` and `rebase-conflict` so operators can review the history of rebase events across all runs.

**Acceptance Criteria:**

- **AC-015-1:** Given multiple runs have completed with mid-pipeline rebases, when `foreman inbox --type rebase-context` is run, then only mails of type `rebase-context` are shown, with run ID and upstream change count visible.
- **AC-015-2:** Given a run that hit a `rebase_conflict`, when `foreman inbox --bead <id>` is run, then the rebase conflict mail, the troubleshooter mail, and the resume notification are all visible in chronological order.

---

## 11. Non-Functional Requirements

### REQ-016: Performance -- Rebase Step Latency

**Priority:** P1 (high)
**MoSCoW:** Must
**Type:** Non-Functional

The mid-pipeline rebase step shall add minimal wall-clock time to a pipeline run. The rebase itself is a VCS CLI operation; the only new latency budget is the VCS call plus the diff computation for the `rebase-context` mail.

**Acceptance Criteria:**

- **AC-016-1:** Given a clean rebase with no conflicts, when the mid-pipeline rebase step completes, then the elapsed time for the rebase step (from phase complete to next phase dispatch) is under 30 seconds for repositories up to 50,000 files.
- **AC-016-2:** Given a rebase that surfaces conflicts, when the troubleshooter is invoked, then the conflict detection and escalation path (status update + mail send + troubleshooter dispatch) completes within 10 seconds of `vcs.rebase()` returning.

### REQ-017: Reliability -- No Regression on Clean Pipelines

**Priority:** P0 (critical)
**MoSCoW:** Must
**Type:** Non-Functional

Pipelines that do not configure `rebaseAfterPhase` must be completely unaffected. No new failure modes are introduced to existing workflows.

**Acceptance Criteria:**

- **AC-017-1:** Given the entire existing test suite, when the mid-pipeline rebase feature is merged, then all existing Vitest tests pass without modification.
- **AC-017-2:** Given a workflow without `rebaseAfterPhase`, when any pipeline phase completes, then no rebase-related code path is entered (verified by absence of rebase log entries in the run log).
- **AC-017-3:** Given a workflow with `rebaseAfterPhase` enabled and an already-clean worktree (no upstream divergence), when the rebase step fires, then the pipeline continues immediately without any status transition or mail send (trivial rebase is a no-op from the operator's perspective).

### REQ-018: Test Coverage

**Priority:** P1 (high)
**MoSCoW:** Must
**Type:** Non-Functional

New code introduced by this feature shall meet Foreman's coverage standards: unit tests >= 80%, integration tests >= 70%.

**Acceptance Criteria:**

- **AC-018-1:** Given the pipeline executor rebase hook, when unit tests run, then the following branches are covered: clean rebase (continue), rebase with conflicts (escalate), `rebaseAfterPhase` absent (skip), troubleshooter success (resume from developer), troubleshooter failure (abort + fail).
- **AC-018-2:** Given the workflow YAML loader, when unit tests run, then `rebaseAfterPhase` present/absent, `rebaseTarget` present/absent, and unknown phase name validation error are all covered.
- **AC-018-3:** Given the integration test suite, when a full pipeline integration test runs with `rebaseAfterPhase: developer`, then the test covers both the clean-rebase path (QA receives rebase-context mail) and the conflict path (run transitions to `rebase_conflict`).

---

## 12. Implementation Strategy

### 12.1 Phased Delivery

| Phase | Scope | Duration | Dependencies |
|-------|-------|----------|-------------|
| Phase A | Workflow YAML schema update (`rebaseAfterPhase`, `rebaseTarget`). Validation in `workflow-loader.ts`. Unit tests for loader. | 1 day | None |
| Phase B | SQLite schema migration: add `rebase_conflict`, `rebase_resolving` to `status` enum. Update `store.ts` type definitions. | 0.5 days | None |
| Phase C | Pipeline executor rebase hook: post-phase rebase call, conflict detection, status transition, troubleshooter escalation, resume-from-developer logic. Unit tests with mocked VcsBackend. | 3 days | Phase A, Phase B |
| Phase D | QA rebase-context mail: diff computation after clean rebase, mail construction, delivery via `send_mail` tool. Unit tests. | 1 day | Phase C |
| Phase E | Observability: dashboard status indicators, `foreman inbox` type filter, operator mail notifications. | 1.5 days | Phase B, Phase C |
| Phase F | Integration tests: full pipeline with mid-pipeline rebase (clean + conflict paths). Performance validation. | 1.5 days | All above |

**Total estimated effort:** 8.5 days

### 12.2 Pipeline Executor Integration Points

The rebase hook shall be injected into `pipeline-executor.ts` as a post-phase callback. The executor's phase loop currently looks like:

```
for each phase:
  run phase
  if phase.verdict === FAIL: retryWith or fail
  else: dispatch next phase
```

The new hook inserts between "run phase" and "dispatch next phase":

```
for each phase:
  run phase
  if workflow.rebaseAfterPhase === phase.name:
    result = await vcs.rebase(rebaseTarget)
    if result.conflicts:
      await escalateToTroubleshooter(result)   // may resume from developer
      break
    else:
      await sendRebaseContextMail(result, nextPhase)
  if phase.verdict === FAIL: retryWith or fail
  else: dispatch next phase
```

No hardcoded phase names in the executor -- the hook fires whenever the phase name matches `rebaseAfterPhase`.

### 12.3 Troubleshooter Integration

The troubleshooter (`onFailure.troubleshooter`) already implements a `resolve-conflict` skill. The mid-pipeline escalation passes it the same inputs as the existing failure path:

- `worktreePath`: path to the conflicted worktree
- `conflictingFiles`: list from `vcs.getConflictingFiles()`
- `rebaseTarget`: the target ref that was being rebased onto
- `resumePhase: 'developer'`: instruction to resume from developer after resolution

The troubleshooter does not need modification for v1; it receives the conflict context through the existing mail channel.

### 12.4 Testing Strategy

- **Unit tests:** Pipeline executor rebase hook tested with mocked `VcsBackend` covering all branches (clean, conflicted, no-op). Workflow loader validation tests.
- **Integration tests:** Full in-process pipeline run with a real git repository. One test creates an upstream divergence that the rebase resolves cleanly. A second test creates a genuine conflict (same line modified upstream and in the worktree).
- **Regression tests:** All existing pipeline tests run with `rebaseAfterPhase` absent to verify no regression.
- **Diff computation tests:** `rebase-context` mail content verified against known git history.

---

## 13. Risks and Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Troubleshooter fails to resolve mid-pipeline conflicts consistently | No improvement over today's retry rate | Medium | Monitor troubleshooter resolution rate. If < 70%, add a "manual escalation" path that pauses the run and notifies the operator interactively. |
| Double-rebase (mid-pipeline + finalize) causes no-op overhead for already-clean repos | Slightly slower pipelines | Low | Detect "nothing to rebase" result and skip status transitions and mail for trivial rebases (AC-017-3). |
| `rebase_conflict` status interacts unexpectedly with existing `foreman reset` logic | Reset fails or corrupts run state | Low | Treat `rebase_conflict` identically to `failed` in the reset handler -- reset to `open`, prune worktree. Covered by AC-002-3. |
| Mid-pipeline resume from developer re-introduces the same conflict (loop) | Infinite conflict loop | Medium | Enforce single conflict resolution attempt per run (AC-004-3). Second conflict at the same rebase point marks the run `failed` permanently. |
| Upstream diff for `rebase-context` mail is too large for QA mail body | Mail delivery fails or QA agent overwhelmed | Low | Cap diff summary at 100 files; if exceeded, summarize as "N files changed, diff truncated -- see full diff at <worktree_path>". |
| `rebaseAfterPhase` naming a late phase (e.g., reviewer) creates unexpected semantics | Confusing operator behavior | Low | Document that `rebaseAfterPhase` is designed for post-developer use. Validation warning (not error) if `rebaseAfterPhase` names a phase after QA. |

---

## 14. Acceptance Criteria Summary

| REQ ID | Requirement | AC Count | Priority | MoSCoW |
|--------|-------------|----------|----------|--------|
| REQ-001 | Mid-Pipeline Rebase Execution | 4 | P0 | Must |
| REQ-002 | Conflict Detection and Run Status Transition | 3 | P0 | Must |
| REQ-003 | Troubleshooter Escalation | 3 | P0 | Must |
| REQ-004 | Pipeline Resume After Conflict Resolution | 3 | P0 | Must |
| REQ-005 | QA Rebase-Context Mail | 3 | P1 | Must |
| REQ-006 | VcsBackend Rebase Method Compatibility | 3 | P1 | Must |
| REQ-007 | `rebaseAfterPhase` Configuration Key | 3 | P0 | Must |
| REQ-008 | `rebaseTarget` Configuration Key | 3 | P1 | Should |
| REQ-009 | Default Workflow Update | 2 | P2 | Should |
| REQ-010 | Shared Worktree Mode -- Dispatcher Queuing Interface | 3 | P3 | Could (Won't) |
| REQ-011 | Shared Worktree Mode -- Serial Finalize | 2 | P3 | Could (Won't) |
| REQ-012 | New Run Status Values | 3 | P1 | Must |
| REQ-013 | Dashboard Visibility | 2 | P2 | Should |
| REQ-014 | Agent Mail Notifications | 3 | P1 | Must |
| REQ-015 | `foreman inbox` Rebase Mail Filtering | 2 | P2 | Should |
| REQ-016 | Performance -- Rebase Step Latency | 2 | P1 | Must |
| REQ-017 | Reliability -- No Regression on Clean Pipelines | 3 | P0 | Must |
| REQ-018 | Test Coverage | 3 | P1 | Must |
| REQ-019 | *(Reserved for future use)* | -- | -- | -- |
| **Total** | **18 active requirements** | **48 ACs** | | |

---

## 15. Success Metrics

| Metric | Baseline | Target | Measurement Method |
|--------|----------|--------|--------------------|
| Conflict-driven retry rate | ~50% of pipeline runs | < 10% of pipeline runs | Run status tracking in SQLite; ratio of `rebase_conflict` + `failed` (conflict cause) to total completed runs |
| Token cost per delivered task | 2x average (due to retries) | <= 1.15x average | Aggregate token usage per closed bead divided by count of closed beads, before vs. after |
| Troubleshooter conflict resolution rate | N/A (new) | >= 70% | Count of `rebase_conflict` → `in_progress` (resolved) vs. `rebase_conflict` → `failed` (unresolved) |
| Regression rate on non-rebase pipelines | 0% | 0% | Existing CI test suite pass rate |
| Rebase step latency (clean path) | N/A | < 30 seconds P95 | Pipeline executor timing logs |
| Operator manual interventions per day | ~5 (reset/retry) | <= 1 | Foreman CLI command frequency logging |

---

## 16. Release Plan

| Release | Contents | Gate Criteria |
|---------|----------|---------------|
| v0.1-alpha | Workflow YAML schema update (`rebaseAfterPhase`, `rebaseTarget`). SQLite migration for new status values. Loader validation. | Loader unit tests green. Schema migration applies cleanly on existing DB. |
| v0.2-alpha | Pipeline executor rebase hook (clean path only). No escalation yet -- clean rebase continues, conflict aborts run with `failed`. QA rebase-context mail. | Clean-path integration test passes. No regression on existing tests. Rebase-context mail delivered in test. |
| v0.3-alpha | Troubleshooter escalation path. Resume-from-developer logic. `rebase_conflict` and `rebase_resolving` status transitions. | Conflict-path integration test passes. Run resumes from developer after mock troubleshooter resolution. AC-004-3 (max retry after resume) verified. |
| v0.4-beta | Full observability: dashboard indicators, inbox filtering, operator mail notifications. Default workflow comment block. | Dashboard shows `REBASE CONFLICT` label. Inbox filtering works. All 48 ACs verified. |
| v1.0 | Production release. Conflict-driven retry rate measured over 48-hour production window. | Retry rate < 10%. All success metrics met. No regressions on 20+ production pipeline runs. |

---

## 17. Open Questions

| ID | Question | Status | Resolution |
|----|----------|--------|------------|
| OQ-1 | What triggers the mid-pipeline rebase? | Resolved | `rebaseAfterPhase` key in workflow YAML; pipeline-executor calls `vcs.rebase()` after the named phase. |
| OQ-2 | What does "escalate to troubleshooter" mean for a mid-pipeline conflict? | Resolved | Pipeline marks run `rebase_conflict`; troubleshooter's `resolve-conflict` skill handles it via agent mail; if resolved, pipeline resumes from developer phase (not from scratch). |
| OQ-3 | What is the rebase target? | Resolved | `origin/<defaultBranch>` (same as finalize rebase today); configurable per workflow via `rebaseTarget`; defaults to `origin/dev` for the default workflow. |
| OQ-4 | Does shared worktree mode need a locking mechanism? | Resolved | Dispatcher checks for active runs on the shared branch before dispatching; queues subsequent tasks if worktree is in use (deferred to v2). |
| OQ-5 | What if the rebase produces no conflicts but changes the test surface significantly? | Resolved | After rebase, pipeline-executor sends `rebase-context` mail to QA with a diff summary of upstream changes; QA uses this to adapt its test plan. Trivial rebases (zero upstream commits) send no mail. |
| OQ-6 | Should the troubleshooter's resolve-conflict skill require changes for mid-pipeline use? | Open | Current troubleshooter skill was designed for finalize-time conflicts. Needs investigation: does it require the rebase to be in-progress (mid-rebase state) or does it work on the already-aborted worktree? Escalation protocol in REQ-003 assumes in-progress rebase state. |
| OQ-7 | Should `rebaseAfterPhase` support multiple phases (e.g., after explorer AND after developer)? | Open | v1 supports a single phase name. Multiple rebases per pipeline may be valuable for long-running tasks. Deferred; can be addressed as a minor extension post-v1. |
