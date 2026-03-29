---
document_id: TRD-2026-006
prd_reference: PRD-2026-006
version: 1.0.0
status: Draft
date: 2026-03-29
design_readiness_score: 4.25
---

# TRD-2026-006: Multi-Project Native Task Management

**PRD:** PRD-2026-006
**Version:** 1.0.0
**Status:** Draft
**Date:** 2026-03-29
**Design Readiness Score:** 4.25 (PASS)

---

## Table of Contents

1. [Architecture Decision](#1-architecture-decision)
2. [System Architecture](#2-system-architecture)
3. [Master Task List](#3-master-task-list)
4. [Sprint Planning](#4-sprint-planning)
5. [Acceptance Criteria Traceability](#5-acceptance-criteria-traceability)
6. [Quality Requirements](#6-quality-requirements)
7. [Design Readiness Scorecard](#7-design-readiness-scorecard)

---

## 1. Architecture Decision

### Chosen Approach: Option C — Pragmatic Monolith with Extracted Helpers

Matches the existing codebase style (`ForemanStore`, `SqliteMailClient`) without introducing new abstraction layers. Key decisions:

- `NativeTaskStore` in `task-store.ts` — CRUD + state machine as private method table (not a separate class). Mirrors `ForemanStore` structure.
- `ProjectRegistry` in `project-registry.ts` — thin JSON wrapper with health checks. Atomic write via temp-file + rename.
- State machine transitions enforced as a `VALID_TRANSITIONS` map inside `NativeTaskStore`.
- Dependency cycle detection as a tested DFS function extracted for clarity but not a separate class.
- Dashboard aggregation as a helper function in `dashboard.ts`, using `Promise.all()` for parallel DB reads.

### Alternatives Considered

**Option A (Single-file minimal):** Ruled out — `task-store.ts` would exceed 600 lines with no separation between persistence and state logic.

**Option B (Layered services):** Ruled out — introduces `TaskStateMachine`, `CrossProjectAggregator` abstractions that have no precedent in the codebase and would slow Sprint 1-2 delivery.

### Key Interface Decisions

1. **`WorkerConfig.taskId?: string`** — dispatcher sets this when claiming a native task; pipeline executor passes it to `updatePhase()`. No-op when null (beads fallback mode).

2. **Atomic claim transaction** — `NativeTaskStore.claim(id, runId, db?)` accepts an optional external DB connection so the dispatcher can wrap run creation + task claim in a single SQLite transaction.

3. **Dashboard write actions** — dashboard opens DBs read-only for aggregation. Approve/retry actions open a short-lived write connection to the target project's DB.

4. **Coexistence signal** — `NativeTaskStore.hasNativeTasks(): boolean` checks if `tasks` table exists AND has rows. Dispatcher calls this first; if false, falls back to `BeadsRustClient`.

---

## 2. System Architecture

### Module Structure

```
src/lib/
  project-registry.ts          ← ProjectRegistry class
  task-store.ts                ← NativeTaskStore class

src/cli/commands/
  project.ts                   ← foreman project add/list/remove  (NEW)
  task.ts                      ← foreman task create/list/show/update/approve/close/import  (NEW)
  status.ts                    ← extended: --all flag  (MODIFIED)
  dashboard.ts                 ← extended: cross-project aggregation  (MODIFIED)

src/orchestrator/
  dispatcher.ts                ← updated: native task store query + coexistence fallback  (MODIFIED)
  refinery.ts                  ← updated: closes native tasks post-merge  (MODIFIED)
  pipeline-executor.ts         ← updated: phase status updates  (MODIFIED)
```

### Data Flow

```
foreman project add <path>
  └─> ProjectRegistry.add(path) → ~/.foreman/projects.json

foreman task create --title "X"
  └─> NativeTaskStore.create({...}) → INSERT INTO tasks (status='backlog')

foreman task approve <id>
  └─> NativeTaskStore.approve(id)
      ├─ no blocking deps → UPDATE status='ready', approved_at=now
      └─ has blocking deps → UPDATE status='blocked'

foreman run [--project <name>]
  └─> ProjectRegistry.resolve(name) → absolute path
  └─> dispatcher.getReadyTasks(projectPath)
      ├─ NativeTaskStore.hasNativeTasks() = true
      │   └─> SELECT * FROM tasks WHERE status='ready' ORDER BY priority, created_at
      └─ fallback: BeadsRustClient.getReadyTasks()
  └─> NativeTaskStore.claim(id, runId, db) [atomic transaction]
  └─> WorkerConfig{ taskId, ... } → spawn agent worker

pipeline-executor at each phase transition
  └─> NativeTaskStore.updatePhase(taskId, phaseName)  [no-op if taskId null]

refinery post-merge
  └─> NativeTaskStore.updateStatus(taskId, 'merged')
  └─> NativeTaskStore.unblockDependents(taskId)

foreman dashboard
  └─> ProjectRegistry.list()
  └─> Promise.all(projects.map(p => readProjectSnapshot(p.path)))
      └─ each: open DB READONLY, query tasks+runs, close
  └─> render TUI: "Needs Human" panel + per-project panels
  └─> refresh every 5s (configurable)
  └─> on approve/retry action: open write connection to target project DB
```

### SQLite Schema Additions

```sql
-- Added to existing .foreman/foreman.db

CREATE TABLE IF NOT EXISTS tasks (
  id           TEXT PRIMARY KEY,              -- UUID v4
  external_id  TEXT,                          -- original bead ID (for import deduplication)
  title        TEXT NOT NULL,
  description  TEXT,
  type         TEXT NOT NULL DEFAULT 'task',  -- task|bug|feature|epic|chore|docs|question
  priority     INTEGER NOT NULL DEFAULT 2,    -- 0 (critical) - 4 (backlog)
  status       TEXT NOT NULL DEFAULT 'backlog',
  run_id       TEXT REFERENCES runs(id),
  branch       TEXT,
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL,
  approved_at  TEXT,
  closed_at    TEXT,
  CHECK (status IN (
    'backlog','ready','in-progress','explorer','developer',
    'qa','reviewer','finalize','merged','conflict','failed',
    'stuck','blocked','closed'
  ))
);

CREATE TABLE IF NOT EXISTS task_dependencies (
  from_task_id  TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  to_task_id    TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  type          TEXT NOT NULL DEFAULT 'blocks',  -- 'blocks' | 'parent-child'
  PRIMARY KEY (from_task_id, to_task_id, type)
);

CREATE INDEX IF NOT EXISTS idx_tasks_status   ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_priority ON tasks(priority, created_at);
```

### State Machine

```
backlog ──approve──> ready       (if no unresolved blocks)
backlog ──approve──> blocked     (if unresolved blocks)
ready   ──claim───> in-progress
in-progress ──phase──> explorer|developer|qa|reviewer|finalize
explorer|developer|qa|reviewer|finalize ──phase──> (next phase)
any-active ──complete──> merged
any-active ──conflict──> conflict
any-active ──fail────> failed|stuck
blocked ──unblock──> ready       (when all blocking tasks merged/closed)
any ──force──> any               (with --force flag)
```

### Global Registry Format

```json
// ~/.foreman/projects.json
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

---

## 3. Master Task List

### Sprint 1 — Foundation

- [ ] **TRD-001** (4h): Create `ProjectRegistry` class in `src/lib/project-registry.ts`. Implements `add(path, name?)`, `list()`, `remove(name)`, `resolve(nameOrPath)`, `removeStale()`, `hasProject(name)`. Reads/writes `~/.foreman/projects.json` atomically (write to temp file + rename). Creates `~/.foreman/` on first write. Exposes `ProjectEntry` type and `DuplicateProjectError`, `ProjectNotFoundError` typed errors. [satisfies REQ-001, REQ-002, REQ-022]
  - Validates PRD ACs: AC-001.1, AC-001.2, AC-001.3, AC-001.4, AC-002.1, AC-002.2, AC-002.3, AC-022.1, AC-022.2, AC-022.3
  - Implementation ACs:
    - Given `~/.foreman/` does not exist, when `add()` is called, then the directory is created before writing
    - Given `add()` is called with a path already in the registry, then `DuplicateProjectError` is thrown with the existing name
    - Given `list()` is called, each entry includes `status: 'ok' | 'stale'` based on `fs.access()` check
    - Given `removeStale()` is called, all entries with inaccessible paths are removed atomically

- [ ] **TRD-001-TEST** (2h): Unit tests for `ProjectRegistry`: add (happy path, warning on missing .foreman/, duplicate error, auto-mkdir), list (stale detection), remove (active-agents guard), resolve (name, path, not-found), removeStale. [verifies TRD-001] [satisfies REQ-001, REQ-002, REQ-022] [depends: TRD-001]

- [ ] **TRD-002** (3h): Add SQLite DDL migration for `tasks` and `task_dependencies` tables (including `external_id` column and indexes). Migration runs idempotently via `CREATE TABLE IF NOT EXISTS`. Wired into `ForemanStore` constructor (runs on every open, no-op on existing DBs). Includes CHECK constraint on `status`. Exports `InvalidTaskStatusError`. [satisfies REQ-003, REQ-004, REQ-020]
  - Validates PRD ACs: AC-003.1, AC-003.2, AC-003.3, AC-020.1
  - Implementation ACs:
    - Given `ForemanStore.open()` on existing DB with runs/messages, when migration runs, then only `tasks` and `task_dependencies` are added; existing data is unchanged
    - Given migration runs twice, then no error and no duplicate tables or indexes
    - Given `INSERT INTO tasks (status='invalid')`, then SQLite CHECK constraint rejects it; TypeScript layer throws `InvalidTaskStatusError`

- [ ] **TRD-002-TEST** (2h): Integration tests for schema migration idempotency on new DB, on existing DB, and on DB migrated twice. Test `InvalidTaskStatusError` propagation. [verifies TRD-002] [satisfies REQ-003, REQ-020] [depends: TRD-002]

- [ ] **TRD-003** (4h): Implement `foreman project add/list/remove` CLI commands in `src/cli/commands/project.ts`. Register as `project` Commander subcommand group in `src/cli/index.ts`. Handles `--name` alias for `add`, `--force` for `remove`, `--stale` for `remove`. [satisfies REQ-001, REQ-002, REQ-022] [depends: TRD-001]
  - Validates PRD ACs: AC-001.1, AC-001.2, AC-001.3, AC-002.1, AC-002.2, AC-002.3, AC-022.3

- [ ] **TRD-003-TEST** (2h): Unit tests for `project.ts` commands with mocked `ProjectRegistry`. Tests: add (valid path, missing .foreman/ warning, duplicate), list (table output, stale indicator), remove (active-agents guard, --force bypass, --stale). [verifies TRD-003] [satisfies REQ-001, REQ-002] [depends: TRD-003]

### Sprint 2 — Native Task Store + Task CLI

- [ ] **TRD-004** (6h): Implement `NativeTaskStore` class in `src/lib/task-store.ts`. Constructor takes `db: Database` (better-sqlite3). Methods: `create(fields)`, `get(id)`, `list(filter?)`, `update(id, fields)`, `close(id, reason?)`, `approve(id)`, `claim(id, runId, db?)`, `updatePhase(id, phase)`, `updateStatus(id, status, opts?)`, `hasNativeTasks()`. Private: `transition(id, newStatus, force?)` enforces state machine via `VALID_TRANSITIONS` map. Throws `TaskNotFoundError`, `InvalidTransitionError`, `InvalidTaskStatusError`. [satisfies REQ-003, REQ-004, REQ-005, REQ-017] [depends: TRD-002]
  - Validates PRD ACs: AC-003.1, AC-003.2, AC-003.3, AC-004.1, AC-004.2, AC-004.3, AC-005.1, AC-005.2, AC-005.3, AC-017.1, AC-017.2, AC-017.3
  - Implementation ACs:
    - Given `claim(id, runId, db)`, when executed, then the `UPDATE tasks` and run creation are wrapped in the same `db.transaction()` call, preventing double-dispatch
    - Given `approve(id)` on task with unresolved `blocks` dep, then status becomes `blocked` and prints blocking task IDs
    - Given `updatePhase(null, 'qa')`, then the call is a no-op (returns without error)
    - Given `hasNativeTasks()` on DB with no tasks table, then returns `false` (catches error gracefully)

- [ ] **TRD-004-TEST** (3h): Unit tests for `NativeTaskStore`: CRUD, state machine transitions (valid, invalid, force), approval gate (no deps → ready, with deps → blocked), atomic claim (verify transaction), `hasNativeTasks` (table absent, empty, populated), `updatePhase` no-op on null. [verifies TRD-004] [satisfies REQ-003-005, REQ-017] [depends: TRD-004]

- [ ] **TRD-005** (3h): Add dependency graph management to `NativeTaskStore`: `addDependency(fromId, toId, type)`, `removeDependency(fromId, toId)`, `getDependencies(id)`, `getBlockers(id)`, `unblockDependents(id)`. Cycle detection via DFS on `task_dependencies` adjacency list — throws `CircularDependencyError` before inserting. `unblockDependents` re-evaluates all tasks blocked by `id`: if no remaining open blockers, transitions to `ready` (if previously approved). [satisfies REQ-004, REQ-021] [depends: TRD-004]
  - Validates PRD ACs: AC-004.1, AC-004.2, AC-004.3, AC-021.3

- [ ] **TRD-005-TEST** (2h): Unit tests for dependency graph: addDependency (valid, duplicate no-op, circular detection — direct and transitive), removeDependency, getDependencies both directions, unblockDependents (single blocker resolved, multi-blocker partial, parent-child not affecting ready). [verifies TRD-005] [satisfies REQ-004, REQ-021] [depends: TRD-005]

- [ ] **TRD-006** (5h): Implement `foreman task` Commander subcommand group in `src/cli/commands/task.ts`. Subcommands: `create` (--title required, --description, --type, --priority, --project), `list` (--status, --all, --project, table output), `show <id>` (full detail + dependencies), `update <id>` (--title, --description, --priority, --status, --force, --project), `approve <id>` (--project), `close <id>` (--reason, --project). Wire into `src/cli/index.ts`. [satisfies REQ-006, REQ-007, REQ-008] [depends: TRD-004, TRD-005, TRD-001]
  - Validates PRD ACs: AC-006.1, AC-006.2, AC-006.3, AC-007.1, AC-007.2, AC-007.3, AC-008.1, AC-008.2

- [ ] **TRD-006-TEST** (2h): Unit tests for `task.ts` with mocked `NativeTaskStore`: create (required --title, priority aliases 'critical'→0, invalid type error), list (default excludes merged/closed, --all, --status filter), show (full detail + deps), update (valid transition, invalid without --force, --force overrides), approve (backlog→ready, backlog→blocked), close (sets closed_at, dep re-evaluation). [verifies TRD-006] [satisfies REQ-006-008] [depends: TRD-006]

### Sprint 3 — Dispatcher + Pipeline + Sling

- [ ] **TRD-007** (4h): Update `dispatcher.ts`: add `getReadyTasks(projectPath)` that calls `NativeTaskStore.hasNativeTasks()` first. If true: `SELECT * FROM tasks WHERE status='ready' ORDER BY priority ASC, created_at ASC`. If false: fall back to `BeadsRustClient.getReadyTasks()`. Log which path taken at debug level. Update `claimTask(id, runId, db)` to use `NativeTaskStore.claim()` atomically. Expose `taskId` in the dispatch result for `WorkerConfig`. Add `FOREMAN_TASK_STORE` env var override (values: `native`, `beads`). [satisfies REQ-014, REQ-017, REQ-020] [depends: TRD-004]
  - Validates PRD ACs: AC-014.1, AC-014.2, AC-017.1, AC-017.2, AC-020.1

- [ ] **TRD-007-TEST** (2h): Unit tests for dispatcher coexistence: native path (hasNativeTasks=true → SQL query, no br call), beads fallback (hasNativeTasks=false → BeadsRustClient), FOREMAN_TASK_STORE=native (forces native even if empty), FOREMAN_TASK_STORE=beads (forces fallback), atomic claim (transaction wraps run + task update). [verifies TRD-007] [satisfies REQ-014, REQ-017] [depends: TRD-007]

- [ ] **TRD-008** (2h): Add `taskId?: string` to `WorkerConfig` type. Update `pipeline-executor.ts`: after each phase transition, call `ctx.taskStore?.updatePhase(config.taskId, phaseName)`. Pass `NativeTaskStore` instance to `PipelineContext` as optional `taskStore?: NativeTaskStore`. No-op if `taskId` is null/undefined. [satisfies REQ-012, REQ-017] [depends: TRD-004]
  - Validates PRD ACs: AC-012.2, AC-017.3

- [ ] **TRD-008-TEST** (1h): Unit tests: phase transition calls `updatePhase` with correct phase name; null taskId is a no-op; absent `taskStore` does not throw. [verifies TRD-008] [satisfies REQ-012] [depends: TRD-008]

- [ ] **TRD-009** (2h): Update `refinery.ts`: after successful merge, if native task store active, call `taskStore.updateStatus(taskId, 'merged', { closedAt: new Date() })` and `taskStore.unblockDependents(taskId)`. In beads fallback mode, call existing `syncBeadStatusAfterMerge()`. If `taskId` unresolvable, log debug warning and continue. [satisfies REQ-018] [depends: TRD-004]
  - Validates PRD ACs: AC-018.1, AC-018.2

- [ ] **TRD-009-TEST** (1h): Unit tests: native path calls `updateStatus('merged')` + `unblockDependents`; beads fallback path calls `syncBeadStatusAfterMerge`; unresolvable taskId logs warning without error. [verifies TRD-009] [satisfies REQ-018] [depends: TRD-009]

- [ ] **TRD-010** (3h): Update `src/cli/commands/sling.ts`: replace `br create` / `BeadsRustClient.create()` calls with `NativeTaskStore.create()`. Auto-trigger schema migration if `tasks` table absent (one-time message: `"Migrating task store to native format..."`). Tasks enter `backlog` status. Add `foreman task approve --all --from-sling <seed>` batch-approval shortcut. [satisfies REQ-009] [depends: TRD-004, TRD-002]
  - Validates PRD ACs: AC-009.1, AC-009.2, AC-009.3

- [ ] **TRD-010-TEST** (1h): Unit tests: sling does not call `br create` or `BeadsRustClient`; tasks created with status `backlog`; auto-migration fires when table absent; batch-approve transitions all matching tasks to `ready`. [verifies TRD-010] [satisfies REQ-009] [depends: TRD-010]

### Sprint 4 — Dashboard + Cross-Project

- [ ] **TRD-011** (6h): Update `src/cli/commands/dashboard.ts` for cross-project aggregation. Add `readProjectSnapshot(projectPath): ProjectSnapshot` helper — opens DB `SQLITE_OPEN_READONLY`, queries tasks and runs, closes. Use `Promise.all()` for parallel reads across all registered projects. Render cross-project TUI with: (a) "Needs Human" panel — tasks WHERE status IN ('conflict','failed','stuck','backlog'), sorted by priority then age; (b) per-project agent status panel; (c) task list filterable by project. Refresh loop at 5s default (`--refresh <seconds>` / `dashboard.refreshInterval` config). Interactive: `a` = approve backlog task, `r` = retry failed/stuck, `Enter` = show detail. Write actions use a separate short-lived write connection. [satisfies REQ-010, REQ-011, REQ-012, REQ-019] [depends: TRD-001, TRD-004]
  - Validates PRD ACs: AC-010.1, AC-010.2, AC-010.3, AC-011.1, AC-011.2, AC-011.3, AC-012.1, AC-019.1, AC-019.2

- [ ] **TRD-011-TEST** (2h): Unit tests for `readProjectSnapshot` (inaccessible DB shows `[offline]`, read-only open, parallel reads). Benchmark test in `src/cli/__tests__/dashboard-performance.test.ts`: 7 in-memory SQLite DBs × 200 tasks × 10 runs → full aggregation < 2000ms. Note: keyboard interaction (`a`, `r`, `Enter`) is covered by manual test checklist only (headless terminal limitation). [verifies TRD-011] [satisfies REQ-010, REQ-011, REQ-019] [depends: TRD-011]

- [ ] **TRD-012** (3h): Add `--project <name-or-path>` option to `foreman run`, `foreman reset`, `foreman retry`, `foreman status`. Option resolves project from `ProjectRegistry.resolve()`, sets `process.chdir()` (or passes resolved path) before command execution. Add `foreman status --all`: outputs cross-project table with `PROJECT`, `RUNNING AGENTS`, `READY TASKS`, `NEEDS HUMAN`, `LAST ACTIVITY`. Print warning for path-only `--project` not in registry. [satisfies REQ-016] [depends: TRD-001]
  - Validates PRD ACs: AC-016.1, AC-016.2, AC-016.3

- [ ] **TRD-012-TEST** (1h): Unit tests: `--project foreman` resolves to registered path; unregistered name exits with error message; absolute path with no registry entry prints warning + continues; stale path exits with descriptive message; `--all` output includes all registered projects. [verifies TRD-012] [satisfies REQ-016, REQ-022] [depends: TRD-012]

### Sprint 5 — Migration + Deprecation

- [ ] **TRD-013** (4h): Implement `foreman task import --from-beads [--dry-run]` in `task.ts`. Reads `.beads/beads.jsonl`, maps each bead: `open`→`backlog`, `in_progress`→`backlog` (not auto-approved), `closed`→`merged`; `type=epic`→`type=epic`; dependencies preserved. Skips rows where `external_id` already exists in `tasks`. `--dry-run` prints first 5 task mappings without writing. Prints summary: `"Imported N tasks (M skipped: already exist)."` [satisfies REQ-013] [depends: TRD-004, TRD-002]
  - Validates PRD ACs: AC-013.1, AC-013.2, AC-013.3, AC-013.4

- [ ] **TRD-013-TEST** (2h): Unit tests for beads import: happy path mapping (open→backlog, in_progress→backlog, closed→merged), epic type preserved, blocks dep preserved, deduplication via external_id, --dry-run prints without writing, summary count correct. [verifies TRD-013] [satisfies REQ-013] [depends: TRD-013]

- [ ] **TRD-014** (1h): Add `@deprecated` JSDoc tags to all exported symbols in `src/lib/beads-rust.ts`. Run grep audit to verify no non-shim Foreman code references `BeadsRustClient` directly (excluding `dispatcher.ts` coexistence fallback and `beads-rust.ts` itself). Add `eslint-disable-next-line` comment at the one permitted fallback call site in `dispatcher.ts`. [satisfies REQ-015]
  - Validates PRD ACs: AC-015.1, AC-015.2

- [ ] **TRD-014-TEST** (1h): Static analysis test: programmatically grep `src/**/*.ts` for `BeadsRustClient` and assert the only matches are in `beads-rust.ts` and the permitted fallback call in `dispatcher.ts`. Fails the test suite if any other file references it. [verifies TRD-014] [satisfies REQ-015] [depends: TRD-014]

- [ ] **TRD-015** (2h): Update `foreman doctor` command: report task store mode (`"Task store: native (N tasks)"` or `"Task store: beads (fallback)"`); warn if both native store and `.beads/beads.jsonl` exist; emit info (not error) when `br` binary absent. [satisfies REQ-014, REQ-015] [depends: TRD-004, TRD-001]
  - Validates PRD ACs: AC-014.3, AC-015.2

- [ ] **TRD-015-TEST** (1h): Unit tests for `doctor` task store reporting: native mode (N tasks), beads fallback mode, dual-data warning, absent `br` shows info not error. [verifies TRD-015] [satisfies REQ-014, REQ-015] [depends: TRD-015]

- [ ] **TRD-016** (2h): Add `FOREMAN_TASK_STORE` env var override to `NativeTaskStore.hasNativeTasks()` and the dispatcher coexistence check. `native` = force native regardless of table state. `beads` = force beads regardless. Document in CLAUDE.md and env var section. [satisfies REQ-014] [depends: TRD-007]
  - Validates PRD ACs: AC-014.2

- [ ] **TRD-016-TEST** (1h): Unit tests for env var override: `FOREMAN_TASK_STORE=native` with empty table → native path; `FOREMAN_TASK_STORE=beads` with populated table → beads path; unset → normal coexistence logic. [verifies TRD-016] [satisfies REQ-014] [depends: TRD-016]

- [ ] **TRD-017** (2h): TypeScript strict mode audit and coverage gate. Verify `npx tsc --noEmit` passes. Run Vitest coverage for `task-store.ts` (≥80%) and dashboard aggregation path (≥70%). Fix any `any` escapes in new modules. Add coverage thresholds to `vitest.config.ts` for new modules. [satisfies REQ-021]
  - Validates PRD ACs: AC-021.1, AC-021.2

- [ ] **TRD-017-TEST** (1h): Coverage gate test: Vitest coverage run with `--reporter=json`, assert `task-store.ts` branch coverage ≥80%, `project-registry.ts` ≥80%, dashboard aggregation path ≥70%. [verifies TRD-017] [satisfies REQ-021] [depends: TRD-017]

---

## 4. Sprint Planning

### Sprint 1 — Foundation (Gate: schema migration + registry functional, all existing tests pass)

| Task | Hours | Depends On |
|------|-------|-----------|
| TRD-001: ProjectRegistry class | 4h | — |
| TRD-001-TEST | 2h | TRD-001 |
| TRD-002: Schema DDL migration | 3h | — |
| TRD-002-TEST | 2h | TRD-002 |
| TRD-003: `foreman project` CLI | 4h | TRD-001 |
| TRD-003-TEST | 2h | TRD-003 |
| **Sprint 1 Total** | **17h** | |

**Gate:** `foreman project add/list/remove` functional; schema migration runs idempotently; all existing integration tests pass unchanged.

### Sprint 2 — Task Store + CLI (Gate: task CRUD, approval gate, dependency graph end-to-end)

| Task | Hours | Depends On |
|------|-------|-----------|
| TRD-004: NativeTaskStore | 6h | TRD-002 |
| TRD-004-TEST | 3h | TRD-004 |
| TRD-005: Dependency graph | 3h | TRD-004 |
| TRD-005-TEST | 2h | TRD-005 |
| TRD-006: `foreman task` CLI | 5h | TRD-004, TRD-005, TRD-001 |
| TRD-006-TEST | 2h | TRD-006 |
| **Sprint 2 Total** | **21h** | |

**Gate:** `foreman task create/approve/list/show/update/close` functional; approval gate tested end-to-end; dep blocking and unblocking tested.

### Sprint 3 — Dispatcher + Pipeline + Sling (Gate: full pipeline run using native task store)

| Task | Hours | Depends On |
|------|-------|-----------|
| TRD-007: Dispatcher coexistence | 4h | TRD-004 |
| TRD-007-TEST | 2h | TRD-007 |
| TRD-008: Pipeline phase updates | 2h | TRD-004 |
| TRD-008-TEST | 1h | TRD-008 |
| TRD-009: Refinery close | 2h | TRD-004 |
| TRD-009-TEST | 1h | TRD-009 |
| TRD-010: Sling native tasks | 3h | TRD-004, TRD-002 |
| TRD-010-TEST | 1h | TRD-010 |
| **Sprint 3 Total** | **16h** | |

**Gate:** Dispatcher uses native task store for complete pipeline run; phase status visible in `foreman task show`; refinery marks tasks `merged`; sling creates native tasks.

### Sprint 4 — Dashboard + Cross-Project (Gate: dashboard benchmark passes)

| Task | Hours | Depends On |
|------|-------|-----------|
| TRD-011: Dashboard aggregation | 6h | TRD-001, TRD-004 |
| TRD-011-TEST | 2h | TRD-011 |
| TRD-012: `--project` flag | 3h | TRD-001 |
| TRD-012-TEST | 1h | TRD-012 |
| **Sprint 4 Total** | **12h** | |

**Gate:** `foreman dashboard` shows all registered projects; "Needs Human" panel populated; `foreman status --all` functional; dashboard benchmark < 2s for 7 projects.

### Sprint 5 — Migration + Deprecation (Gate: `foreman doctor` reflects native/beads mode correctly)

| Task | Hours | Depends On |
|------|-------|-----------|
| TRD-013: `import --from-beads` | 4h | TRD-004, TRD-002 |
| TRD-013-TEST | 2h | TRD-013 |
| TRD-014: BeadsRustClient deprecation | 1h | — |
| TRD-014-TEST | 1h | TRD-014 |
| TRD-015: doctor native/beads mode | 2h | TRD-004, TRD-001 |
| TRD-015-TEST | 1h | TRD-015 |
| TRD-016: FOREMAN_TASK_STORE env override | 2h | TRD-007 |
| TRD-016-TEST | 1h | TRD-016 |
| TRD-017: TS strict + coverage gate | 2h | — |
| TRD-017-TEST | 1h | TRD-017 |
| **Sprint 5 Total** | **17h** | |

**Gate:** `foreman task import --from-beads` tested on real data; coexistence fallback verified; `foreman doctor` correct; `BeadsRustClient` deprecated with 0 internal usages outside shim.

**Total estimated: ~83h across 5 sprints**

---

## 5. Acceptance Criteria Traceability

| REQ-NNN | Description | Implementation Tasks | Test Tasks |
|---------|-------------|---------------------|-----------|
| REQ-001 | Global Project Registry | TRD-001, TRD-003 | TRD-001-TEST, TRD-003-TEST |
| REQ-002 | Project Listing and Health Status | TRD-001, TRD-003 | TRD-001-TEST, TRD-003-TEST |
| REQ-003 | Task Schema with Workflow-Aware Statuses | TRD-002, TRD-004 | TRD-002-TEST, TRD-004-TEST |
| REQ-004 | Task Dependency Graph | TRD-004, TRD-005 | TRD-004-TEST, TRD-005-TEST |
| REQ-005 | Approval Gate | TRD-004, TRD-006 | TRD-004-TEST, TRD-006-TEST |
| REQ-006 | `foreman task create` | TRD-006 | TRD-006-TEST |
| REQ-007 | `foreman task list`, `show`, `update` | TRD-006 | TRD-006-TEST |
| REQ-008 | `foreman task close` and Manual Status Control | TRD-006 | TRD-006-TEST |
| REQ-009 | Sling Integration — Native Task Creation | TRD-010 | TRD-010-TEST |
| REQ-010 | Cross-Project Dashboard Aggregation | TRD-011 | TRD-011-TEST |
| REQ-011 | "Needs Human" Panel | TRD-011 | TRD-011-TEST |
| REQ-012 | Pipeline Phase Visibility | TRD-008, TRD-011 | TRD-008-TEST, TRD-011-TEST |
| REQ-013 | Beads Import Command | TRD-013 | TRD-013-TEST |
| REQ-014 | Coexistence — Fallback to Beads | TRD-007, TRD-015, TRD-016 | TRD-007-TEST, TRD-015-TEST, TRD-016-TEST |
| REQ-015 | Beads Deprecation Path | TRD-014, TRD-015 | TRD-014-TEST, TRD-015-TEST |
| REQ-016 | `--project` Flag on Dispatch Commands | TRD-012 | TRD-012-TEST |
| REQ-017 | Dispatcher Reads Native Task Store Per-Project | TRD-004, TRD-007, TRD-008 | TRD-004-TEST, TRD-007-TEST, TRD-008-TEST |
| REQ-018 | Refinery Closes Native Tasks Post-Merge | TRD-009 | TRD-009-TEST |
| REQ-019 | Dashboard Refresh Performance | TRD-011 | TRD-011-TEST |
| REQ-020 | Backward Compatibility During Transition | TRD-002, TRD-007 | TRD-002-TEST, TRD-007-TEST |
| REQ-021 | TypeScript Strict Mode and Test Coverage | TRD-017 | TRD-017-TEST |
| REQ-022 | Stale Project Handling | TRD-001, TRD-003, TRD-012 | TRD-001-TEST, TRD-003-TEST, TRD-012-TEST |

**Traceability check: 22 requirements covered, 0 uncovered, 0 orphaned annotations**

---

## 6. Quality Requirements

- **TypeScript strict mode:** No `any` in `task-store.ts`, `project-registry.ts`, new CLI commands (REQ-021)
- **Test coverage:** `task-store.ts` ≥80%, `project-registry.ts` ≥80%, dashboard aggregation path ≥70% (REQ-021)
- **Performance:** Dashboard refresh < 2000ms for 7 projects × 200 tasks × 10 runs (REQ-019)
- **Backward compatibility:** All existing tests pass unchanged throughout all sprints (REQ-020)
- **SQLite safety:** Dashboard reads use `SQLITE_OPEN_READONLY`; dispatch claim uses explicit transactions (REQ-017, REQ-019)
- **Error types:** `DuplicateProjectError`, `ProjectNotFoundError`, `TaskNotFoundError`, `InvalidTransitionError`, `InvalidTaskStatusError`, `CircularDependencyError` — all typed, not string errors
- **Keyboard interaction in dashboard:** `a`, `r`, `Enter` actions — unit-tested via mock terminal where feasible; manual test checklist for full interactive flow

---

## 7. Design Readiness Scorecard

| Dimension | Score (1-5) | Notes |
|-----------|-------------|-------|
| Architecture completeness | 4 | All components, interfaces, data flows defined. Three gaps (WorkerConfig.taskId, atomic claim scope, dashboard write actions) identified and resolved in Section 1. |
| Task coverage | 4 | All 22 REQ-NNN have paired implementation + test tasks. Coverage gate added to TRD-017. |
| Dependency clarity | 5 | Explicit, acyclic. Critical path: TRD-002→TRD-004→{TRD-005, TRD-006, TRD-007, TRD-008, TRD-009, TRD-010, TRD-013}. Max depth: 3. |
| Estimate confidence | 4 | Consistent with codebase patterns. Largest task (TRD-011, 6h) reflects real dashboard complexity. Total 83h ≈ 3-4 sprints as PRD predicted. |
| **Overall** | **4.25** | **PASS** |

---

## 8. Implementation Plan

### 4.1 Sprint 1: Foundation — Registry and Schema

#### Story 1.1: Project Registry

| ID | Task | Est. | Deps | Status |
|----|------|------|------|--------|
| TRD-001 | Create ProjectRegistry class in src/lib/project-registry.ts — add/list/remove/resolve/removeStale, atomic JSON write to ~/.foreman/projects.json, DuplicateProjectError and ProjectNotFoundError typed errors [satisfies REQ-001 REQ-002 REQ-022] | 4h | -- | ( ) |
| TRD-001-TEST | Unit tests for ProjectRegistry: add happy path, missing .foreman/ warning, duplicate error, auto-mkdir, list stale detection, remove active-agents guard, resolve name and path [verifies TRD-001] [satisfies REQ-001 REQ-002 REQ-022] | 2h | TRD-001 | ( ) |
| TRD-003 | foreman project add/list/remove CLI commands in src/cli/commands/project.ts with --name alias, --force, --stale flags; register Commander subcommand group in src/cli/index.ts [satisfies REQ-001 REQ-002 REQ-022] | 4h | TRD-001 | ( ) |
| TRD-003-TEST | Unit tests for project.ts commands with mocked ProjectRegistry [verifies TRD-003] [satisfies REQ-001 REQ-002] | 2h | TRD-003 | ( ) |

#### Story 1.2: Schema Migration

| ID | Task | Est. | Deps | Status |
|----|------|------|------|--------|
| TRD-002 | SQLite DDL migration for tasks and task_dependencies tables with status CHECK constraint, external_id column, and indexes; wired into ForemanStore constructor, idempotent via CREATE TABLE IF NOT EXISTS; exports InvalidTaskStatusError [satisfies REQ-003 REQ-004 REQ-020] | 3h | -- | ( ) |
| TRD-002-TEST | Integration tests for schema migration idempotency on new DB, existing DB, and double-run; InvalidTaskStatusError propagation [verifies TRD-002] [satisfies REQ-003 REQ-020] | 2h | TRD-002 | ( ) |

### 4.2 Sprint 2: Native Task Store and Task CLI

#### Story 2.1: NativeTaskStore Core

| ID | Task | Est. | Deps | Status |
|----|------|------|------|--------|
| TRD-004 | NativeTaskStore class in src/lib/task-store.ts — create/get/list/update/close/approve/claim/updatePhase/updateStatus/hasNativeTasks methods; private transition() state machine via VALID_TRANSITIONS map; TaskNotFoundError, InvalidTransitionError typed errors [satisfies REQ-003 REQ-004 REQ-005 REQ-017] | 6h | TRD-002 | ( ) |
| TRD-004-TEST | Unit tests for NativeTaskStore: CRUD, state machine transitions (valid, invalid, force), approval gate, atomic claim transaction, hasNativeTasks edge cases, updatePhase no-op on null taskId [verifies TRD-004] [satisfies REQ-003 REQ-004 REQ-005 REQ-017] | 3h | TRD-004 | ( ) |
| TRD-005 | Dependency graph management in NativeTaskStore: addDependency/removeDependency/getDependencies/getBlockers/unblockDependents; DFS cycle detection throwing CircularDependencyError before insert [satisfies REQ-004 REQ-021] | 3h | TRD-004 | ( ) |
| TRD-005-TEST | Unit tests for dependency graph: addDependency valid and circular (direct and transitive), removeDependency, getDependencies both directions, unblockDependents single and multi-blocker [verifies TRD-005] [satisfies REQ-004 REQ-021] | 2h | TRD-005 | ( ) |

#### Story 2.2: Task CLI Commands

| ID | Task | Est. | Deps | Status |
|----|------|------|------|--------|
| TRD-006 | foreman task Commander subcommand group in src/cli/commands/task.ts: create (--title required, --description, --type, --priority with word aliases, --project), list (--status, --all, --project), show, update (--force for backward transitions), approve, close (--reason) [satisfies REQ-006 REQ-007 REQ-008] | 5h | TRD-004, TRD-005, TRD-001 | ( ) |
| TRD-006-TEST | Unit tests for task.ts commands with mocked NativeTaskStore: create (required title, priority aliases, invalid type), list filters, show full detail with deps, update valid and --force transitions, approve (ready vs blocked), close (dep re-evaluation) [verifies TRD-006] [satisfies REQ-006 REQ-007 REQ-008] | 2h | TRD-006 | ( ) |

### 4.3 Sprint 3: Dispatcher, Pipeline, and Sling Integration

#### Story 3.1: Dispatcher Coexistence

| ID | Task | Est. | Deps | Status |
|----|------|------|------|--------|
| TRD-007 | Update dispatcher.ts: getReadyTasks() calls hasNativeTasks() for coexistence check; native path uses SELECT WHERE status=ready; beads fallback via BeadsRustClient; atomic claim via NativeTaskStore.claim(); taskId in dispatch result for WorkerConfig; FOREMAN_TASK_STORE env override [satisfies REQ-014 REQ-017 REQ-020] | 4h | TRD-004 | ( ) |
| TRD-007-TEST | Unit tests for dispatcher: native path, beads fallback, FOREMAN_TASK_STORE=native and beads overrides, atomic claim transaction [verifies TRD-007] [satisfies REQ-014 REQ-017] | 2h | TRD-007 | ( ) |
| TRD-016 | FOREMAN_TASK_STORE env var override extracted as reusable helper used by both dispatcher and NativeTaskStore.hasNativeTasks() [satisfies REQ-014] | 2h | TRD-007 | ( ) |
| TRD-016-TEST | Unit tests for env var override: native with empty table, beads with populated table, unset uses coexistence logic [verifies TRD-016] [satisfies REQ-014] | 1h | TRD-016 | ( ) |

#### Story 3.2: Pipeline and Refinery Integration

| ID | Task | Est. | Deps | Status |
|----|------|------|------|--------|
| TRD-008 | Add taskId to WorkerConfig type; update pipeline-executor.ts to call ctx.taskStore?.updatePhase(config.taskId, phaseName) at each phase transition; no-op when taskId null; pass NativeTaskStore as optional taskStore in PipelineContext [satisfies REQ-012 REQ-017] | 2h | TRD-004 | ( ) |
| TRD-008-TEST | Unit tests: phase transition calls updatePhase with correct name; null taskId is a no-op; absent taskStore does not throw [verifies TRD-008] [satisfies REQ-012] | 1h | TRD-008 | ( ) |
| TRD-009 | Update refinery.ts: after successful merge, call taskStore.updateStatus(taskId, merged) and unblockDependents(taskId) in native mode; retain syncBeadStatusAfterMerge() in beads fallback; unresolvable taskId logs debug warning [satisfies REQ-018] | 2h | TRD-004 | ( ) |
| TRD-009-TEST | Unit tests: native close path calls updateStatus and unblockDependents; beads fallback calls syncBeadStatusAfterMerge; unresolvable taskId warns without error [verifies TRD-009] [satisfies REQ-018] | 1h | TRD-009 | ( ) |

#### Story 3.3: Sling Integration

| ID | Task | Est. | Deps | Status |
|----|------|------|------|--------|
| TRD-010 | Update sling.ts: replace br create and BeadsRustClient.create() with NativeTaskStore.create(); auto-run schema migration if tasks table absent with one-time message; tasks enter backlog; add batch-approve shortcut [satisfies REQ-009] | 3h | TRD-004, TRD-002 | ( ) |
| TRD-010-TEST | Unit tests: sling does not call br create; tasks created with status backlog; auto-migration fires when table absent; batch-approve transitions matching tasks to ready [verifies TRD-010] [satisfies REQ-009] | 1h | TRD-010 | ( ) |

### 4.4 Sprint 4: Dashboard and Cross-Project Operations

#### Story 4.1: Cross-Project Dashboard

| ID | Task | Est. | Deps | Status |
|----|------|------|------|--------|
| TRD-011 | Update dashboard.ts: readProjectSnapshot() reads each project DB READONLY via Promise.all(); Needs Human panel shows conflict/failed/stuck/backlog tasks sorted by priority then age; per-project agent panel; 5s refresh loop configurable via --refresh and config.yaml; approve/retry interactive actions via short-lived write connection [satisfies REQ-010 REQ-011 REQ-012 REQ-019] | 6h | TRD-001, TRD-004 | ( ) |
| TRD-011-TEST | Unit tests for readProjectSnapshot (inaccessible DB shows offline indicator, parallel reads); benchmark test in src/cli/__tests__/dashboard-performance.test.ts: 7 in-memory DBs x 200 tasks x 10 runs < 2000ms [verifies TRD-011] [satisfies REQ-010 REQ-011 REQ-019] | 2h | TRD-011 | ( ) |

#### Story 4.2: Cross-Project Dispatch Flags

| ID | Task | Est. | Deps | Status |
|----|------|------|------|--------|
| TRD-012 | Add --project flag to foreman run/reset/retry/status resolving from ProjectRegistry; foreman status --all cross-project table with RUNNING AGENTS, READY TASKS, NEEDS HUMAN, LAST ACTIVITY; stale path descriptive error; path-only with no registry entry prints warning [satisfies REQ-016] | 3h | TRD-001 | ( ) |
| TRD-012-TEST | Unit tests: registered name resolves; unregistered name exits with error; absolute path with no registry entry warns; stale path exits with message; --all output includes all projects [verifies TRD-012] [satisfies REQ-016 REQ-022] | 1h | TRD-012 | ( ) |

### 4.5 Sprint 5: Migration, Deprecation, and Quality Gates

#### Story 5.1: Beads Migration

| ID | Task | Est. | Deps | Status |
|----|------|------|------|--------|
| TRD-013 | foreman task import --from-beads [--dry-run] in task.ts: read .beads/beads.jsonl, map open→backlog, in_progress→backlog, closed→merged; preserve epic type and blocks deps; skip by external_id; --dry-run prints first 5 mappings; prints summary count [satisfies REQ-013] | 4h | TRD-004, TRD-002 | ( ) |
| TRD-013-TEST | Unit tests: field mapping (all status values), epic type preserved, blocks dep preserved, deduplication via external_id, dry-run does not write, summary count correct [verifies TRD-013] [satisfies REQ-013] | 2h | TRD-013 | ( ) |

#### Story 5.2: Deprecation and Doctor

| ID | Task | Est. | Deps | Status |
|----|------|------|------|--------|
| TRD-014 | Add @deprecated JSDoc to all exports in src/lib/beads-rust.ts; grep audit confirms zero non-shim usages; add eslint-disable comment at single permitted fallback call site in dispatcher.ts [satisfies REQ-015] | 1h | -- | ( ) |
| TRD-014-TEST | Static analysis test: programmatically grep src/ for BeadsRustClient and assert only beads-rust.ts and dispatcher.ts fallback match [verifies TRD-014] [satisfies REQ-015] | 1h | TRD-014 | ( ) |
| TRD-015 | Update foreman doctor: report native (N tasks) or beads (fallback) mode; warn on dual-data coexistence; absent br is info not error [satisfies REQ-014 REQ-015] | 2h | TRD-004, TRD-001 | ( ) |
| TRD-015-TEST | Unit tests for doctor: native mode, beads fallback, dual-data warning, absent br info message [verifies TRD-015] [satisfies REQ-014 REQ-015] | 1h | TRD-015 | ( ) |

#### Story 5.3: TypeScript and Coverage Gate

| ID | Task | Est. | Deps | Status |
|----|------|------|------|--------|
| TRD-017 | TypeScript strict mode audit: npx tsc --noEmit passes; zero any escapes in task-store.ts, project-registry.ts, new CLI commands; add Vitest coverage thresholds: task-store.ts >=80%, project-registry.ts >=80%, dashboard aggregation >=70% [satisfies REQ-021] | 2h | -- | ( ) |
| TRD-017-TEST | Coverage gate test: Vitest coverage run asserts all thresholds met [verifies TRD-017] [satisfies REQ-021] | 1h | TRD-017 | ( ) |
