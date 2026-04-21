---
document_id: TRD-2026-006
prd_reference: PRD-2026-006
version: 1.0.0
status: Draft
date: 2026-03-30
design_readiness_score: 4.0
---

# TRD-2026-006: Multi-Project Native Task Management

## Architecture Decision

### Chosen Approach: Option C -- Extend Existing Infrastructure

Extend the existing `NativeTaskStore` class (`src/lib/task-store.ts`, 168 lines) and the `foreman.db` SQLite schema (which already includes `tasks` and `task_dependencies` DDL) with the missing methods (`create()`, `approve()`, `ready()`, dependency graph operations, cycle detection). Build `ProjectRegistry` as a standalone class reading `~/.foreman/projects.json`. Add Commander subcommand groups for `foreman project` and `foreman task`. Dashboard reads all project DBs read-only in parallel.

**Key insight:** The `tasks` and `task_dependencies` tables already exist in `store.ts` DDL. The `NativeTaskStore` class already has `hasNativeTasks()`, `list()`, `claim()`, `updatePhase()`, and `updateStatus()`. The `ITaskClient` interface in `task-client.ts` defines the contract the dispatcher uses. This TRD extends what exists rather than replacing it, and the dispatcher's coexistence check (`hasNativeTasks()`) is already partially implemented.

### Alternatives Considered

| Option | Pros | Cons | Rejected Because |
|--------|------|------|------------------|
| A: Separate SQLite DB per feature | Clean isolation, no migration risk | Two DB files per project, connection management complexity, WAL contention across files | Unnecessary complexity; existing `foreman.db` already has the tables |
| B: Replace NativeTaskStore with new class | Clean-slate design, no legacy baggage | Breaks existing pipeline-executor calls to `updatePhase()`, ~168 lines rewritten | Working code exists; extend, don't rewrite |
| D: JSON file store (no SQLite) | Simple, human-readable, git-trackable | No concurrent access safety, no transactions, no atomic claim | Multi-agent concurrency requires SQLite transactions |

### Architecture Diagram

```
~/.foreman/
  projects.json  <-- ProjectRegistry (name -> path)
  config.yaml    <-- global defaults (dashboard.refreshInterval, etc.)

Per-Project (.foreman/foreman.db)
  tasks               <-- NativeTaskStore (extended)
  task_dependencies   <-- dependency graph (blocks / parent-child)
  runs                <-- existing
  merge_queue         <-- existing
  messages            <-- existing

CLI Layer:
  foreman project add/list/remove  -->  ProjectRegistry
  foreman task create/list/show/    -->  NativeTaskStore
    update/approve/close/import
  foreman run --project <name>      -->  ProjectRegistry.resolve() -> Dispatcher
  foreman status --all              -->  ProjectRegistry.list() -> parallel DB reads
  foreman dashboard                 -->  ProjectRegistry.list() -> parallel read-only DB opens
                                          -> aggregated TUI with "Needs Human" panel

Dispatcher Flow (native mode):
  getReadyTasks()
    |-- hasNativeTasks()? --yes--> SELECT * FROM tasks WHERE status='ready'
    |                              ORDER BY priority ASC, created_at ASC
    |-- no --> BeadsRustClient.ready() (fallback)

Pipeline Integration:
  pipeline-executor.ts  --phase transition-->  taskStore.updatePhase(taskId, phase)
  refinery.ts           --post-merge------>    taskStore.updateStatus(taskId, 'merged')
  sling.ts              --task creation--->    taskStore.create(...)
```

### Component Boundaries

| Component | File | Responsibility |
|-----------|------|----------------|
| **ProjectRegistry** | `src/lib/project-registry.ts` | Read/write `~/.foreman/projects.json`; resolve name-to-path; health checks |
| **NativeTaskStore** (extended) | `src/lib/task-store.ts` | CRUD + approve + ready query + dependency graph + cycle detection |
| **Project CLI** | `src/cli/commands/project.ts` | `foreman project add/list/remove` subcommands |
| **Task CLI** | `src/cli/commands/task.ts` | `foreman task create/list/show/update/approve/close/import` subcommands |
| **Dispatcher** (updated) | `src/orchestrator/dispatcher.ts` | Native task store query; `--project` resolution; coexistence logic |
| **Refinery** (updated) | `src/orchestrator/refinery.ts` | Close native tasks post-merge |
| **Pipeline Executor** (existing) | `src/orchestrator/pipeline-executor.ts` | Phase status updates (already calls `updatePhase()`) |
| **Sling** (updated) | `src/cli/commands/sling.ts` | Create native tasks instead of `br create` |
| **Dashboard** (updated) | `src/cli/commands/dashboard.ts` | Cross-project aggregation; "Needs Human" panel |
| **Status** (updated) | `src/cli/commands/status.ts` | `--all` flag; `--project` flag |
| **Doctor** (updated) | `src/cli/commands/doctor.ts` | Native task store mode reporting |

