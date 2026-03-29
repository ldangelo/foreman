# PRD-2026-006: Multi-Project Native Task Management

**Document ID:** PRD-2026-006
**Version:** 1.0
**Status:** Draft
**Date:** 2026-03-29
**Author:** Product Management
**Stakeholders:** Engineering (Foreman maintainers), Foreman operators managing multiple concurrent projects
**Requirements:** 22 (REQ-001 through REQ-022)

---

## Readiness Scorecard

| Dimension | Score (1-5) | Notes |
|-----------|-------------|-------|
| Completeness | 4 | All feature areas covered; sling integration and coexistence period well-defined |
| Testability | 4 | Acceptance criteria are measurable and specific |
| Clarity | 4 | Workflow-aware statuses and approval gate are precisely defined |
| Feasibility | 3 | **Concern: large scope.** Beads replacement is a multi-sprint effort; dispatcher refactor, native task store, dashboard aggregation, and migration tooling all require coordination. Recommend phased delivery (see Section 13). |
| **Overall** | **3.75** | Proceed — operator is aware this is a strategic initiative |

> **Feasibility note:** This PRD describes a significant architectural shift. The beads/bv replacement is intentional and strategic, but teams should plan 3-4 sprints for full delivery. The coexistence mechanism (REQ-017) de-risks the transition by allowing incremental adoption.

---

