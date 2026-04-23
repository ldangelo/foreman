# TRD-2026-011: Multi-Project Orchestrator v2 — tRPC Daemon Architecture

**Document ID:** TRD-2026-011
**Version:** 1.1.0
**Status:** Draft
**Date:** 2026-04-21
**PRD Reference:** PRD-2026-010 v2.0
**Design Readiness Score:** 4.0 (PASS)

---

## Architecture Decision Record

### ADR-001: API-First Daemon Architecture (replaces Phased Migration)

**Chosen approach:** tRPC daemon — CLI commands are thin wrappers over a tRPC client that connects to a persistent Foreman daemon. The daemon owns the Postgres connection pool. No `DbAdapter` interface, no `SqliteAdapter`.

**Rationale:** The v1.0 adapter-pattern approach (extract `DbAdapter` interface, build `SqliteAdapter`, migrate to `PostgresAdapter`) was rejected after adversarial review. Problems: (1) 50+ method `DbAdapter` interface is a maintenance burden; (2) dual-adapter path requires 8h SqliteAdapter extraction on critical path; (3) SQLite backward compat adds complexity with no benefit in v1 (fresh installs don't need SQLite). The tRPC daemon approach eliminates the adapter layer entirely: the daemon speaks directly to Postgres, the CLI speaks only to the daemon's tRPC procedures.

**Alternatives considered:**
- **Adapter pattern (v1.0):** `DbAdapter` interface → `SqliteAdapter` → `PostgresAdapter`. Phased migration. Maintains backward compat for SQLite users. High interface maintenance cost.
- **Big-bang Postgres replacement (rejected):** Replace `ForemanStore` with direct Postgres calls in one pass. Cleanest but highest risk — 40+ consumer files must be updated simultaneously.

**Data flows:**
```
CLI commands → TrpcClient → ForemanDaemon (Unix socket) → PostgresAdapter → PoolManager → Postgres
```
The daemon is a long-lived Node.js HTTP server. It starts via `foreman daemon start` and stops via `foreman daemon stop`.

---

## 1. System Architecture

### 1.1 Component Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         CLI Layer                                 │
│   foreman project | run | inbox | status | board | dashboard     │
│                    foreman daemon | webhook | doctor               │
│   Each command: creates TrpcClient, calls tRPC procedure           │
└──────────────────────────────┬────────────────────────────────┘
                               │
                    ~/.foreman/daemon.sock  (mode 0600)
                    or http://localhost:3847 (fallback)
                               │
┌──────────────────────────────▼────────────────────────────────┐
│                    ForemanDaemon (src/daemon/)                    │
│   - Fastify HTTP server                                         │
│   - tRPC router (all domain procedures)                          │
│   - PostgresAdapter (database access)                            │
│   - PoolManager singleton (pg-pool)                             │
│   - DaemonManager (lifecycle: start/stop/status)                 │
└─────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│                    PostgresAdapter (src/lib/db/)                  │
│   Direct Postgres queries. No SQLite. No adapter interface.       │
│   Methods grouped by domain: projects, tasks, runs, events.       │
└──────────────────────────────────────────────────────────────────┘
                                               │
                                  ┌────────────▼────────────────┐
                                  │       PoolManager              │
                                  │  Singleton pg-pool (size=20)    │
                                  └───────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│                     Supporting Services                            │
│  ProjectRegistry ──► ~/.foreman/projects.json (source of truth)  │
│  GhCli ────────────► gh repo clone | gh api | gh auth status      │
│  WorktreeManager ─► ~/.foreman/worktrees/<project-id>/            │
│  MigrationRunner ──► node-pg-migrate, schema_migrations table    │
└──────────────────────────────────────────────────────────────────┘
```

### 1.2 Component Responsibilities

| Component | Responsibility | Location |
|-----------|---------------|----------|
| `ForemanDaemon` | Node.js HTTP server + tRPC router. Long-lived process. | `src/daemon/index.ts` |
| `TrpcRouter` | Monolithic tRPC router with all domain procedures (projects, tasks, runs, events, messages). | `src/daemon/router.ts` |
| `TrpcClient` | CLI-side tRPC client. Connects to daemon via Unix socket or localhost. | `src/lib/trpc-client.ts` |
| `DaemonManager` | Manages daemon lifecycle: start, stop, status, PID file. | `src/lib/daemon-manager.ts` |
| `PostgresAdapter` | All database operations. Direct Postgres queries via PoolManager. | `src/lib/db/postgres-adapter.ts` |
| `PoolManager` | Singleton Postgres connection pool. Initialized once in daemon. | `src/lib/db/pool-manager.ts` |
| `MigrationRunner` | Schema migrations via node-pg-migrate. Runs on daemon startup. | `src/lib/db/migrations/` |
| `ProjectRegistry` | Project metadata: JSON file + Postgres mirror. JSON is source of truth. | `src/lib/project-registry.ts` |
| `GhCli` | Thin wrapper around `gh` CLI commands. | `src/lib/gh-cli.ts` |
| `WorktreeManager` | Worktree lifecycle at `~/.foreman/worktrees/<project-id>/`. | `src/lib/worktree-manager.ts` |

### 1.3 Data Flow: Project Addition

```
foreman project add <github-url>
  │
  ├─► TrpcClient.project.add({ url })  → ForemanDaemon
  │
  ├─► GhCli.authStatus()              → verify gh is authenticated
  │
  ├─► GhCli.repoClone(url, path)      → gh repo clone <url> ~/.foreman/projects/<id>/
  │
  ├─► GhCli.api("/repos/{owner}/{repo}") → fetch default branch, visibility
  │
  ├─► PostgresAdapter.createProject(metadata) → INSERT INTO projects
  │
  └─► console.log("Project '<id>' added at <path>")
```

### 1.4 Data Flow: Task Dispatch

```
foreman run --project <name>
  │
  ├─► ProjectRegistry.resolve(name)   → look up project_id + clone_path
  │
  ├─► TrpcClient.tasks.claim({ projectId }) → ForemanDaemon
  │    └─► PostgresAdapter.claimTask(projectId)
  │         → SELECT ... FOR UPDATE WHERE status='ready'
  │         → UPDATE status='in-progress', set run_id
  │         → Transaction: atomic
  │
  ├─► TrpcClient.runs.create({ projectId, ... })
  │
  ├─► WorktreeManager.create(projectId, seedId)
  │    → git worktree add ~/.foreman/worktrees/<project-id>/<seed-id> <branch>
  │
  ├─► AgentWorker.spawn(runId, worktreePath)
  │
  └─► AgentWorker.run() → pipeline phases → finalize → autoMerge
```

### 1.5 Data Flow: Cross-Project Dashboard

```
foreman dashboard
  │
  ├─► TrpcClient.projects.list() → PostgresAdapter.listProjects()
  │
  ├─► For each project_id:
  │    ├─► TrpcClient.runs.listActive({ projectId })
  │    ├─► TrpcClient.tasks.listNeedsHuman({ projectId })
  │    │    → SELECT ... WHERE status IN ('conflict','failed','stuck','backlog')
  │    ├─► TrpcClient.tasks.countByStatus({ projectId })
  │    └─► TrpcClient.metrics.getAggregates({ projectId })
  │
  └─► Render TTY dashboard with Needs Human panel + per-project panels
```

### 1.6 Technology Choices

| Concern | Choice | Rationale |
|---------|--------|-----------|
| API protocol | tRPC | TypeScript-native, end-to-end type safety without code generation |
| HTTP server | Fastify | Required by tRPC; fast, low overhead |
| Transport | Unix socket (primary) + localhost HTTP (fallback) | Secure local IPC; no network exposure |
| Database | Postgres (pg + pg-pool) | Required by PRD; concurrent writes + row locking |
| Migrations | node-pg-migrate | TypeScript, transactional, easy rollback |
| GitHub integration | gh CLI (exec) | Required by PRD; OS keychain auth |
| Config | YAML (js-yaml) | Existing pattern in codebase |
| Connection pool | pg-pool | Required by Postgres adapter |
| JSON registry | File system + in-memory cache | Source of truth for critical paths |

---

## 2. Master Task List

### Sprint 0: API Foundation (Daemon Skeleton + Projects Domain End-to-End)

Goal: `foreman daemon start` → `foreman project add` → `foreman project list` → `foreman project remove` all work via tRPC. Daemon manages pool + migrations. One domain only (projects).

| TRD-NNN | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-001 | Install `fastify`, `@trpc/server`, `@trpc/client`, `ws`, `pg`, `pg-pool` dependencies | 1h | REQ-004 | AC-004.1 |
| TRD-002 | Create `PoolManager` singleton: initialize pg-pool, expose query/execute helpers, health check | 3h | REQ-004 | AC-004.3 |
| TRD-003 | Create `PostgresAdapter` skeleton: all method stubs throw "not implemented" | 2h | REQ-004 | — |
| TRD-004 | Create `TrpcRouter` with projects router stub: `list`, `add`, `remove` procedures | 4h | REQ-004 | AC-004.4 |
| TRD-005 | Create `ForemanDaemon` HTTP server with Fastify + tRPC middleware, listen on Unix socket | 4h | REQ-004 | AC-004.2 |
| TRD-006 | Create `DaemonManager`: PID file, start/stop/status commands, socket cleanup | 3h | REQ-004 | — |
| TRD-007 | Add `foreman daemon start` and `foreman daemon stop` CLI commands | 2h | REQ-004 | AC-004.1 |
| TRD-008 | Create `TrpcClient`: connect to daemon via Unix socket transport | 3h | REQ-004 | AC-004.2 |
| TRD-009 | Wire CLI project commands to `TrpcClient`: `foreman project list/add/remove` | 3h | REQ-002 | AC-002.1, AC-002.2 |
| TRD-010 | Create Postgres schema migration: `projects` table only | 4h | REQ-005 | AC-005.1 |
| TRD-011 | Implement `PostgresAdapter.createProject()`, `.listProjects()`, `.removeProject()` | 4h | REQ-002 | AC-002.1, AC-002.2 |
| TRD-012 | End-to-end test: `foreman daemon start` → `foreman project add <url>` → daemon → Postgres | 4h | REQ-001, REQ-004 | AC-001.1, AC-004.1 |

---

### Sprint 1: Projects Domain Complete + gh CLI

| TRD-NNN | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-013 | Implement `GhCli` class: `gh auth status`, `gh repo clone`, `gh api` | 3h | REQ-001, REQ-025 | AC-001.1, AC-025.1 |
| TRD-014 | Add `gh` availability check: exit with clear error if not installed | 1h | REQ-001, REQ-025 | AC-001.1 |
| TRD-015 | Implement `foreman project add <github-url>` via tRPC | 4h | REQ-001 | AC-001.1–AC-001.4 |
| TRD-016 | Implement project ID generation: `<normalized-name>-<hex5>` | 2h | REQ-001 | AC-001.1 |
| TRD-017 | Create `~/.foreman/projects/` directory on first project add | 1h | REQ-008 | AC-008.1 |
| TRD-018 | Implement `gh repo clone` via GhCli for initial clone | 2h | REQ-001, REQ-008 | AC-001.1, AC-008.2 |
| TRD-019 | Implement `GhCli.api()` for fetching repo metadata (default branch, visibility) | 2h | REQ-001 | AC-025.2 |
| TRD-020 | Create `ProjectRegistry`: dual-write JSON + Postgres, JSON as source of truth | 4h | REQ-001, REQ-002 | AC-002.1 |
| TRD-021 | Implement `foreman project sync` via tRPC | 2h | REQ-002 | AC-002.3 |
| TRD-022 | Implement `foreman project list` via tRPC | 2h | REQ-002 | AC-002.1 |
| TRD-023 | Implement `foreman project remove` with active-run guard | 2h | REQ-002 | AC-002.2 |
| TRD-024 | Write gh-cli integration tests (mock gh commands) | 3h | REQ-001, REQ-025 | AC-001.1, AC-025.1 |

---

### Sprint 2: Tasks Domain

| TRD-NNN | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-025 | Extend PostgresAdapter: add tasks table migration | 3h | REQ-005, REQ-006 | AC-005.1, AC-006.1 |
| TRD-026 | Implement tRPC tasks procedures: `list`, `get`, `create`, `update`, `delete` | 4h | REQ-006 | AC-006.1, AC-006.3 |
| TRD-027 | Implement `claimTask` with `SELECT ... FOR UPDATE` row locking | 3h | REQ-007 | AC-007.1, AC-007.2, AC-007.3 |
| TRD-028 | Implement `approveTask`, `resetTask`, `retryTask` procedures | 3h | REQ-016 | AC-016.3 |
| TRD-029 | Wire CLI task commands to TrpcClient: `foreman inbox`, `foreman status`, `foreman board` | 4h | REQ-011, REQ-012, REQ-013 | AC-011.1, AC-012.1, AC-013.1 |
| TRD-030 | Add `projectId` parameter to all tRPC task procedures; reject calls without it | 2h | REQ-006 | AC-006.3 |
| TRD-031 | Write task procedure integration tests | 4h | REQ-007 | AC-007.1 |

---

### Sprint 3: Runs, Events, Messages

| TRD-NNN | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-032 | Extend PostgresAdapter: runs, events, messages table migrations | 4h | REQ-005 | AC-005.1, AC-006.1 |
| TRD-033 | Implement tRPC runs procedures: `create`, `list`, `listActive`, `updateStatus`, `finalize` | 4h | REQ-004 | AC-004.3 |
| TRD-034 | Implement tRPC events procedures: `log`, `listByRun` | 2h | REQ-004 | — |
| TRD-035 | Implement tRPC messages procedures: `send`, `list`, `markRead` | 2h | REQ-011 | AC-011.1 |
| TRD-036 | Implement `WorktreeManager`: `~/.foreman/worktrees/<project-id>/` hierarchy | 3h | REQ-009 | AC-009.1, AC-009.2 |
| TRD-037 | Update dispatcher: create worktrees at correct path | 4h | REQ-009 | AC-009.1, AC-009.2 |
| TRD-038 | Implement `foreman worktree list` and `foreman worktree clean` | 3h | REQ-009 | AC-009.3, AC-009.4 |
| TRD-039 | Write runs/events/messages integration tests | 4h | REQ-004 | AC-004.3 |

---

### Sprint 4: CLI --project Flag

| TRD-NNN | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-040 | Add `--project` flag to all relevant CLI commands | 4h | REQ-010 | AC-010.1, AC-010.2, AC-010.3 |
| TRD-041 | Implement multi-project mode detection: 2+ projects in registry | 2h | REQ-014 | AC-014.1, AC-014.3 |
| TRD-042 | Make `--project` required in multi-project mode; error message | 1h | REQ-014 | AC-014.1 |
| TRD-043 | Update `foreman inbox --project` and `--all` | 2h | REQ-011 | AC-011.1, AC-011.2, AC-011.3 |
| TRD-044 | Update `foreman status --project` and `--all` | 2h | REQ-012 | AC-012.1, AC-012.2 |
| TRD-045 | Update `foreman board --project` and `--all` | 2h | REQ-013 | AC-013.1, AC-013.2 |
| TRD-046 | Update `foreman run --project` dispatch | 3h | REQ-014 | AC-014.2, AC-014.4 |
| TRD-047 | Update `foreman reset --project`, `foreman retry --project` | 2h | REQ-010 | AC-010.1 |
| TRD-048 | Write CLI project-awareness integration tests | 4h | REQ-010, REQ-014 | AC-010.1, AC-014.1, AC-014.3 |

---

### Sprint 5: Dashboard

| TRD-NNN | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-049 | Create dashboard renderer: TTY layout with project selector, panels | 6h | REQ-015 | AC-015.1, AC-015.2 |
| TRD-050 | Implement cross-project aggregate queries via tRPC | 4h | REQ-015 | AC-015.1, AC-015.4 |
| TRD-051 | Implement "Needs Human" triage panel | 3h | REQ-016 | AC-016.1, AC-016.2, AC-016.3 |
| TRD-052 | Implement aggregate metrics panel | 2h | REQ-017 | AC-017.1, AC-017.2 |
| TRD-053 | Add `--refresh <seconds>` flag to dashboard | 1h | REQ-015 | AC-015.3 |
| TRD-054 | Add keyboard navigation: a/r/Enter in Needs Human panel | 2h | REQ-016 | AC-016.3 |
| TRD-055 | Handle project query failures gracefully (per-project error display) | 2h | REQ-015 | AC-015.4 |
| TRD-056 | Write dashboard integration tests | 4h | REQ-015, REQ-016, REQ-017 | AC-015.4, AC-016.1 |

---

### Sprint 6: Beads Data Import

| TRD-NNN | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-057 | Implement `foreman task import --from-beads --project <name>` | 4h | REQ-018 | AC-018.1, AC-018.2, AC-018.3 |
| TRD-058 | Implement beads status → native task status mapping | 2h | REQ-018 | AC-018.2 |
| TRD-059 | Implement beads dependency → task_dependencies mapping | 3h | REQ-018 | AC-018.2 |
| TRD-060 | Write beads import integration tests | 3h | REQ-018 | AC-018.3 |

---

### Sprint 7: Webhook (Deferred — REQ-003)

| TRD-NNN | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-061 | Create webhook HTTP server: `foreman webhook --port 9000` | 4h | REQ-003 | AC-003.1 |
| TRD-062 | Implement HMAC-SHA256 signature verification | 2h | REQ-003 | AC-003.1 |
| TRD-063 | Handle GitHub push events: auto-rebase active worktrees | 4h | REQ-003 | AC-003.2 |
| TRD-064 | Handle GitHub PR merge events: transition task to merged | 3h | REQ-003 | AC-003.3 |
| TRD-065 | Write webhook integration tests | 3h | REQ-003 | AC-003.1, AC-003.2, AC-003.3 |

---

### Sprint 8: Polish and Non-Functional

| TRD-NNN | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-066 | Add project_id logging to all cross-project operations | 2h | REQ-022 | AC-022.1 |
| TRD-067 | Update `foreman doctor`: check daemon health, Postgres connectivity, clone health, gh auth | 2h | REQ-022 | AC-022.2 |
| TRD-068 | Implement graceful degradation: agent continues on Postgres disconnect, resumes on reconnect | 4h | REQ-023 | AC-023.2 |
| TRD-069 | Performance test: 20 projects × 5 agents = 100 concurrent operations | 4h | REQ-021 | AC-021.1, AC-021.2 |
| TRD-070 | Pool size warning: doctor warns at 80% capacity | 1h | REQ-026 | AC-026.2 |

---

## 3. Test Tasks

For every user-facing implementation task, a corresponding TEST task is generated:

| Test Task | Verifies | Depends |
|-----------|----------|---------|
| TRD-001-TEST | fastify + tRPC dependencies installed, build passes | TRD-001 |
| TRD-002-TEST | PoolManager singleton, pool.query works | TRD-002 |
| TRD-003-TEST | PostgresAdapter throws "not implemented" on all methods | TRD-003 |
| TRD-004-TEST | TrpcRouter exposes projects.list/add/remove procedures | TRD-004 |
| TRD-005-TEST | ForemanDaemon starts, binds to Unix socket, responds to health check | TRD-005 |
| TRD-006-TEST | DaemonManager: start/stop/status/pidfile lifecycle | TRD-006 |
| TRD-007-TEST | `foreman daemon start` → daemon running; `stop` → daemon stopped | TRD-007 |
| TRD-008-TEST | TrpcClient connects via Unix socket, calls procedure | TRD-008 |
| TRD-009-TEST | CLI project commands route through TrpcClient to daemon | TRD-009 |
| TRD-010-TEST | Migration creates projects table, applied in schema_migrations | TRD-010 |
| TRD-011-TEST | createProject/listProjects/removeProject CRUD round-trip via tRPC | TRD-011 |
| TRD-012-TEST | End-to-end: daemon start → project add → project list → project remove | TRD-012 |
| TRD-013-TEST | GhCli.authStatus() returns true/false | TRD-013 |
| TRD-014-TEST | Clear error when gh not installed | TRD-014 |
| TRD-015-TEST | `foreman project add` creates clone + registry entry | TRD-015 |
| TRD-016-TEST | Project ID generation produces `<name>-<hex5>` | TRD-016 |
| TRD-017-TEST | Creates `~/.foreman/projects/` on first add | TRD-017 |
| TRD-018-TEST | gh repo clone called with correct arguments | TRD-018 |
| TRD-019-TEST | gh api returns default branch + visibility | TRD-019 |
| TRD-020-TEST | ProjectRegistry dual-writes JSON + Postgres | TRD-020 |
| TRD-021-TEST | `foreman project sync` updates last_sync | TRD-021 |
| TRD-022-TEST | `foreman project list` shows all projects | TRD-022 |
| TRD-023-TEST | `foreman project remove` guards active runs | TRD-023 |
| TRD-024-TEST | GhCli commands work (mock gh) | TRD-024 |
| TRD-025-TEST | Tasks table migration creates correct schema with project_id FK | TRD-025 |
| TRD-026-TEST | tasks CRUD via tRPC procedures | TRD-026 |
| TRD-027-TEST | Concurrent claim on same task: one wins, one gets null | TRD-027 |
| TRD-028-TEST | approveTask/resetTask/retryTask dispatch correctly | TRD-028 |
| TRD-029-TEST | `foreman inbox/status/board` via tRPC | TRD-029 |
| TRD-030-TEST | Missing projectId raises tRPC error on all task procedures | TRD-030 |
| TRD-031-TEST | claimTask locking + transaction atomicity | TRD-031 |
| TRD-032-TEST | runs/events/messages table migrations | TRD-032 |
| TRD-033-TEST | runs CRUD via tRPC procedures | TRD-033 |
| TRD-034-TEST | events logging via tRPC | TRD-034 |
| TRD-035-TEST | messages CRUD via tRPC | TRD-035 |
| TRD-036-TEST | WorktreeManager creates worktrees at correct path | TRD-036 |
| TRD-037-TEST | Dispatcher creates worktrees in ~/.foreman/worktrees/ | TRD-037 |
| TRD-038-TEST | `foreman worktree list/clean` | TRD-038 |
| TRD-039-TEST | runs/events/messages integration with real Postgres | TRD-039 |
| TRD-040-TEST | `--project` flag accepted by all commands | TRD-040 |
| TRD-041-TEST | Multi-project mode detected at 2+ projects | TRD-041 |
| TRD-042-TEST | `--project` required error in multi-project mode | TRD-042 |
| TRD-043-TEST | `foreman inbox --project` and `--all` | TRD-043 |
| TRD-044-TEST | `foreman status --project` and `--all` | TRD-044 |
| TRD-045-TEST | `foreman board --project` and `--all` | TRD-045 |
| TRD-046-TEST | `foreman run --project` dispatches from correct project | TRD-046 |
| TRD-047-TEST | `foreman reset/retry --project` | TRD-047 |
| TRD-048-TEST | Project-aware CLI: end-to-end scenario | TRD-048 |
| TRD-049-TEST | Dashboard renders TTY layout correctly | TRD-049 |
| TRD-050-TEST | Dashboard aggregates cross-project data via tRPC | TRD-050 |
| TRD-051-TEST | Needs Human panel shows correct tasks | TRD-051 |
| TRD-052-TEST | Aggregate metrics panel shows correct totals | TRD-052 |
| TRD-053-TEST | Dashboard refresh at configured interval | TRD-053 |
| TRD-054-TEST | Keyboard nav: a/r/Enter actions dispatch correctly | TRD-054 |
| TRD-055-TEST | Project failure shows [error], doesn't crash dashboard | TRD-055 |
| TRD-056-TEST | Dashboard with real daemon + Postgres (integration) | TRD-056 |
| TRD-057-TEST | Beads import creates native tasks in Postgres | TRD-057 |
| TRD-058-TEST | Beads status → native task status mapping | TRD-058 |
| TRD-059-TEST | Beads dependency → task_dependencies mapping | TRD-059 |
| TRD-060-TEST | Beads import dry-run shows correct preview | TRD-060 |
| TRD-061-TEST | Webhook server starts, receives requests | TRD-061 |
| TRD-062-TEST | Invalid HMAC signatures rejected | TRD-062 |
| TRD-063-TEST | Push event triggers worktree rebase | TRD-063 |
| TRD-064-TEST | PR merge event transitions task to merged | TRD-064 |
| TRD-065-TEST | Webhook end-to-end with mock GitHub events | TRD-065 |
| TRD-066-TEST | project_id in all cross-project log lines | TRD-066 |
| TRD-067-TEST | doctor checks: daemon + Postgres + clones + gh auth | TRD-067 |
| TRD-068-TEST | Agent continues when Postgres disconnects, resumes on reconnect | TRD-068 |
| TRD-069-TEST | 100 concurrent operations < 200ms p95 | TRD-069 |
| TRD-070-TEST | doctor warns at 80% pool capacity | TRD-070 |

**Total implementation tasks:** 70
**Total test tasks:** 70
**Total tasks:** 140

---

## 4. Sprint Planning

### Sprint 0: API Foundation (14 days, 33h)
- TRD-001 through TRD-012
- Goal: Daemon starts, connects to Postgres, serves projects CRUD via tRPC. End-to-end: `foreman daemon start` → `foreman project add <url>` → Postgres.
- **Critical path gate:** `foreman daemon start` → `foreman project add <url>` → `foreman project list` all work. `foreman daemon stop` terminates cleanly.

### Sprint 1: Projects Domain + GitHub Integration (16 days, 26h)
- TRD-013 through TRD-024
- Goal: `foreman project add <url>` works end-to-end with gh CLI cloning. Projects registered and cloned.
- **Critical path gate:** `foreman project add` → `foreman project list` → `foreman project remove` all work via tRPC + daemon + Postgres.

### Sprint 2: Tasks Domain (16 days, 22h)
- TRD-025 through TRD-031
- Goal: All task CRUD operations available via tRPC procedures. Row locking for task claiming.
- **Critical path gate:** `claimTask` concurrent test passes (one winner, one null).

### Sprint 3: Runs, Events, Messages (18 days, 22h)
- TRD-032 through TRD-039
- Goal: Runs/events/messages via tRPC. Worktrees created at correct path.
- **Critical path gate:** `foreman run --project <name>` creates worktree at `~/.foreman/worktrees/<project-id>/<seed-id>`.

### Sprint 4: Project-Aware CLI (12 days, 16h)
- TRD-040 through TRD-048
- Goal: All commands accept `--project` flag. Multi-project mode detection works.
- **Critical path gate:** `foreman run --project <name>` dispatches from correct project. Without `--project` in multi-project mode: clear error.

### Sprint 5: Dashboard (16 days, 20h)
- TRD-049 through TRD-056
- Goal: `foreman dashboard` renders cross-project view with Needs Human panel.
- **Critical path gate:** Dashboard shows all registered projects, keyboard nav works.

### Sprint 6: Beads Data Import (8 days, 12h)
- TRD-057 through TRD-060
- Goal: Existing beads data imported from project clone directory into Postgres.
- **Critical path gate:** Beads import dry-run shows correct preview; write produces correct native tasks.

### Sprint 7: Webhook (11 days, 16h)
- TRD-061 through TRD-065
- Goal: `foreman webhook --port 9000` receives and processes GitHub events.
- Deferred if timeline pressure — REQ-003 is "Could" priority.

### Sprint 8: Polish (8 days, 14h)
- TRD-066 through TRD-070
- Goal: doctor updated, graceful degradation working, performance validated.

---

## 5. Acceptance Criteria Traceability

| REQ-NNN | Description | Implementation Tasks | Test Tasks |
|---------|-------------|---------------------|------------|
| REQ-001 | GitHub-URL Project Addition | TRD-013, TRD-015, TRD-016, TRD-018, TRD-019 | TRD-013-TEST, TRD-015-TEST, TRD-016-TEST, TRD-018-TEST, TRD-019-TEST |
| REQ-002 | Project Listing and Health | TRD-009, TRD-011, TRD-020, TRD-022, TRD-023 | TRD-009-TEST, TRD-011-TEST, TRD-020-TEST, TRD-022-TEST, TRD-023-TEST |
| REQ-003 | GitHub Webhook Integration | TRD-061, TRD-062, TRD-063, TRD-064 | TRD-061-TEST, TRD-062-TEST, TRD-063-TEST, TRD-064-TEST |
| REQ-004 | Daemon Startup + tRPC + Pool | TRD-001, TRD-002, TRD-005, TRD-007, TRD-008 | TRD-001-TEST, TRD-002-TEST, TRD-005-TEST, TRD-007-TEST, TRD-008-TEST |
| REQ-005 | Postgres Schema Migrations | TRD-010, TRD-025, TRD-032 | TRD-010-TEST, TRD-025-TEST, TRD-032-TEST |
| REQ-006 | Per-Project Data Isolation | TRD-025, TRD-026, TRD-030 | TRD-025-TEST, TRD-026-TEST, TRD-030-TEST |
| REQ-007 | DB-Level Locking | TRD-027, TRD-031 | TRD-027-TEST, TRD-031-TEST |
| REQ-008 | Project Clone Storage | TRD-017, TRD-018 | TRD-017-TEST, TRD-018-TEST |
| REQ-009 | Worktree Lifecycle | TRD-036, TRD-037, TRD-038 | TRD-036-TEST, TRD-037-TEST, TRD-038-TEST |
| REQ-010 | `--project` Flag on All Commands | TRD-040, TRD-047 | TRD-040-TEST, TRD-047-TEST |
| REQ-011 | Project-Aware `foreman inbox` | TRD-029, TRD-043 | TRD-029-TEST, TRD-043-TEST |
| REQ-012 | Project-Aware `foreman status` | TRD-029, TRD-044 | TRD-029-TEST, TRD-044-TEST |
| REQ-013 | Project-Aware `foreman board` | TRD-029, TRD-045 | TRD-029-TEST, TRD-045-TEST |
| REQ-014 | `foreman run` in Multi-Project Mode | TRD-041, TRD-042, TRD-046 | TRD-041-TEST, TRD-042-TEST, TRD-046-TEST |
| REQ-015 | Cross-Project Dashboard | TRD-049, TRD-050, TRD-055 | TRD-049-TEST, TRD-050-TEST, TRD-055-TEST |
| REQ-016 | "Needs Human" Triage Panel | TRD-051, TRD-054 | TRD-051-TEST, TRD-054-TEST |
| REQ-017 | Aggregate Metrics Panel | TRD-052 | TRD-052-TEST |
| REQ-018 | Beads Data Import | TRD-057, TRD-058, TRD-059 | TRD-057-TEST, TRD-058-TEST, TRD-059-TEST |
| REQ-021 | Postgres Performance | TRD-069 | TRD-069-TEST |
| REQ-022 | Operational Observability | TRD-066, TRD-067 | TRD-066-TEST, TRD-067-TEST |
| REQ-023 | Graceful Degradation | TRD-068 | TRD-068-TEST |
| REQ-024 | Migration-Free Onboarding | TRD-010, TRD-012 | TRD-010-TEST, TRD-012-TEST |
| REQ-025 | GitHub Credential Management | TRD-013, TRD-014 | TRD-013-TEST, TRD-014-TEST |
| REQ-026 | Scalability Ceiling | TRD-070 | TRD-070-TEST |

**Traceability check: 24/24 requirements covered. 0 orphaned [satisfies] annotations.**

---

## 6. Design Readiness Gate

| Dimension | Score | Notes |
|-----------|-------|-------|
| Architecture completeness | 4/5 | All components defined: daemon, tRPC router, PostgresAdapter, PoolManager, TrpcClient, DaemonManager. No adapter interface. Note: monolithic tRPC router (all domains in one) is appropriate for v1 single-operator use. |
| Task coverage | 5/5 | Every REQ has implementation + test tasks. 100% coverage. 0 orphaned annotations. |
| Dependency clarity | 4/5 | Clear sprint ordering. Sprint 0 gate: daemon + projects domain. TRD-001–TRD-012 must all pass before proceeding to Sprint 1. |
| Estimate confidence | 3/5 | Implementation estimates 1–6h. Webhook (Sprint 7) optimistic. Daemon lifecycle management (TRD-005, TRD-006) may slip — Unix socket permissions, PID file races. |
| **Overall** | **4.0** | **PASS — proceed to /ensemble:implement-trd-beads** |

**Design concerns to monitor:**
1. **TRD-005 (ForemanDaemon HTTP server):** Unix socket permissions (mode 0600), socket file cleanup on crash, fallback to localhost HTTP. Test on both macOS and Linux.
2. **TRD-006 (DaemonManager):** PID file races, daemon already running detection, graceful SIGTERM vs hard kill.
3. **TRD-027 (FOR UPDATE locking):** Must be validated with concurrent test. Race condition bugs are hard to reproduce.
4. **TRD-012 (End-to-end Sprint 0 test):** Critical gate — if this fails, Sprint 1 is blocked. Write the test first (TDD).

---

## 7. Implementation Readiness

**Recommended startup:** Sprint 0 begins with TRD-001 (dependencies) → TRD-002 (PoolManager) → TRD-003 (PostgresAdapter skeleton) → TRD-005 (ForemanDaemon) → TRD-008 (TrpcClient). The daemon must boot before any CRUD work begins.

**Sprint 0 test-first sequence:**
1. Write TRD-012-TEST first (end-to-end daemon → project add → project list)
2. Implement minimum daemon to make the test pass
3. Add projects CRUD one procedure at a time

**Next recommended step:**
```
/ensemble:implement-trd-beads docs/TRD/TRD-2026-011-multi-project-orchestrator.md
```

All tables include `project_id` as a required column. All queries in task-context include `WHERE project_id = $1`. The tRPC procedures enforce project scope at the procedure argument level — the procedure signature includes `projectId: string` as a required input, making it impossible to issue a cross-project query without explicitly providing a project ID.

---

## Appendix: Component File Map

| Component | File | Status |
|-----------|------|--------|
| `PoolManager` | `src/lib/db/pool-manager.ts` | New |
| `PostgresAdapter` | `src/lib/db/postgres-adapter.ts` | New |
| `TrpcRouter` | `src/daemon/router.ts` | New |
| `ForemanDaemon` | `src/daemon/index.ts` | New |
| `DaemonManager` | `src/lib/daemon-manager.ts` | New |
| `TrpcClient` | `src/lib/trpc-client.ts` | New |
| `GhCli` | `src/lib/gh-cli.ts` | New |
| `ProjectRegistry` | `src/lib/project-registry.ts` | New |
| `WorktreeManager` | `src/lib/worktree-manager.ts` | New (refactor from existing) |
| `MigrationRunner` | `src/lib/db/migrations/` | New |

**Files NOT created in v1:**
- `src/lib/db/adapter.ts` (removed — no DbAdapter interface)
- `src/lib/db/sqlite-adapter.ts` (removed — no SQLite)
- `src/lib/store.ts` (deprecated — replaced by tRPC procedures)
- `src/lib/task-store.ts` (deprecated — replaced by tRPC procedures)