### Data Flow

```
1. Operator registers projects: foreman project add /path/to/repo
   -> ProjectRegistry writes to ~/.foreman/projects.json

2. Operator creates tasks: foreman task create --title "..." --type feature --priority 1
   -> NativeTaskStore.create() inserts row with status='backlog'
   -> Operator runs: foreman task approve <id>
   -> NativeTaskStore.approve() sets status='ready', approved_at=now()
   -> If blocked: status='blocked' instead

3. Dispatcher picks up ready tasks: foreman run [--project <name>]
   -> If --project: ProjectRegistry.resolve(name) -> cwd override
   -> Dispatcher.getReadyTasks() -> SELECT * FROM tasks WHERE status='ready'
   -> Dispatcher.claim(taskId, runId) -> atomic transaction
   -> Pipeline executor runs phases, calls updatePhase() at each transition

4. Refinery merges completed work:
   -> refinery calls taskStore.updateStatus(taskId, 'merged', {closedAt: now()})
   -> Cascade: re-evaluate blocked dependents -> unblock if all blockers resolved

5. Dashboard aggregates across projects:
   -> Reads ~/.foreman/projects.json
   -> Opens each project's foreman.db read-only (SQLITE_OPEN_READONLY)
   -> Queries tasks, runs, merge_queue in parallel
   -> Renders unified TUI with "Needs Human" panel at top
```

---

## Master Task List

### Sprint 1: Foundation (REQ-001, REQ-002, REQ-003, REQ-004, REQ-020)

#### TRD-001: Implement ProjectRegistry class
**3h** | [satisfies REQ-001]
- Validates PRD ACs: AC-001.1, AC-001.2, AC-001.3, AC-001.4
- Implementation ACs:
  - Given `~/.foreman/` does not exist, when `ProjectRegistry.add(path)` is called, then the directory is created and `projects.json` is written with `version: 1` and the project entry
  - Given a valid directory path, when `add(path)` is called without `--name`, then the project name is derived from the directory basename and the path is stored as an absolute resolved path
  - Given a path already registered, when `add(path)` is called, then a `ProjectAlreadyRegisteredError` is thrown with the message format from AC-001.3
  - Given a path without `.foreman/` directory, when `add(path)` is called, then a warning is emitted but registration proceeds

#### TRD-001-TEST: Unit tests for ProjectRegistry
**2h** | [verifies TRD-001] [satisfies REQ-001] [depends: TRD-001]
- Test: add project creates `~/.foreman/projects.json` when absent
- Test: add project derives name from basename
- Test: add project with `--name` alias uses alias
- Test: duplicate path throws `ProjectAlreadyRegisteredError`
- Test: path without `.foreman/` emits warning but succeeds
- Test: auto-creates `~/.foreman/` directory

#### TRD-002: Implement `foreman project add/list/remove` CLI commands
**3h** | [satisfies REQ-001, REQ-002, REQ-022] [depends: TRD-001]
- Validates PRD ACs: AC-001.1, AC-001.2, AC-001.3, AC-002.1, AC-002.2, AC-002.3, AC-022.1, AC-022.3
- Implementation ACs:
  - Given `foreman project add <path>`, when the command runs, then it calls `ProjectRegistry.add()` and prints the confirmation message
  - Given `foreman project list`, when called, then it outputs a table with columns `NAME`, `PATH`, `STATUS`, `ACTIVE AGENTS`, `NEEDS HUMAN` where STATUS is `ok` or `stale` based on `fs.access()` check
  - Given `foreman project remove <name>`, when the project has active agents, then the command exits with error unless `--force` is provided
  - Given `foreman project remove --stale`, when called, then all entries with inaccessible paths are removed atomically

#### TRD-002-TEST: Unit tests for project CLI commands
**2h** | [verifies TRD-002] [satisfies REQ-001, REQ-002, REQ-022] [depends: TRD-002]
- Test: `project add` with valid path registers project
- Test: `project list` shows table with health status
- Test: `project remove` refuses when active agents present
- Test: `project remove --force` overrides active agent check
- Test: `project remove --stale` removes inaccessible entries
- Test: stale path shows `STATUS=stale` in list output