## Version History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-03-29 | Product Management | Initial draft. 22 requirements across 7 feature areas: project registry, native task store, task management CLI, unified dashboard, beads migration, cross-project dispatch, and non-functional requirements. Pre-resolved 6 adversarial gaps prior to publication. |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Statement](#2-problem-statement)
3. [Goals and Non-Goals](#3-goals-and-non-goals)
4. [User Personas](#4-user-personas)
5. [Current State Analysis](#5-current-state-analysis)
6. [Solution Overview](#6-solution-overview)
7. [Functional Requirements -- Part 1: Project Registry](#7-functional-requirements----part-1-project-registry)
8. [Functional Requirements -- Part 2: Native Task Store](#8-functional-requirements----part-2-native-task-store)
9. [Functional Requirements -- Part 3: Task Management CLI](#9-functional-requirements----part-3-task-management-cli)
10. [Functional Requirements -- Part 4: Unified Dashboard](#10-functional-requirements----part-4-unified-dashboard)
11. [Functional Requirements -- Part 5: Beads Migration](#11-functional-requirements----part-5-beads-migration)
12. [Functional Requirements -- Part 6: Cross-Project Dispatch](#12-functional-requirements----part-6-cross-project-dispatch)
13. [Non-Functional Requirements](#13-non-functional-requirements)
14. [Implementation Strategy](#14-implementation-strategy)
15. [Risks and Mitigations](#15-risks-and-mitigations)
16. [Acceptance Criteria Summary](#16-acceptance-criteria-summary)
17. [Success Metrics](#17-success-metrics)
18. [Release Plan](#18-release-plan)
19. [Open Questions](#19-open-questions)

---

## 1. Executive Summary

Foreman today is a per-project tool: each invocation operates on the project in the current working directory, with no awareness of other projects or their agent states. An operator managing 5-7 active projects must context-switch between terminal windows to check on running agents, triage failures, and approve new work -- with no aggregated signal across projects.

This PRD transforms Foreman into a **self-contained, multi-project orchestration platform** by introducing three interlocking capabilities:

1. **A global project registry** (`~/.foreman/projects.json`) that lets the operator register named project paths once and reference them from any directory.
2. **A native task store** embedded in each project's existing SQLite database, replacing beads (`br`) and beads-viewer (`bv`) with workflow-aware task tracking that models the full pipeline lifecycle.
3. **A unified cross-project dashboard** that aggregates state across all registered projects, surfaces a "needs human" priority column, and allows dispatch operations without requiring `cd`.

The result is a single interface -- `foreman dashboard` -- where the operator sees everything, approves work, and intervenes on failures across all projects simultaneously.

---

## 2. Problem Statement

### 2.1 No Cross-Project Visibility

Foreman operates exclusively within the current working directory. There is no mechanism to observe the state of multiple projects simultaneously. An operator managing 5-7 projects must:

- Maintain separate tmux windows or terminal sessions per project
- Manually run `foreman status` in each project directory to check for failures
- Remember which projects have agents running, which have stuck tasks, and which need human approval

This context-switching overhead grows linearly with the number of active projects and introduces a class of operational failures where a stuck agent or failed merge goes unnoticed for hours because the operator is focused elsewhere.

### 2.2 No "Needs Human" Aggregation

There is no concept in the current system of "this task requires operator attention." Tasks either have running agents or they don't. A task in `conflict`, `failed`, or `stuck` state looks identical to a task in `backlog` from the operator's perspective -- both simply have no active agent. There is no triage surface.

### 2.3 External Task Tracking Dependency

Foreman currently delegates all task management to beads (`br`), an external CLI tool with its own database, status model, and conventions. This creates friction:

- Foreman operators must learn two CLIs (`foreman` and `br`) with different conventions
- The beads status model (`open`, `in_progress`, `closed`) does not map to pipeline phases (`explorer`, `developer`, `qa`, `reviewer`, `finalize`), causing semantic mismatch when monitoring pipeline progress
- `foreman sling trd X` creates beads tasks via the external `br` binary -- if `br` is unavailable or misconfigured, sling fails
- The dashboard (`foreman dashboard`) cannot display pipeline phase granularity because beads has no pipeline-aware status

### 2.4 Cross-Directory Operations Require `cd`

Every `foreman run`, `foreman reset`, and `foreman retry` command requires the operator to be in the target project's directory. There is no `--project` flag or registry-name targeting. For an operator managing 7 projects, retrying a failed pipeline in project B while reviewing project A requires a directory switch.

---

## 3. Goals and Non-Goals

### 3.1 Goals

1. **Introduce a global project registry** at `~/.foreman/projects.json` with `foreman project add/list/remove` commands.
2. **Build a native task store** into each project's existing `.foreman/foreman.db` SQLite database with workflow-aware statuses and a dependency graph.
3. **Replace `br` and `bv`** as the task management interface with `foreman task` subcommands and the enhanced `foreman dashboard`.
4. **Add a "needs human" view** to the dashboard that surfaces `conflict`, `failed`, `stuck`, and awaiting-approval (`backlog`) tasks across all projects.
5. **Enable cross-project dispatch** via `--project <name>` flags on `foreman run`, `foreman reset`, and `foreman retry`.
6. **Provide a migration path** from `.beads/` data via `foreman task import --from-beads`.
7. **Integrate native task creation into `foreman sling trd`** so the sling pipeline creates native tasks instead of calling `br`.
8. **Support coexistence** -- foreman reads from the native task store if present, falls back to beads if not, so migration can be incremental.

### 3.2 Non-Goals

1. **Centralized task storage** -- task state remains per-project in each project's `.foreman/foreman.db`. The global registry only stores project paths and metadata.
2. **Replacing git or VCS operations** -- this PRD does not change VCS handling (see PRD-2026-004).
3. **Multi-user / team collaboration** -- the task store is single-operator; no concurrency or access control features.
4. **Real-time task sync across machines** -- task state is local to each machine.
5. **Custom workflow YAML changes** -- the pipeline phase sequence is unchanged; only status tracking is enhanced.
6. **External integrations** (Jira, Linear, GitHub Issues) -- out of scope.
7. **Immediate removal of `br` binary** -- beads remains available during the coexistence period.

---

## 4. User Personas

### 4.1 Multi-Project Operator

**Name:** Alex, Senior Engineer / Tech Lead
**Context:** Manages 6 active Foreman projects. Has Foreman running in parallel across multiple git repositories. Currently uses 6 tmux windows and must manually check each for failures. Uses `br` for task tracking but finds the status model too coarse to understand pipeline progress.
**Needs:** A single terminal view showing all projects, which agents are active, and which tasks need intervention. Wants to approve or dispatch work without `cd`.

### 4.2 Single-Project Power User (Existing)

**Name:** Dana, Senior Engineer
**Context:** Uses Foreman on one large repository today. Happy with the existing workflow but finds `br` ergonomically inconsistent with `foreman` conventions. Wants pipeline-phase-level status visibility.
**Needs:** Zero regression on existing functionality. Richer task statuses. `foreman task` commands as a drop-in replacement for common `br` commands.

### 4.3 Operator Onboarding a New Project

**Name:** Jordan, Platform Engineer
**Context:** Setting up a new project to use Foreman. Currently must install `br` separately, initialize `.beads/`, and learn beads conventions before Foreman can dispatch any work.
**Needs:** `foreman project add` and `foreman task create` as the only onboarding steps -- no external tool installation.

---

## 5. Current State Analysis

### 5.1 Current Task Flow

```
Operator                  beads (br)               Foreman
   |                         |                         |
   |-- br create ---------> beads DB                  |
   |-- br ready ----------> [ready tasks] ----------> dispatcher
   |                                                    |
   |                                                    |-- agent runs
   |                                                    |
   |                         syncBeadStatusAfterMerge()<-- refinery
   |-- br show -----------> [status]                   |
```

### 5.2 Coupling Points to Replace

| Current Component | Location | Replacement |
|------------------|----------|-------------|
| `BeadsRustClient` | `src/lib/beads-rust.ts` | `NativeTaskStore` in `src/lib/task-store.ts` |
| `br ready` query in dispatcher | `src/orchestrator/dispatcher.ts` | Query `tasks` table WHERE `status = 'ready'` |
| `syncBeadStatusAfterMerge()` in refinery | `src/orchestrator/refinery.ts` | `taskStore.updateStatus(id, 'merged')` |
| `br create` in sling | `src/cli/commands/sling.ts` | `taskStore.create(...)` |
| `bv` dashboard view | external binary | `foreman dashboard` cross-project view |
| Per-project `foreman status` | `src/cli/commands/status.ts` | `foreman status --all` aggregation |

### 5.3 Existing SQLite Schema

The current `.foreman/foreman.db` has four tables: `runs`, `projects`, `merge_queue`, `messages`. The native task store adds two new tables (`tasks`, `task_dependencies`) to this existing database without modifying existing tables.

---

## 6. Solution Overview

### 6.1 Architecture

```
Global (~/.foreman/)
  projects.json          <-- project registry (name -> path mapping)
  config.yaml            <-- global defaults (optional)

Per-Project (.foreman/foreman.db)
  tasks                  <-- native task store (NEW)
  task_dependencies      <-- dependency graph (NEW)
  runs                   <-- existing
  merge_queue            <-- existing
  messages               <-- existing
```

```
foreman dashboard
  |
  +-- reads ~/.foreman/projects.json
  |
  +-- for each registered project:
  |     opens <project>/.foreman/foreman.db (read-only)
  |     queries tasks, runs, merge_queue
  |
  +-- renders cross-project TUI with "needs human" column
```

```
foreman run --project <name>
  |
  +-- resolves project path from registry
  |
  +-- dispatcher queries tasks WHERE status='ready' AND project=<path>
  |
  +-- creates worktree, spawns agent (existing flow)
```

### 6.2 Workflow-Aware Task Statuses

```
backlog ──(approve)──> ready ──(dispatch)──> in-progress
                                                  |
                           explorer ──> developer ──> qa ──> reviewer ──> finalize
                                                                              |
                                                                           merged
backlog / ready / in-progress / any-phase ──> conflict | failed | stuck
any-phase ──> blocked  (unresolved dependency)
```

### 6.3 Approval Gate

Tasks created via `foreman task create` or `foreman sling trd` enter `backlog` status. They do not become visible to the dispatcher until an operator runs `foreman task approve <id>`, which transitions them to `ready`. This prevents accidental dispatch of incomplete or unapproved task definitions.

---

## 7. Functional Requirements -- Part 1: Project Registry

### REQ-001: Global Project Registry

**Priority:** P0 (critical)
**MoSCoW:** Must

Foreman shall maintain a global project registry at `~/.foreman/projects.json` that maps project names to filesystem paths. The registry shall be the authoritative source for all cross-project operations.

**Registry schema:**

```json
{
  "version": 1,
  "projects": [
    {
      "name": "foreman",
      "path": "/Users/ldangelo/Development/Fortium/foreman",
      "addedAt": "2026-03-29T00:00:00Z"
    }
  ]
}
```

**Acceptance Criteria:**

- AC-001.1: Running `foreman project add <path>` with a valid directory path adds the project to `~/.foreman/projects.json` with an auto-derived name (directory basename) and the absolute resolved path. If `--name <alias>` is provided, that alias is used instead.
- AC-001.2: Running `foreman project add <path>` with a path that does not contain a `.foreman/` directory emits a warning `"No .foreman/ directory found at <path>. Run 'foreman init' in that directory first."` but proceeds with registration.
- AC-001.3: Attempting to add a path that is already registered exits with a non-zero status and message `"Project '<name>' is already registered at <path>."` without duplicating the entry.
- AC-001.4: `~/.foreman/` is created automatically if it does not exist when any registry-writing command is first run.

---

### REQ-002: Project Listing and Health Status

**Priority:** P0 (critical)
**MoSCoW:** Must

`foreman project list` shall display all registered projects with their health status. A project is **healthy** if its `path` resolves to an accessible directory. A project is **stale** if the directory no longer exists or is inaccessible.

**Acceptance Criteria:**

- AC-002.1: `foreman project list` outputs a table with columns: `NAME`, `PATH`, `STATUS`, `ACTIVE AGENTS`, `NEEDS HUMAN`. Each row shows a registered project. Healthy projects show `STATUS=ok`; stale projects show `STATUS=stale` with a warning indicator.
- AC-002.2: `foreman project remove <name>` removes the named project from the registry. If the project has active agents (runs with status `running` in its database), the command exits with an error: `"Project '<name>' has active agents. Stop them first or use --force."`.
- AC-002.3: `foreman project remove --stale` removes all registry entries whose paths are no longer accessible. It prints the list of removed entries before removing them.

---

## 8. Functional Requirements -- Part 2: Native Task Store

### REQ-003: Task Schema with Workflow-Aware Statuses

**Priority:** P0 (critical)
**MoSCoW:** Must

The system shall add a `tasks` table to each project's `.foreman/foreman.db` SQLite database. The schema shall support workflow-aware statuses aligned with the Foreman pipeline.

**Schema:**

```sql
CREATE TABLE IF NOT EXISTS tasks (
  id          TEXT PRIMARY KEY,           -- UUID v4
  title       TEXT NOT NULL,
  description TEXT,
  type        TEXT NOT NULL DEFAULT 'task',  -- task | bug | feature | epic | chore | docs | question
  priority    INTEGER NOT NULL DEFAULT 2,    -- 0 (critical) - 4 (backlog)
  status      TEXT NOT NULL DEFAULT 'backlog',
  run_id      TEXT REFERENCES runs(id),      -- active run if in-progress or in a phase
  branch      TEXT,                          -- git branch if dispatched
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  approved_at TEXT,                          -- set when transitioned to 'ready'
  closed_at   TEXT
);

-- Valid status values:
-- backlog | ready | in-progress | explorer | developer | qa | reviewer | finalize
-- | merged | conflict | failed | stuck | blocked
```

**Acceptance Criteria:**

- AC-003.1: `foreman init` (and any path that creates `.foreman/foreman.db`) runs the `tasks` and `task_dependencies` DDL migrations idempotently. Running `foreman init` on an existing project with an existing database adds the new tables without modifying existing data.
- AC-003.2: The `status` column is constrained to the enumerated values listed above. Attempting to insert or update with an unknown status value raises a SQLite constraint error that propagates as a typed `InvalidTaskStatusError` in TypeScript.
- AC-003.3: Task IDs are UUID v4 strings generated at creation time. The `id` field is immutable after creation.

---

### REQ-004: Task Dependency Graph

**Priority:** P1 (high)
**MoSCoW:** Must

The system shall support task dependencies via a `task_dependencies` table. Dependencies shall support two relationship types: `blocks` (task B cannot start until task A is complete) and `parent-child` (organizational grouping only, does not affect `ready` status).

**Schema:**

```sql
CREATE TABLE IF NOT EXISTS task_dependencies (
  from_task_id  TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  to_task_id    TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  type          TEXT NOT NULL DEFAULT 'blocks',  -- 'blocks' | 'parent-child'
  PRIMARY KEY (from_task_id, to_task_id, type)
);
```

**Acceptance Criteria:**

- AC-004.1: A task with `status = 'ready'` that has one or more `blocks`-type dependencies where the blocking task has a status other than `merged` or `closed` shall be automatically transitioned to `status = 'blocked'` when the dependency is added. The `ready` query used by the dispatcher excludes `blocked` tasks.
- AC-004.2: When a task transitions to `merged` or `closed`, the system automatically re-evaluates all tasks that were blocked by it. Any task that now has no remaining open `blocks` dependencies is transitioned from `blocked` to `ready` (if it was previously approved).
- AC-004.3: `parent-child` relationships are stored and retrievable but do not influence the dispatcher's `ready` query or the `blocked` status transition logic.

---

### REQ-005: Approval Gate

**Priority:** P0 (critical)
**MoSCoW:** Must

Tasks created in the native task store shall enter `backlog` status and shall not be dispatched by the dispatcher until explicitly approved by the operator. Approval transitions a task from `backlog` to `ready`.

**Acceptance Criteria:**

- AC-005.1: The dispatcher's ready-task query is `SELECT * FROM tasks WHERE status = 'ready' AND (run_id IS NULL)`. Tasks with `status = 'backlog'` are never returned by this query regardless of their dependency state.
- AC-005.2: `foreman task approve <id>` transitions a task from `backlog` to `ready`, sets `approved_at` to the current timestamp, and prints `"Task <id> approved and ready for dispatch."`. If the task has unresolved `blocks` dependencies, it transitions to `blocked` instead of `ready`, and prints `"Task <id> approved but blocked on: <blocking-task-ids>."`.
- AC-005.3: Attempting to approve a task that is not in `backlog` status prints `"Task <id> is already in status '<current-status>' -- no change."` and exits with status 0.

---

## 9. Functional Requirements -- Part 3: Task Management CLI

### REQ-006: `foreman task create`

**Priority:** P0 (critical)
**MoSCoW:** Must

The system shall provide a `foreman task create` command that creates a native task in the current project's task store (or the project specified by `--project`).

**Usage:**
```
foreman task create --title "Implement OAuth login" \
  --description "Add Google and GitHub OAuth2 flows" \
  --type feature --priority 1
```

**Acceptance Criteria:**

- AC-006.1: `foreman task create` requires `--title`. All other flags are optional with defaults: `--type task`, `--priority 2`, `--description ""`. The created task enters `backlog` status. The command prints `"Created task <id>: <title> [backlog]"`.
- AC-006.2: `--priority` accepts integers 0-4 only. Values outside this range exit with error `"Priority must be 0 (critical) through 4 (backlog)."`. The aliases `critical`, `high`, `medium`, `low`, `backlog` are also accepted as input (mapped to 0-4 respectively) for ergonomic compatibility with beads conventions.
- AC-006.3: `--type` accepts the enumerated task types. An unrecognized type exits with an error listing valid types.

---

### REQ-007: `foreman task list`, `show`, and `update`

**Priority:** P0 (critical)
**MoSCoW:** Must

The system shall provide `foreman task list`, `foreman task show <id>`, and `foreman task update <id>` commands that replace the equivalent `br list`, `br show`, and `br update` commands for day-to-day task management.

**Acceptance Criteria:**

- AC-007.1: `foreman task list` outputs a table of tasks for the current project (or `--project` target) with columns: `ID`, `TITLE`, `TYPE`, `PRI`, `STATUS`. By default, tasks with `status = 'merged'` or `status = 'closed'` are excluded. `--all` includes all statuses. `--status <value>` filters by a single status.
- AC-007.2: `foreman task show <id>` displays full task detail including: id, title, description, type, priority, status, run_id, branch, created_at, updated_at, approved_at, and all dependencies (both directions, with type label).
- AC-007.3: `foreman task update <id>` accepts `--title`, `--description`, `--priority`, `--status` flags. Status transitions not valid in the workflow state machine (e.g., `merged` -> `backlog`) print a warning but proceed when `--force` is provided. Without `--force`, invalid transitions exit with a non-zero status.

---

### REQ-008: `foreman task close` and Manual Status Control

**Priority:** P1 (high)
**MoSCoW:** Must

The system shall provide `foreman task close <id>` and unrestricted manual status override to give operators full control over task lifecycle, including recovery from edge cases.

**Acceptance Criteria:**

- AC-008.1: `foreman task close <id>` sets `status = 'closed'` and `closed_at` to the current timestamp. It accepts an optional `--reason` string stored in the task description suffix. If the task has tasks that depend on it via `blocks` relationships, those dependent tasks' blocked state is re-evaluated (see AC-004.2).
- AC-008.2: `foreman task update <id> --status <any-valid-status>` works without `--force` for any status that is a valid forward or lateral transition. The `--force` flag is required only for backward transitions (e.g., `merged` -> `ready`).

---

### REQ-009: Sling Integration -- Native Task Creation

**Priority:** P1 (high)
**MoSCoW:** Must

`foreman sling trd <trd-file>` shall create tasks in the native task store instead of calling the `br` binary. The sling pipeline's task creation output shall be identical in content but stored natively.

**Acceptance Criteria:**

- AC-009.1: After this change, `foreman sling trd <file>` does not invoke `br create` or any `BeadsRustClient` method. All task creation goes through `NativeTaskStore.create()`. Existing sling output format (task titles, descriptions, dependencies, priorities) is preserved.
- AC-009.2: Tasks created by sling enter `backlog` status. The operator must run `foreman task approve <id>` (or `foreman task approve --all --from-sling <seed>`) before the dispatcher will pick them up.
- AC-009.3: If the current project has not yet been initialized with the native task store (no `tasks` table in `foreman.db`), `foreman sling trd` automatically runs the schema migration before creating tasks, with a one-time message: `"Migrating task store to native format..."`.

---

## 10. Functional Requirements -- Part 4: Unified Dashboard

### REQ-010: Cross-Project Dashboard Aggregation

**Priority:** P0 (critical)
**MoSCoW:** Must

`foreman dashboard` shall aggregate and display task and agent state across all registered projects simultaneously. It shall open each registered project's `.foreman/foreman.db` in read-only mode and render a unified view without requiring `cd` into any project directory.

**Acceptance Criteria:**

- AC-010.1: `foreman dashboard` reads `~/.foreman/projects.json` and opens each registered project's database read-only. Projects whose databases are inaccessible show a `[offline]` indicator rather than crashing the dashboard.
- AC-010.2: The dashboard refreshes its view at a configurable interval (default: 5 seconds). The refresh rate is configurable via `~/.foreman/config.yaml` (`dashboard.refreshInterval`) and via `--refresh <seconds>` CLI flag.
- AC-010.3: The dashboard layout includes at minimum: a project-selector header, a "Needs Human" panel (top priority), a per-project agent status panel, and a task list panel filterable by project.

---

### REQ-011: "Needs Human" Panel

**Priority:** P0 (critical)
**MoSCoW:** Must

The dashboard shall display a dedicated "Needs Human" panel that surfaces all tasks across all registered projects that require operator attention, defined as tasks with status `conflict`, `failed`, `stuck`, or `backlog` (awaiting approval).

**Acceptance Criteria:**

- AC-011.1: The "Needs Human" panel lists all tasks where `status IN ('conflict', 'failed', 'stuck', 'backlog')` across all registered, accessible projects. Each row shows: `PROJECT`, `TASK ID`, `TITLE`, `STATUS`, `AGE` (time since `updated_at`). Rows are sorted by priority (P0 first) then age (oldest first).
- AC-011.2: The panel is always visible and is the topmost section of the dashboard layout. When the panel is empty (no tasks needing attention), it displays `"No tasks need attention."` in a visually distinct style.
- AC-011.3: The operator can navigate to any item in the "Needs Human" panel and press `a` to approve a `backlog` task, `r` to retry a `failed` or `stuck` task (equivalent to `foreman reset --bead <id> --project <name>`), or `Enter` to show full task detail. These actions are dispatched to the appropriate project without requiring a directory change.

---

### REQ-012: Pipeline Phase Visibility

**Priority:** P1 (high)
**MoSCoW:** Must

The dashboard shall display the current pipeline phase for in-progress tasks, not just a generic "in-progress" status. This replaces the coarse beads `in_progress` status with phase-level granularity.

**Acceptance Criteria:**

- AC-012.1: Tasks with `status IN ('explorer', 'developer', 'qa', 'reviewer', 'finalize')` are displayed with the phase name as their status in all dashboard views and `foreman task list` output. The phase name is styled distinctly from terminal statuses (`conflict`, `failed`, `stuck`).
- AC-012.2: The dispatcher updates the task's `status` to the current pipeline phase name at the start of each phase. The pipeline executor calls `taskStore.updatePhase(taskId, phaseName)` at phase transitions, sourcing the phase name from the workflow YAML.

---

## 11. Functional Requirements -- Part 5: Beads Migration

### REQ-013: Beads Import Command

**Priority:** P0 (critical)
**MoSCoW:** Must

The system shall provide `foreman task import --from-beads` to migrate existing beads data from `.beads/beads.jsonl` into the native task store, enabling operators to transition without losing task history.

**Acceptance Criteria:**

- AC-013.1: `foreman task import --from-beads` reads `.beads/beads.jsonl` from the current project directory, maps each bead to a native task using the field mapping in Section 5.2, and inserts all tasks into the `tasks` table. It prints a summary: `"Imported N tasks (M skipped: already exist by title match)."`.
- AC-013.2: The beads `status` field is mapped to native task statuses as follows: `open` -> `backlog`, `in_progress` -> `ready` (not auto-approved; operator must approve), `closed` -> `merged`. Beads with `type=epic` are imported as `type=epic`. Dependencies in beads (`blocks` type) are imported into `task_dependencies` with type `blocks`; `parent-child` type is preserved.
- AC-013.3: `foreman task import --from-beads --dry-run` performs the import logic and prints what would be created without writing to the database. The dry-run output includes field-level mapping for the first 5 tasks to aid verification.
- AC-013.4: If a task with the same `id` already exists in the native store (by bead ID stored in a `external_id` column), it is skipped rather than duplicated. The `external_id TEXT` column shall be added to the `tasks` schema to store the original bead ID.

---

### REQ-014: Coexistence -- Fallback to Beads

**Priority:** P1 (high)
**MoSCoW:** Must

During the transition period, Foreman shall support coexistence: if a project has native tasks in its `tasks` table, Foreman uses the native store; if the `tasks` table is empty or absent, Foreman falls back to querying `br` for ready tasks. This allows incremental per-project migration.

**Acceptance Criteria:**

- AC-014.1: The dispatcher's `getReadyTasks()` method first checks whether the current project's database has a `tasks` table with one or more rows. If yes, it queries the native store. If the `tasks` table is absent or empty, it falls back to `BeadsRustClient.getReadyTasks()`. A debug-level log message records which path was taken.
- AC-014.2: The fallback behavior is overridable: `FOREMAN_TASK_STORE=native` environment variable forces native store usage even if the table is empty. `FOREMAN_TASK_STORE=beads` forces beads fallback regardless of table contents.
- AC-014.3: `foreman doctor` reports the task store mode for the current project: `"Task store: native (N tasks)"` or `"Task store: beads (fallback)"`. If both a non-empty native store and a non-empty `.beads/beads.jsonl` exist, `foreman doctor` emits a warning: `"Both native task store and beads data exist. Run 'foreman task import --from-beads' and then remove .beads/ to complete migration."`.

---

### REQ-015: Beads Deprecation Path

**Priority:** P2 (medium)
**MoSCoW:** Should

The `BeadsRustClient` interface and `src/lib/beads-rust.ts` shall be marked deprecated and isolated to a compatibility shim. No new code shall depend on `BeadsRustClient` after this PRD is implemented.

**Acceptance Criteria:**

- AC-015.1: `src/lib/beads-rust.ts` is annotated with `@deprecated` JSDoc tags on all exported symbols. The TypeScript strict-mode build emits no deprecation errors from within Foreman's own modules (internal usages are replaced with `NativeTaskStore` calls).
- AC-015.2: `foreman doctor` emits an informational notice (not an error) when `br` binary is absent: `"beads (br) not found -- native task store active."` This replaces the current behavior of failing the doctor check when `br` is absent.

---

## 12. Functional Requirements -- Part 6: Cross-Project Dispatch

### REQ-016: `--project` Flag on Dispatch Commands

**Priority:** P0 (critical)
**MoSCoW:** Must

`foreman run`, `foreman reset`, `foreman retry`, and `foreman status` shall accept a `--project <name-or-path>` flag that resolves the target project from the registry and operates against it without requiring `cd`.

**Acceptance Criteria:**

- AC-016.1: `foreman run --project <name>` resolves `<name>` from `~/.foreman/projects.json` to its registered path, then executes the equivalent of running `foreman run` from that directory. If `<name>` is not found in the registry, it exits with error: `"Project '<name>' not found. Run 'foreman project list' to see registered projects."`.
- AC-016.2: `--project` also accepts an absolute filesystem path directly. If the path is not in the registry, a warning is printed (`"Path not in registry -- operating directly."`) but execution proceeds.
- AC-016.3: `foreman status --all` outputs a condensed status table for all registered projects: `PROJECT`, `RUNNING AGENTS`, `READY TASKS`, `NEEDS HUMAN`, `LAST ACTIVITY`. This is the cross-project equivalent of the current per-project `foreman status`.

---

### REQ-017: Dispatcher Reads Native Task Store Per-Project

**Priority:** P0 (critical)
**MoSCoW:** Must

The dispatcher shall query the local project's SQLite `tasks` table for ready tasks when the native task store is active, replacing the current `br ready` shell invocation. The dispatcher operates cwd-relative (same as today); the `--project` flag handles the cwd resolution before the dispatcher is invoked.

**Acceptance Criteria:**

- AC-017.1: When the native task store is active, `dispatcher.getReadyTasks()` executes `SELECT * FROM tasks WHERE status = 'ready' ORDER BY priority ASC, created_at ASC` against the project's `foreman.db`. It does not invoke `execFileAsync` or any shell command to query beads.
- AC-017.2: When the dispatcher claims a task for execution, it updates `status = 'in-progress'` and sets `run_id` to the newly created run ID atomically in the same SQLite transaction as run creation. This prevents double-dispatch if two foreman processes race.
- AC-017.3: When the pipeline executor transitions between phases, it calls `taskStore.updatePhase(taskId, phaseName)` to update the task status to the current phase name. If `taskId` is null (beads fallback mode), this call is a no-op.

---

### REQ-018: Refinery Closes Native Tasks Post-Merge

**Priority:** P1 (high)
**MoSCoW:** Must

The refinery shall close native tasks by updating their status to `merged` after a successful merge, replacing the current `syncBeadStatusAfterMerge()` call.

**Acceptance Criteria:**

- AC-018.1: After a successful merge in `refinery.ts`, the refinery calls `taskStore.updateStatus(taskId, 'merged', { closedAt: new Date() })` for the task associated with the completed run. The `syncBeadStatusAfterMerge()` function is called only in beads fallback mode.
- AC-018.2: If the task ID cannot be resolved from the run (e.g., the run was created before native task tracking was active), the refinery logs a debug warning and proceeds without error. Eventual consistency is acceptable -- a manual `foreman task update <id> --status merged` is the operator recovery path.

---

## 13. Non-Functional Requirements

### REQ-019: Dashboard Refresh Performance

**Priority:** P1 (high)
**MoSCoW:** Must

The unified dashboard shall refresh its aggregated view across all registered projects within 2 seconds, even when 7 projects are registered.

**Acceptance Criteria:**

- AC-019.1: Dashboard refresh time (measured from refresh trigger to completed render) is less than 2000ms with 7 registered projects, each with up to 200 tasks and 10 active runs, on a machine with a standard SSD. This is validated by a benchmark test in `src/cli/__tests__/dashboard-performance.test.ts`.
- AC-019.2: Each project's database is opened in read-only mode (`SQLITE_OPEN_READONLY`) during dashboard aggregation. Write contention from active agent processes does not block dashboard reads.

---

### REQ-020: Backward Compatibility During Transition

**Priority:** P0 (critical)
**MoSCoW:** Must

All existing `foreman` commands shall continue to work without modification during the coexistence period. Projects that have not run `foreman task import --from-beads` shall behave identically to today.

**Acceptance Criteria:**

- AC-020.1: A project with no `tasks` table (fresh install, or project that has not migrated) passes all existing integration tests without modification. The `foreman run`, `foreman status`, `foreman merge`, `foreman dashboard` (single-project mode), and `foreman doctor` commands all function as before.
- AC-020.2: The `foreman task` command group is additive -- no existing command is renamed or removed. `foreman status` retains its current behavior; `foreman status --all` is the new cross-project addition.

---

### REQ-021: TypeScript Strict Mode and Test Coverage

**Priority:** P1 (high)
**MoSCoW:** Must

All new modules introduced by this PRD shall comply with the project's TypeScript strict mode and test coverage requirements.

**Acceptance Criteria:**

- AC-021.1: `npx tsc --noEmit` passes with zero errors after all new modules are added. No `any` type escape hatches are used in `src/lib/task-store.ts`, `src/lib/project-registry.ts`, or any new CLI command modules.
- AC-021.2: Unit test coverage for `src/lib/task-store.ts` and `src/lib/project-registry.ts` is >= 80% as measured by Vitest coverage. Integration test coverage for the cross-project dashboard aggregation path is >= 70%.
- AC-021.3: The `task_dependencies` circular dependency check (a task cannot block itself, directly or transitively) is enforced at the `NativeTaskStore` layer with a typed `CircularDependencyError`, not at the SQLite constraint layer. Unit tests cover the cycle detection algorithm.

---

### REQ-022: Stale Project Handling

**Priority:** P2 (medium)
**MoSCoW:** Should

The system shall gracefully handle registered projects whose directories have been deleted or moved, without crashing or corrupting the registry.

**Acceptance Criteria:**

- AC-022.1: `foreman project list` checks filesystem accessibility for each registered project path. Stale entries (inaccessible paths) are displayed with `STATUS=stale` and a `[!]` warning indicator. The check uses `fs.access()` and does not attempt to open the database for stale entries.
- AC-022.2: All commands that accept `--project <name>` check path accessibility before proceeding. If the resolved path is stale, the command exits with: `"Project '<name>' path is no longer accessible: <path>. Update the registry with 'foreman project add <new-path> --name <name>' or remove it with 'foreman project remove <name>'."`.
- AC-022.3: `foreman project remove --stale` removes all stale entries from the registry atomically (read-modify-write with file lock). It prints the count and names of removed entries.

---

## 14. Implementation Strategy

### 14.1 Phased Delivery

This PRD is explicitly multi-sprint. The recommended delivery sequence minimizes risk by establishing the foundation before replacing beads.

**Sprint 1 -- Foundation (REQ-001, REQ-002, REQ-003, REQ-004, REQ-020)**
- Global project registry (`~/.foreman/projects.json`)
- `foreman project add/list/remove`
- Native task store schema (DDL migration in `foreman init`)
- Stale project handling
- Zero behavior change for existing projects

**Sprint 2 -- Task CLI and Approval Gate (REQ-005, REQ-006, REQ-007, REQ-008)**
- `foreman task create/list/show/update/close/approve`
- Approval gate logic
- Dependency graph management
- Replaces `br` for new projects

**Sprint 3 -- Dispatcher and Pipeline Integration (REQ-009, REQ-017, REQ-018)**
- Dispatcher queries native task store
- Pipeline executor phase status updates
- Refinery closes native tasks post-merge
- Sling creates native tasks

**Sprint 4 -- Dashboard and Cross-Project (REQ-010, REQ-011, REQ-012, REQ-016, REQ-019)**
- Cross-project dashboard aggregation
- "Needs Human" panel
- `--project` flag on dispatch commands
- `foreman status --all`

**Sprint 5 -- Migration and Deprecation (REQ-013, REQ-014, REQ-015)**
- `foreman task import --from-beads`
- Coexistence / fallback logic
- `BeadsRustClient` deprecation
- `foreman doctor` native task store awareness

### 14.2 Module Structure

```
src/lib/
  task-store.ts              -- NativeTaskStore class
  project-registry.ts        -- ProjectRegistry class (reads/writes projects.json)
  beads-rust.ts              -- @deprecated, kept as compatibility shim

src/cli/commands/
  project.ts                 -- foreman project add/list/remove
  task.ts                    -- foreman task create/list/show/update/approve/close
  status.ts                  -- updated: adds --all flag
  dashboard.ts               -- updated: cross-project aggregation

src/orchestrator/
  dispatcher.ts              -- updated: native task store query
  refinery.ts                -- updated: closes native tasks post-merge
  pipeline-executor.ts       -- updated: phase status updates

src/lib/
  task-store.ts
    __tests__/
      task-store.test.ts
      dependency-graph.test.ts

src/lib/
  project-registry.ts
    __tests__/
      project-registry.test.ts
```

---

## 15. Risks and Mitigations

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Big-bang beads replacement breaks existing workflows | Medium | High | Coexistence period (REQ-014) + per-project opt-in migration. Beads fallback remains until all projects migrated. |
| SQLite write contention between agent workers and dashboard reads | Medium | Medium | Dashboard opens DBs read-only (AC-019.2). Agent writes use WAL mode (already configured). |
| Circular dependency introduced in task graph via import | Low | Medium | Cycle detection at `NativeTaskStore` layer with typed error (AC-021.3). Import performs cycle check before committing. |
| Registered project path deleted; commands crash | Low | Low | Stale project checks on all cross-project paths (REQ-022). |
| Dashboard refresh exceeds 2s with 7 projects | Low | Medium | Parallel read across project DBs; benchmark test gates release (AC-019.1). |
| Sling creates native tasks before schema migration runs | Low | Low | Auto-migration in sling entry point (AC-009.3). |
| Dispatcher double-dispatch race condition | Low | High | Atomic transaction for task claim + run creation (AC-017.2). |

---

## 16. Acceptance Criteria Summary

| Req | Title | ACs | Priority | MoSCoW |
|-----|-------|-----|----------|--------|
| REQ-001 | Global Project Registry | 4 | P0 | Must |
| REQ-002 | Project Listing and Health Status | 3 | P0 | Must |
| REQ-003 | Task Schema with Workflow-Aware Statuses | 3 | P0 | Must |
| REQ-004 | Task Dependency Graph | 3 | P1 | Must |
| REQ-005 | Approval Gate | 3 | P0 | Must |
| REQ-006 | `foreman task create` | 3 | P0 | Must |
| REQ-007 | `foreman task list`, `show`, `update` | 3 | P0 | Must |
| REQ-008 | `foreman task close` and Manual Status Control | 2 | P1 | Must |
| REQ-009 | Sling Integration -- Native Task Creation | 3 | P1 | Must |
| REQ-010 | Cross-Project Dashboard Aggregation | 3 | P0 | Must |
| REQ-011 | "Needs Human" Panel | 3 | P0 | Must |
| REQ-012 | Pipeline Phase Visibility | 2 | P1 | Must |
| REQ-013 | Beads Import Command | 4 | P0 | Must |
| REQ-014 | Coexistence -- Fallback to Beads | 3 | P1 | Must |
| REQ-015 | Beads Deprecation Path | 2 | P2 | Should |
| REQ-016 | `--project` Flag on Dispatch Commands | 3 | P0 | Must |
| REQ-017 | Dispatcher Reads Native Task Store | 3 | P0 | Must |
| REQ-018 | Refinery Closes Native Tasks Post-Merge | 2 | P1 | Must |
| REQ-019 | Dashboard Refresh Performance | 2 | P1 | Must |
| REQ-020 | Backward Compatibility During Transition | 2 | P0 | Must |
| REQ-021 | TypeScript Strict Mode and Test Coverage | 3 | P1 | Must |
| REQ-022 | Stale Project Handling | 3 | P2 | Should |
| **Total** | | **62** | | |

---

## 17. Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Time to identify a task needing human attention (cross-project) | < 5 seconds from `foreman dashboard` open | Operator observation; dashboard "Needs Human" panel load time |
| Dashboard refresh time (7 projects) | < 2 seconds | Automated benchmark (AC-019.1) |
| Projects migrated from beads to native store (adoption) | 100% within 60 days of Sprint 5 release | `foreman doctor` reports across registered projects |
| Reduction in context-switch events (operator survey) | >= 50% reduction in tmux window switches per work session | Operator self-report |
| `br` invocations remaining in Foreman codebase post-implementation | 0 (outside compatibility shim) | `grep -r "BeadsRustClient" src/ --include="*.ts"` excluding `beads-rust.ts` |
| Pipeline phase visibility in dashboard | All in-progress tasks show phase name (not generic "in-progress") | Dashboard screenshot at each phase transition |

---

## 18. Release Plan

### Gate Criteria

**Sprint 1 complete when:**
- `foreman project add/list/remove` functional with health status
- Schema migration runs idempotently on existing and new projects
- All existing integration tests pass unchanged

**Sprint 2 complete when:**
- `foreman task create/list/show/update/close/approve` functional
- Approval gate tested end-to-end (create -> approve -> dispatcher picks up)
- Dependency blocking and unblocking tested

**Sprint 3 complete when:**
- Dispatcher uses native task store for a complete end-to-end pipeline run
- Pipeline phase status updates visible in `foreman task show`
- Refinery marks tasks `merged` post-merge
- Sling creates native tasks

**Sprint 4 complete when:**
- `foreman dashboard` shows all registered projects
- "Needs Human" panel populated from cross-project scan
- `foreman status --all` and `--project` flag functional
- Dashboard benchmark passes (< 2s for 7 projects)

**Sprint 5 complete when:**
- `foreman task import --from-beads` tested on real beads data
- Coexistence fallback verified on a project with no native tasks
- `foreman doctor` reflects native/beads mode correctly
- `BeadsRustClient` deprecated with no internal usages outside shim

---

## 19. Open Questions

All adversarial gaps identified during pre-publication review have been resolved and incorporated into the requirements above. The resolutions are documented below for traceability.

| OQ | Question | Resolution | Incorporated In |
|----|----------|------------|-----------------|
| OQ-1 | How does the dispatcher know which task store to query? | Dispatcher reads from local project's SQLite (cwd-based); global dashboard aggregates read-only. | REQ-017, REQ-014 |
| OQ-2 | What is the definition of "needs human"? | Any task with status `conflict`, `failed`, `stuck`, or `backlog` (awaiting approval). | REQ-011 |
| OQ-3 | Does the native task store support a dependency graph? | Yes -- `task_dependencies` table with `blocks` and `parent-child` types. | REQ-004 |
| OQ-4 | Big-bang beads replacement risk? | Coexistence period with per-project opt-in migration. Dispatcher falls back to beads if native store empty. | REQ-014, REQ-020 |
| OQ-5 | How are tasks created by `foreman sling trd`? | Sling creates native tasks directly via `NativeTaskStore.create()` after this PRD. | REQ-009 |
| OQ-6 | What if a registered project's directory is deleted? | `foreman project list` flags stale entries; all cross-project commands check accessibility before operating. | REQ-022 |