#### TRD-003: Extend NativeTaskStore with `create()` and status constraint validation
**3h** | [satisfies REQ-003, REQ-006]
- Validates PRD ACs: AC-003.1, AC-003.2, AC-003.3, AC-006.1, AC-006.2, AC-006.3
- Implementation ACs:
  - Given valid task fields, when `NativeTaskStore.create({title, description, type, priority})` is called, then a compact `<project-id>-<5 hex>` ID is generated, the task is inserted with `status='backlog'`, and the created task is returned
  - Given an invalid status value, when an insert or update is attempted, then an `InvalidTaskStatusError` is thrown before the SQL executes (TypeScript-layer validation using a const enum of valid statuses)
  - Given a priority outside 0-4, when `create()` is called, then an `InvalidPriorityError` is thrown
  - Given a type not in the valid set, when `create()` is called, then an `InvalidTaskTypeError` is thrown

#### TRD-003-TEST: Unit tests for NativeTaskStore.create() and validation
**2h** | [verifies TRD-003] [satisfies REQ-003, REQ-006] [depends: TRD-003]
- Test: create() generates a compact project-prefixed ID and inserts with `status='backlog'`
- Test: create() with all optional fields populates them correctly
- Test: invalid status throws `InvalidTaskStatusError`
- Test: priority outside 0-4 throws `InvalidPriorityError`
- Test: unknown type throws `InvalidTaskTypeError`
- Test: created_at and updated_at are set to current ISO timestamp

#### TRD-004: Implement dependency graph operations and cycle detection
**4h** | [satisfies REQ-004, REQ-021]
- Validates PRD ACs: AC-004.1, AC-004.2, AC-004.3, AC-021.3
- Implementation ACs:
  - Given two task IDs, when `addDependency(fromId, toId, 'blocks')` is called, then a row is inserted into `task_dependencies` and the dependent task's status is re-evaluated (set to `blocked` if the blocker is not `merged`/`closed`)
  - Given a task transitions to `merged` or `closed`, when `updateStatus()` completes, then all tasks blocked by it are re-evaluated; any task with no remaining open blockers transitions from `blocked` to `ready` (if previously approved)
  - Given a dependency that would create a cycle (direct or transitive), when `addDependency()` is called, then a `CircularDependencyError` is thrown and no row is inserted
  - Given a `parent-child` dependency, when added, then it is stored but does not affect `ready` query or `blocked` status transitions
  - Given a task blocks itself directly, when `addDependency(id, id, 'blocks')` is called, then `CircularDependencyError` is thrown

#### TRD-004-TEST: Unit tests for dependency graph and cycle detection
**2h** | [verifies TRD-004] [satisfies REQ-004, REQ-021] [depends: TRD-004]
- Test: addDependency creates `blocks` row
- Test: addDependency with `blocks` sets dependent to `blocked` if blocker is open
- Test: closing a blocker unblocks dependent tasks
- Test: parent-child deps do not affect `blocked` status
- Test: direct self-cycle throws `CircularDependencyError`
- Test: transitive cycle (A->B->C->A) throws `CircularDependencyError`
- Test: unblocking only applies to tasks that were previously approved

#### TRD-005: Implement `ready()` method on NativeTaskStore
**1h** | [satisfies REQ-017, REQ-020] [depends: TRD-004]
- Validates PRD ACs: AC-005.1, AC-017.1
- Implementation ACs:
  - Given tasks in various statuses, when `ready()` is called, then it returns only tasks with `status = 'ready'` and `run_id IS NULL`, ordered by priority ASC then created_at ASC
  - Given the `FOREMAN_TASK_STORE=native` env var, when `ready()` returns an empty array, then the dispatcher does not fall back to beads

#### TRD-005-TEST: Unit tests for ready() query
**1h** | [verifies TRD-005] [satisfies REQ-017, REQ-020] [depends: TRD-005]
- Test: ready() returns only `status='ready'` tasks
- Test: ready() excludes tasks with non-null `run_id`
- Test: ready() sorts by priority then created_at
- Test: ready() excludes `backlog`, `blocked`, `in-progress`, `merged` tasks

#### TRD-006: Backward compatibility -- existing integration tests pass unchanged
**1h** | [satisfies REQ-020]
- Validates PRD ACs: AC-020.1, AC-020.2
- Implementation ACs:
  - Given a project with no rows in the `tasks` table, when any existing `foreman` command runs, then behavior is identical to before this TRD (no regression)
  - Given the `foreman task` command group is added, when existing commands (`foreman run`, `foreman status`, etc.) are invoked, then they function without modification

#### TRD-006-TEST: Backward compatibility regression tests
**1h** | [verifies TRD-006] [satisfies REQ-020] [depends: TRD-006]
- Test: empty `tasks` table does not affect dispatcher fallback to beads
- Test: existing `foreman status` output unchanged when no native tasks
- Test: `foreman init` on existing DB adds tables without data loss

---

### Sprint 2: Task CLI and Approval Gate (REQ-005, REQ-006, REQ-007, REQ-008)

#### TRD-007: Implement `foreman task create/list/show/update/close` CLI commands
**4h** | [satisfies REQ-006, REQ-007, REQ-008] [depends: TRD-003]
- Validates PRD ACs: AC-006.1, AC-006.2, AC-006.3, AC-007.1, AC-007.2, AC-007.3, AC-008.1, AC-008.2
- Implementation ACs:
  - Given `foreman task create --title "X" --type feature --priority 1`, when the command runs, then `NativeTaskStore.create()` is called and the output matches `"Created task <id>: <title> [backlog]"`
  - Given `foreman task list`, when called, then tasks with `status != 'merged'` and `status != 'closed'` are shown in a table with columns `ID`, `TITLE`, `TYPE`, `PRI`, `STATUS`; `--all` includes all statuses; `--status <val>` filters
  - Given `foreman task show <id>`, when called, then full task detail is displayed including dependencies in both directions with type labels
  - Given `foreman task update <id> --status merged`, when the transition is backward and `--force` is not provided, then the command exits with non-zero status
  - Given `foreman task close <id>`, when called, then status is set to `closed`, `closed_at` is set, and blocked dependents are re-evaluated

#### TRD-007-TEST: Unit tests for task CLI commands
**3h** | [verifies TRD-007] [satisfies REQ-006, REQ-007, REQ-008] [depends: TRD-007]
- Test: `task create` with required flags creates task in backlog
- Test: `task create` with invalid priority shows error
- Test: `task list` excludes merged/closed by default
- Test: `task list --all` includes all statuses
- Test: `task list --status ready` filters correctly
- Test: `task show` displays full detail with dependencies
- Test: `task update --status` validates forward transitions
- Test: `task update --status --force` allows backward transitions
- Test: `task close` sets closed_at and re-evaluates dependents

#### TRD-008: Implement approval gate (`foreman task approve`)
**2h** | [satisfies REQ-005] [depends: TRD-003, TRD-004]
- Validates PRD ACs: AC-005.1, AC-005.2, AC-005.3
- Implementation ACs:
  - Given a task with `status='backlog'`, when `NativeTaskStore.approve(id)` is called, then `status` is set to `ready`, `approved_at` is set to now, and confirmation is printed
  - Given a task with `status='backlog'` and unresolved `blocks` dependencies, when `approve(id)` is called, then `status` is set to `blocked` (not `ready`) and the blocking task IDs are listed in the output
  - Given a task not in `backlog` status, when `approve(id)` is called, then a message is printed indicating no change and the command exits with status 0
  - Given `foreman task approve --all --from-sling <seed>`, when called, then all tasks created by that sling seed are approved in a single transaction

#### TRD-008-TEST: Unit tests for approval gate
**1h** | [verifies TRD-008] [satisfies REQ-005] [depends: TRD-008]
- Test: approve transitions backlog -> ready with approved_at
- Test: approve with unresolved blockers transitions to blocked
- Test: approve on non-backlog task is a no-op
- Test: approve --all --from-sling approves batch

#### TRD-009: Add `--project` flag resolution to NativeTaskStore operations
**2h** | [satisfies REQ-016] [depends: TRD-001, TRD-003]
- Validates PRD ACs: AC-016.1, AC-016.2
- Implementation ACs:
  - Given `--project <name>`, when any `foreman task` command runs, then `ProjectRegistry.resolve(name)` returns the project path and the task store is opened against that project's `foreman.db`
  - Given `--project` with an absolute path not in the registry, when the command runs, then a warning is printed but execution proceeds against the provided path
  - Given `--project` with an unknown name, when the command runs, then the error message from AC-016.1 is printed and the command exits with non-zero status

#### TRD-009-TEST: Unit tests for --project flag resolution
**1h** | [verifies TRD-009] [satisfies REQ-016] [depends: TRD-009]
- Test: `--project` by name resolves from registry
- Test: `--project` by absolute path works with warning
- Test: unknown project name exits with error

---

### Sprint 3: Dispatcher and Pipeline Integration (REQ-009, REQ-017, REQ-018)

#### TRD-010: Update dispatcher to query NativeTaskStore for ready tasks
**3h** | [satisfies REQ-017] [depends: TRD-005]
- Validates PRD ACs: AC-017.1, AC-017.2, AC-017.3
- Implementation ACs:
  - Given the native task store is active (`hasNativeTasks()` returns true), when `dispatcher.getReadyTasks()` runs, then it calls `NativeTaskStore.ready()` directly (no shell exec, no `br` invocation)
  - Given the dispatcher claims a task, when `claim(taskId, runId)` is called, then the status update and run_id assignment happen in the same SQLite transaction (already implemented in `NativeTaskStore.claim()`)
  - Given `FOREMAN_TASK_STORE=native`, when the tasks table is empty, then the dispatcher returns an empty array (does not fall back to beads)
  - Given `FOREMAN_TASK_STORE=beads`, when called, then the dispatcher uses `BeadsRustClient` regardless of native task table contents

#### TRD-010-TEST: Integration tests for dispatcher native task store path
**2h** | [verifies TRD-010] [satisfies REQ-017] [depends: TRD-010]
- Test: dispatcher uses native store when hasNativeTasks() is true
- Test: dispatcher falls back to beads when tasks table empty
- Test: `FOREMAN_TASK_STORE=native` env var forces native path
- Test: `FOREMAN_TASK_STORE=beads` env var forces beads path
- Test: claim() is atomic (no double-dispatch)

#### TRD-011: Update refinery to close native tasks post-merge
**2h** | [satisfies REQ-018] [depends: TRD-005]
- Validates PRD ACs: AC-018.1, AC-018.2
- Implementation ACs:
  - Given a successful merge, when the refinery processes it and the native task store is active, then `taskStore.updateStatus(taskId, 'merged')` is called with `closed_at` set to now
  - Given the task store is in beads fallback mode, when a merge completes, then `syncBeadStatusAfterMerge()` is called instead (existing behavior)
  - Given the run has no associated task ID (pre-migration run), when refinery attempts to close, then a debug-level warning is logged and no error is thrown

#### TRD-011-TEST: Unit tests for refinery native task closure
**1h** | [verifies TRD-011] [satisfies REQ-018] [depends: TRD-011]
- Test: successful merge sets task status to `merged` with `closed_at`
- Test: beads fallback mode calls `syncBeadStatusAfterMerge()`
- Test: missing task ID logs warning, does not throw

#### TRD-012: Update sling to create native tasks instead of beads
**3h** | [satisfies REQ-009] [depends: TRD-003, TRD-004]
- Validates PRD ACs: AC-009.1, AC-009.2, AC-009.3
- Implementation ACs:
  - Given `foreman sling trd <file>`, when tasks are created, then `NativeTaskStore.create()` is called for each task (no `br create` or `BeadsRustClient` calls)
  - Given tasks created by sling, when they are inserted, then `status='backlog'` and operator must approve before dispatch
  - Given the `tasks` table does not exist yet, when sling runs, then the schema migration executes automatically with the message `"Migrating task store to native format..."`
  - Given sling creates tasks with dependencies, when `addDependency()` is called, then `blocks` relationships from the TRD are preserved

#### TRD-012-TEST: Unit tests for sling native task creation
**2h** | [verifies TRD-012] [satisfies REQ-009] [depends: TRD-012]
- Test: sling creates tasks via NativeTaskStore, not br
- Test: created tasks have `status='backlog'`
- Test: auto-migration runs when tasks table absent
- Test: dependencies from TRD are imported as `blocks` relationships
- Test: sling output format preserved (titles, descriptions, priorities)

#### TRD-013: Pipeline phase visibility -- verify updatePhase integration
**1h** | [satisfies REQ-012] [depends: TRD-010]
- Validates PRD ACs: AC-012.1, AC-012.2
- Implementation ACs:
  - Given a pipeline running with a native task, when the executor transitions from `developer` to `qa`, then `taskStore.updatePhase(taskId, 'qa')` is called and the task's status column reads `'qa'`
  - Given `taskId` is null (beads fallback), when `updatePhase()` is called, then it is a no-op (already implemented)

#### TRD-013-TEST: Unit tests for pipeline phase visibility
**1h** | [verifies TRD-013] [satisfies REQ-012] [depends: TRD-013]
- Test: phase transition updates task status to phase name
- Test: null taskId is a no-op
- Test: all phase names are valid task statuses

---

### Sprint 4: Dashboard and Cross-Project (REQ-010, REQ-011, REQ-012, REQ-016, REQ-019)

#### TRD-014: Implement cross-project dashboard aggregation
**4h** | [satisfies REQ-010, REQ-019] [depends: TRD-001, TRD-005]
- Validates PRD ACs: AC-010.1, AC-010.2, AC-010.3, AC-019.1, AC-019.2
- Implementation ACs:
  - Given `foreman dashboard` is invoked, when the registry has N projects, then each project's `foreman.db` is opened with `SQLITE_OPEN_READONLY` flag and queried in parallel
  - Given a project whose database is inaccessible, when the dashboard renders, then that project shows `[offline]` without crashing
  - Given the refresh interval is configured (default 5s), when the interval fires, then all project databases are re-queried and the TUI re-renders
  - Given 7 registered projects with 200 tasks each, when the dashboard refreshes, then the total refresh time is under 2000ms

#### TRD-014-TEST: Integration tests for cross-project dashboard
**2h** | [verifies TRD-014] [satisfies REQ-010, REQ-019] [depends: TRD-014]
- Test: dashboard opens multiple project DBs read-only
- Test: inaccessible project shows `[offline]`
- Test: refresh interval triggers re-query
- Test: benchmark -- 7 projects x 200 tasks refreshes under 2000ms

#### TRD-015: Implement "Needs Human" panel in dashboard
**3h** | [satisfies REQ-011] [depends: TRD-014]
- Validates PRD ACs: AC-011.1, AC-011.2, AC-011.3
- Implementation ACs:
  - Given tasks with status `conflict`, `failed`, `stuck`, or `backlog` across projects, when the dashboard renders, then the "Needs Human" panel shows them sorted by priority (P0 first) then age (oldest first) with columns `PROJECT`, `TASK ID`, `TITLE`, `STATUS`, `AGE`
  - Given no tasks need attention, when the panel renders, then it displays `"No tasks need attention."` in a distinct style
  - Given the operator presses `a` on a `backlog` item, when the keypress is handled, then `NativeTaskStore.approve()` is called on the target project's database
  - Given the operator presses `r` on a `failed` item, when the keypress is handled, then the equivalent of `foreman reset --bead <id> --project <name>` is dispatched

#### TRD-015-TEST: Unit tests for "Needs Human" panel
**2h** | [verifies TRD-015] [satisfies REQ-011] [depends: TRD-015]
- Test: panel lists tasks with attention-needing statuses across projects
- Test: sorting by priority then age
- Test: empty panel shows "No tasks need attention."
- Test: `a` keypress calls approve on correct project DB
- Test: `r` keypress triggers reset on correct project

#### TRD-016: Add `--project` flag to `foreman run`, `reset`, `retry`, `status`
**3h** | [satisfies REQ-016] [depends: TRD-001]
- Validates PRD ACs: AC-016.1, AC-016.2, AC-016.3
- Implementation ACs:
  - Given `foreman run --project <name>`, when the name is in the registry, then the command resolves the path and operates against that project directory
  - Given `foreman status --all`, when called, then a condensed table is output with columns `PROJECT`, `RUNNING AGENTS`, `READY TASKS`, `NEEDS HUMAN`, `LAST ACTIVITY` for all registered projects
  - Given `--project` with an absolute path not in registry, when the command runs, then a warning is printed but execution proceeds
  - Given a stale project path, when `--project` resolves to it, then the error message from AC-022.2 is printed

#### TRD-016-TEST: Unit tests for --project flag on dispatch commands
**2h** | [verifies TRD-016] [satisfies REQ-016] [depends: TRD-016]
- Test: `foreman run --project` resolves from registry
- Test: `foreman status --all` outputs cross-project table
- Test: stale project path exits with descriptive error
- Test: absolute path not in registry works with warning

---

### Sprint 5: Migration and Deprecation (REQ-013, REQ-014, REQ-015)

#### TRD-017: Implement `foreman task import --from-beads`
**4h** | [satisfies REQ-013] [depends: TRD-003, TRD-004]
- Validates PRD ACs: AC-013.1, AC-013.2, AC-013.3, AC-013.4
- Implementation ACs:
  - Given `.beads/beads.jsonl` exists, when `foreman task import --from-beads` runs, then each bead is parsed and mapped: `open`->`backlog`, `in_progress`->`ready`, `closed`->`merged`; type and priority are preserved; the `external_id` column stores the original bead ID
  - Given a bead with `blocks` dependencies, when imported, then `task_dependencies` rows are created with type `blocks`; `parent-child` relationships are also preserved
  - Given `--dry-run`, when the import runs, then no rows are written but the output shows field-level mapping for the first 5 tasks and a total count
  - Given a bead whose `id` matches an existing `external_id` in the native store, when import runs, then it is skipped (no duplicate)

#### TRD-017-TEST: Unit tests for beads import
**2h** | [verifies TRD-017] [satisfies REQ-013] [depends: TRD-017]
- Test: import reads `.beads/beads.jsonl` and creates native tasks
- Test: status mapping (open->backlog, in_progress->ready, closed->merged)
- Test: dependency import (blocks and parent-child)
- Test: `--dry-run` writes no rows, prints mapping
- Test: duplicate detection by external_id skips existing
- Test: import summary message format matches AC-013.1

#### TRD-018: Implement coexistence fallback logic with env var override
**2h** | [satisfies REQ-014] [depends: TRD-010]
- Validates PRD ACs: AC-014.1, AC-014.2, AC-014.3
- Implementation ACs:
  - Given `FOREMAN_TASK_STORE` is not set, when the dispatcher calls `getReadyTasks()`, then `hasNativeTasks()` determines the path and a debug-level log records which path was taken
  - Given `FOREMAN_TASK_STORE=native`, when the tasks table is empty, then native store is used (returns empty, no beads fallback)
  - Given `FOREMAN_TASK_STORE=beads`, when called, then beads client is used regardless of native task table contents
  - Given `foreman doctor`, when the native task store has rows, then output includes `"Task store: native (N tasks)"`; when empty, `"Task store: beads (fallback)"`; when both exist, a warning is emitted per AC-014.3

#### TRD-018-TEST: Unit tests for coexistence fallback
**1h** | [verifies TRD-018] [satisfies REQ-014] [depends: TRD-018]
- Test: no env var -- hasNativeTasks() determines path
- Test: `FOREMAN_TASK_STORE=native` forces native
- Test: `FOREMAN_TASK_STORE=beads` forces beads
- Test: doctor reports correct mode
- Test: doctor warns when both native and beads data exist

#### TRD-019: Deprecate BeadsRustClient and update doctor checks
**2h** | [satisfies REQ-015] [depends: TRD-018]
- Validates PRD ACs: AC-015.1, AC-015.2
- Implementation ACs:
  - Given `src/lib/beads-rust.ts`, when this task is complete, then all exported symbols have `@deprecated` JSDoc tags
  - Given `npx tsc --noEmit`, when run after deprecation, then zero errors are emitted (no internal usages of deprecated symbols outside the compatibility shim)
  - Given `br` binary is absent, when `foreman doctor` runs, then it emits an informational notice `"beads (br) not found -- native task store active."` instead of a failure

#### TRD-019-TEST: Unit tests for deprecation and doctor updates
**1h** | [verifies TRD-019] [satisfies REQ-015] [depends: TRD-019]
- Test: `foreman doctor` without `br` binary emits info notice, not error
- Test: `foreman doctor` with `br` binary and native store active emits migration suggestion
- Test: no TypeScript compilation errors with deprecated annotations

---

## Sprint Planning

### Sprint 1: Foundation (~15h)
- [ ] **TRD-001** (3h): ProjectRegistry class [satisfies REQ-001]
- [ ] **TRD-001-TEST** (2h): Tests for ProjectRegistry [depends: TRD-001]
- [ ] **TRD-002** (3h): Project CLI commands [depends: TRD-001]
- [ ] **TRD-002-TEST** (2h): Tests for project CLI [depends: TRD-002]
- [ ] **TRD-003** (3h): NativeTaskStore.create() + validation [satisfies REQ-003, REQ-006]
- [ ] **TRD-003-TEST** (2h): Tests for create() and validation [depends: TRD-003]
- [ ] **TRD-004** (4h): Dependency graph + cycle detection [CRITICAL PATH] [satisfies REQ-004]
- [ ] **TRD-004-TEST** (2h): Tests for dependency graph [depends: TRD-004]
- [ ] **TRD-005** (1h): ready() method [depends: TRD-004]
- [ ] **TRD-005-TEST** (1h): Tests for ready() [depends: TRD-005]
- [ ] **TRD-006** (1h): Backward compatibility verification [satisfies REQ-020]
- [ ] **TRD-006-TEST** (1h): Regression tests [depends: TRD-006]

### Sprint 2: Task CLI and Approval Gate (~13h)
- [ ] **TRD-007** (4h): Task CLI commands [depends: TRD-003]
- [ ] **TRD-007-TEST** (3h): Tests for task CLI [depends: TRD-007]
- [ ] **TRD-008** (2h): Approval gate [depends: TRD-003, TRD-004]
- [ ] **TRD-008-TEST** (1h): Tests for approval gate [depends: TRD-008]
- [ ] **TRD-009** (2h): --project flag for task commands [depends: TRD-001, TRD-003]
- [ ] **TRD-009-TEST** (1h): Tests for --project resolution [depends: TRD-009]

### Sprint 3: Dispatcher and Pipeline Integration (~15h)
- [ ] **TRD-010** (3h): Dispatcher native task store integration [depends: TRD-005]
- [ ] **TRD-010-TEST** (2h): Tests for dispatcher [depends: TRD-010]
- [ ] **TRD-011** (2h): Refinery native task closure [depends: TRD-005]
- [ ] **TRD-011-TEST** (1h): Tests for refinery [depends: TRD-011]
- [ ] **TRD-012** (3h): Sling native task creation [depends: TRD-003, TRD-004]
- [ ] **TRD-012-TEST** (2h): Tests for sling [depends: TRD-012]
- [ ] **TRD-013** (1h): Pipeline phase visibility [depends: TRD-010]
- [ ] **TRD-013-TEST** (1h): Tests for phase visibility [depends: TRD-013]

### Sprint 4: Dashboard and Cross-Project (~16h)
- [ ] **TRD-014** (4h): Cross-project dashboard aggregation [depends: TRD-001, TRD-005]
- [ ] **TRD-014-TEST** (2h): Tests for dashboard aggregation [depends: TRD-014]
- [ ] **TRD-015** (3h): "Needs Human" panel [depends: TRD-014]
- [ ] **TRD-015-TEST** (2h): Tests for "Needs Human" panel [depends: TRD-015]
- [ ] **TRD-016** (3h): --project flag on dispatch commands [depends: TRD-001]
- [ ] **TRD-016-TEST** (2h): Tests for --project dispatch [depends: TRD-016]

### Sprint 5: Migration and Deprecation (~12h)
- [ ] **TRD-017** (4h): Beads import command [depends: TRD-003, TRD-004]
- [ ] **TRD-017-TEST** (2h): Tests for beads import [depends: TRD-017]
- [ ] **TRD-018** (2h): Coexistence fallback logic [depends: TRD-010]
- [ ] **TRD-018-TEST** (1h): Tests for coexistence [depends: TRD-018]
- [ ] **TRD-019** (2h): BeadsRustClient deprecation [depends: TRD-018]
- [ ] **TRD-019-TEST** (1h): Tests for deprecation [depends: TRD-019]

**Total: ~71h estimated across 38 tasks (19 implementation + 19 test)**

---

## Acceptance Criteria Traceability

| REQ | Description | Implementation Tasks | Test Tasks |
|-----|-------------|---------------------|------------|
| REQ-001 | Global Project Registry | TRD-001, TRD-002 | TRD-001-TEST, TRD-002-TEST |
| REQ-002 | Project Listing and Health Status | TRD-002 | TRD-002-TEST |
| REQ-003 | Task Schema with Workflow-Aware Statuses | TRD-003 | TRD-003-TEST |
| REQ-004 | Task Dependency Graph | TRD-004 | TRD-004-TEST |
| REQ-005 | Approval Gate | TRD-008 | TRD-008-TEST |
| REQ-006 | `foreman task create` | TRD-003, TRD-007 | TRD-003-TEST, TRD-007-TEST |
| REQ-007 | `foreman task list`, `show`, `update` | TRD-007 | TRD-007-TEST |
| REQ-008 | `foreman task close` and Manual Status Control | TRD-007 | TRD-007-TEST |
| REQ-009 | Sling Integration -- Native Task Creation | TRD-012 | TRD-012-TEST |
| REQ-010 | Cross-Project Dashboard Aggregation | TRD-014 | TRD-014-TEST |
| REQ-011 | "Needs Human" Panel | TRD-015 | TRD-015-TEST |
| REQ-012 | Pipeline Phase Visibility | TRD-013 | TRD-013-TEST |
| REQ-013 | Beads Import Command | TRD-017 | TRD-017-TEST |
| REQ-014 | Coexistence -- Fallback to Beads | TRD-018 | TRD-018-TEST |
| REQ-015 | Beads Deprecation Path | TRD-019 | TRD-019-TEST |
| REQ-016 | `--project` Flag on Dispatch Commands | TRD-009, TRD-016 | TRD-009-TEST, TRD-016-TEST |
| REQ-017 | Dispatcher Reads Native Task Store | TRD-005, TRD-010 | TRD-005-TEST, TRD-010-TEST |
| REQ-018 | Refinery Closes Native Tasks Post-Merge | TRD-011 | TRD-011-TEST |
| REQ-019 | Dashboard Refresh Performance | TRD-014 | TRD-014-TEST |
| REQ-020 | Backward Compatibility | TRD-006 | TRD-006-TEST |
| REQ-021 | TypeScript Strict Mode and Test Coverage | TRD-004 | TRD-004-TEST |
| REQ-022 | Stale Project Handling | TRD-002 | TRD-002-TEST |

---

## Design Readiness Score: 4.0 / 5.0

| Dimension | Score | Notes |
|-----------|-------|-------|
| Architecture Completeness | 4.5 | Existing `tasks`/`task_dependencies` DDL and `NativeTaskStore` class provide a solid foundation; extend rather than build from scratch |
| Task Coverage | 4.0 | All 22 REQs mapped to implementation + test tasks; 38 tasks total covering 62 PRD acceptance criteria |
| Dependency Clarity | 4.0 | Clear sprint ordering; critical path through TRD-004 (dependency graph) gates Sprint 2+3 work |
| Estimate Confidence | 3.5 | Dashboard aggregation (TRD-014) and "Needs Human" panel (TRD-015) have TUI complexity that may exceed estimates; sling refactor depends on sling internals not fully audited |
| **Overall** | **4.0** | Well-structured PRD with clear ACs translates to high-confidence TRD; the main risk is Sprint 4 TUI work and the scope of the cross-project dashboard |
