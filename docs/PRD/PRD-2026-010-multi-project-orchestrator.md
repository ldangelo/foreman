# PRD-2026-010: Multi-Project Orchestrator v2

**Document ID:** PRD-2026-010
**Version:** 2.0
**Status:** Ready for TRD
**Date:** 2026-04-21
**Author:** Product Management
**Scale Depth:** DEEP
**Supersedes:** PRD-2026-006 (Multi-Project Native Task Management), PRD-2026-010 v1.0 (adapter-pattern architecture)
**Readiness Score:** 4.5 (PASS — all ambiguities resolved)
**Resolved Clarifications:** 7/7 (all items resolved via deep-interview)

**Changelog v2.0:** Architectural pivot from adapter-pattern (CLI → DbAdapter → SqliteAdapter/PostgresAdapter) to API-first daemon (CLI → tRPC Client → ForemanDaemon → PostgresAdapter). SQLite removed from v1 scope. Migration-free onboarding replaces SQLite migration. tRPC daemon components added to architecture.

---

## PRD Health Summary

| Metric | Value |
|--------|-------|
| Must requirements | 12 |
| Should requirements | 6 |
| Could requirements | 5 |
| Won't requirements | 2 |
| Total requirements | 27 |
| AC coverage | 27/27 (100%) |
| Risk flags | 4 |
| Cross-requirement dependencies | 10 |
| Readiness score | 4.5 — PASS (all 7 deferred items resolved) |

---

## 1. Executive Summary

Foreman today is a per-project, per-directory tool: each invocation operates on the repository in the current working directory, with no awareness of other projects. An operator managing 5–20 repositories must context-switch between terminal windows to check on running agents, triage failures, and dispatch work — with no unified signal across repos.

PRD-2026-010 transforms Foreman into a **global multi-project orchestration platform** by introducing:

1. **API-first daemon architecture** — Foreman runs as a persistent tRPC daemon (`foreman daemon start`) exposing all operations via type-safe tRPC procedures. CLI commands are thin wrappers over a tRPC client. No direct database access from CLI.
2. **Postgres-backed task store** — the daemon connects directly to Postgres via a `PoolManager` + `PostgresAdapter`. SQLite is not used in v1. No `DbAdapter` interface, no SQLite adapter.
3. **GitHub-native project registry** — projects added via GitHub URL, cloned to `~/.foreman/projects/<project-id>/`, tracked in `~/.foreman/projects.json`
4. **Project-aware CLI** — `foreman inbox`, `status`, `board`, and all commands work across all projects from any directory via the tRPC client
5. **Cross-project dispatch and dashboard** — unified view of all projects, tasks, and agents with a "needs human" triage surface

**Architecture decision: API-first over adapter pattern.** The original PRD described a phased migration via a `DbAdapter` interface with `SqliteAdapter` + `PostgresAdapter` behind it. After adversarial review, that approach was replaced by a tRPC daemon architecture: the CLI never touches the database directly. Instead, all operations flow through the daemon's type-safe RPC layer. This eliminates the adapter interface maintenance burden, removes SQLite support entirely (simpler codebase), and provides a clean extension point for future capabilities (webhooks, dashboard polling, agent processes).

**API Protocol: tRPC.** Chosen over REST or GraphQL for: (1) end-to-end TypeScript type safety — the tRPC router's types are inferred by the client without code generation; (2) existing codebase is TypeScript-first; (3) no OpenAPI spec or codegen step required.

This document supersedes PRD-2026-006 and consolidates all multi-project orchestration requirements into a single reference.

---

## 2. Problem Statement

### 2.1 Context Switching Tax

Foreman operates exclusively within the current working directory. Operators managing 5–20 projects must:
- Maintain separate terminal sessions per project
- `cd` into each repo to run `foreman status`, `foreman reset`, or `foreman inbox`
- Manually track which projects have active agents, which have failures, and which need approval

This overhead grows linearly with project count and creates a class of operational failures where a stuck agent or failed merge goes unnoticed for hours.

### 2.2 No Unified Visibility

There is no cross-project view of:
- Active agents across all repos
- Tasks requiring human attention (conflicts, failures, pending approval)
- Aggregate dispatch and merge queue state

### 2.3 SQLite Doesn't Scale

Current architecture uses `better-sqlite3` with a per-project database at `<project>/.foreman/foreman.db`. With 20 projects and 5 concurrent agents each, SQLite's single-writer model creates contention. Concurrent dashboard reads block active agents and vice versa.

### 2.4 Existing PRD-2026-006 Scope

PRD-2026-006 described native task tracking, a project registry, and cross-project dispatch against the existing SQLite architecture. This PRD v2 retains those requirements and adds the GitHub-native project model, Postgres backing store, and migration path.

---

## 3. Goals and Non-Goals

### 3.1 Goals

1. **API-first daemon architecture** — `foreman daemon start` runs a persistent tRPC server on a Unix socket; all CLI commands route through tRPC client to the daemon; no direct database access from CLI
2. **Postgres multi-tenant store** — daemon connects to Postgres via `PoolManager` + `PostgresAdapter`; SQLite is not used in v1
3. **GitHub URL project addition** — `foreman project add <github-url>` clones the repo to `~/.foreman/projects/<project-id>/` using authenticated GitHub access
4. **Global project registry** — `~/.foreman/projects.json` maps project names to cloned paths and GitHub metadata
5. **Project-aware CLI** — all commands (`inbox`, `status`, `board`, `run`, `reset`, `retry`, etc.) operate on all registered projects or a specified project without requiring `cd`
6. **Unified dashboard** — cross-project TUI aggregating task and agent state via tRPC queries with a "needs human" priority panel
7. **Cross-project dispatch** — `foreman run` dispatches tasks from any registered project; `projectId` is required in multi-project mode
8. **Migration-free onboarding** — fresh Foreman installs start with Postgres directly; no SQLite data migration path in v1

### 3.2 Non-Goals

1. **SQLite support** — no `DbAdapter` interface, no `SqliteAdapter`, no `ForemanStore` refactoring. The daemon talks directly to Postgres via `PostgresAdapter`.
2. **Offline operation** — Foreman requires Postgres and GitHub connectivity; no local repo cache for offline work
3. **Custom workflow YAML changes** — pipeline phases unchanged; only project-aware dispatch is new
4. **Multi-user / team collaboration** — single-operator; no access control or concurrency features
5. **Cross-project task dependencies** — tasks within a project can depend on each other; cross-project task dependencies are out of scope
6. **Real-time WebSocket dashboard** — TTY dashboard refreshes on interval; no WebSocket or browser UI in v1
7. **External integrations** (Jira, Linear, GitHub Issues as task source) — out of scope
8. **Multi-host daemon deployment** — single machine; Unix socket or localhost; not exposed as a network service in v1

---

## 4. User Personas

### 4.1 Multi-Project Operator

**Name:** Alex, Senior Engineer
**Context:** Manages 8 active Foreman projects across 8 GitHub repositories. Has Foreman running per-repo today. Must context-switch between tmux windows to triage failures.
**Needs:** Single terminal view showing all 8 projects, active agents, and tasks needing attention. Wants to approve, reset, and dispatch work without `cd`.

### 4.2 Developer Adding a New Project

**Name:** Jordan, Platform Engineer
**Context:** Onboarding a new GitHub repo to Foreman. Currently must `git clone` manually, then `foreman init` in the cloned directory.
**Needs:** `foreman project add <github-url>` as the single onboarding command — clone, register, and ready in one step.

### 4.3 Single-Project User (Existing)

**Name:** Dana, Senior Engineer
**Context:** Uses Foreman on one repository. Has existing `.beads/` and `.foreman/foreman.db` data.
**Needs:** Zero regression. `foreman init` still works in a local directory. Beads import works. Existing commands unchanged.

---

## 5. Storage Architecture

### 5.1 System Architecture

```
CLI Commands (--project flag)
    │
    └────► TrpcClient (src/lib/trpc-client.ts)
                │
                │ Unix socket: ~/.foreman/daemon.sock
                │ or localhost: http://localhost:3847
                │
         ┌─────▼──────┐
         │ ForemanDaemon │  (src/daemon/)
         │ tRPC router   │  (src/daemon/router.ts)
         │ - projects    │
         │ - tasks       │
         │ - runs        │
         │ - events      │
         │ - messages    │
         └─────┬────────┘
               │
         ┌─────▼──────────┐
         │ PostgresAdapter  │  (src/lib/db/postgres-adapter.ts)
         └─────┬──────────┘
               │
         ┌─────▼──────────┐
         │  PoolManager     │  (src/lib/db/pool-manager.ts)
         │  pg-pool         │
         └────────────────┘
```

**Key design decisions:**
- **Daemon manages the database connection pool.** `PoolManager` is instantiated once inside the daemon process. The daemon is the only process that holds Postgres connections.
- **CLI is stateless.** All CLI commands are thin wrappers over tRPC client calls. No CLI process ever directly opens a database connection.
- **Monolithic tRPC router.** One router with all domain procedures (projects, tasks, runs, events, messages). No split-by-domain or split-by-workspace routers. Appropriate for single-operator v1.
- **Manual daemon lifecycle.** Operator explicitly `foreman daemon start` and `foreman daemon stop`. The daemon does not auto-start. If the daemon is not running, CLI commands fail with a clear error: `"Foreman daemon is not running. Run 'foreman daemon start' to start it."`

### 5.2 Directory Layout

```
~/.foreman/
├── config.yaml              # Global configuration (existing)
├── projects.json             # Global project registry
├── daemon.sock               # Unix socket for tRPC daemon (mode 0600)
├── daemon.pid                # PID file for daemon management
│
├── projects/                # Cloned GitHub repositories
│   └── <project-id>/        # e.g., foreman-abc12
│       ├── .git/            # Git clone of the repository
│       └── .foreman/        # Local config (workflow overrides)
│
└── worktrees/               # Git worktrees for dispatched tasks
    └── <project-id>/        # e.g., foreman-abc12
        └── foreman-<seed>   # Per-task worktree
```

### 5.3 Postgres Schema Design

Postgres hosts all Foreman state. Projects are isolated via a `project_id` column on all tables.

```sql
-- Projects registry (mirrors projects.json, stored in Postgres)
CREATE TABLE projects (
  id          TEXT PRIMARY KEY,  -- project-id (e.g., foreman-abc12)
  name        TEXT NOT NULL,     -- display name from GitHub repo name
  github_url  TEXT NOT NULL,     -- full GitHub URL
  clone_path  TEXT NOT NULL,     -- ~/.foreman/projects/<project-id>
  branch      TEXT NOT NULL DEFAULT 'main',
  added_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_sync   TIMESTAMPTZ,
  status      TEXT NOT NULL DEFAULT 'active'  -- active | paused | archived
);

-- All other tables use project_id as the tenancy key
CREATE TABLE runs (
  id          TEXT PRIMARY KEY,
  project_id  TEXT NOT NULL REFERENCES projects(id),
  seed_id     TEXT NOT NULL,
  agent_type  TEXT NOT NULL,
  -- ... all existing columns, project_id added as NOT NULL
);

CREATE TABLE tasks (
  id          TEXT PRIMARY KEY,
  project_id  TEXT NOT NULL REFERENCES projects(id),
  title       TEXT NOT NULL,
  -- ... all existing columns
);

-- Index on (project_id, status) for all tables — critical for per-project queries
CREATE INDEX idx_runs_project_status  ON runs    (project_id, status);
CREATE INDEX idx_tasks_project_status ON tasks   (project_id, status);
CREATE INDEX idx_events_project_run   ON events  (project_id, run_id);
```

### 5.4 Connection Pooling

- **PoolManager**: Singleton inside daemon. Created once on daemon startup. Default 20 connections; configurable.
- **Pool size**: Default 20; configured via `DATABASE_URL` or `~/.foreman/config.yaml`.
- **Project isolation**: All queries include `WHERE project_id = $1`; Postgres row-level security deferred to v2.
- **No SQLite in v1.** `ForemanStore`, `DbAdapter`, `SqliteAdapter` are not part of the v1 architecture. Existing code using `ForemanStore` will be migrated to tRPC procedure calls.

---

## 6. Feature Areas

---

### 6.1 Feature Area: GitHub Project Registry

#### REQ-001: GitHub-URL Project Addition

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** Medium
**Risk:** [RISK: GitHub API rate limits — unauthenticated = 60 req/hr; must require authenticated access]

`foreman project add <github-url>` shall accept a GitHub repository URL (HTTPS or SSH), resolve it via the GitHub API using the configured credentials, clone it to `~/.foreman/projects/<project-id>/`, and register it in `~/.foreman/projects.json`.

**Storage:** Project registry lives in `~/.foreman/projects.json` (file-based for resilience) and is mirrored to Postgres `projects` table for query use.

**Project ID generation:** Project IDs are derived from the GitHub repo name, normalized to lowercase with non-alphanumeric characters replaced by dashes, plus a 5-character hex suffix for collision resistance: `<normalized-name>-<hex5>` (e.g., `my-project-a1b2c`).

**Acceptance Criteria:**
- AC-001.1: Given `foreman project add https://github.com/owner/repo`, when `gh` is installed and authenticated (`gh auth status` succeeds), then Foreman clones the repo to `~/.foreman/projects/<project-id>/` using `gh repo clone`. If `gh` is not installed, Foreman exits with: `"GitHub CLI (gh) is required but not installed. Install it from https://cli.github.com"`.
- AC-001.2: Given `foreman project add <url>` when `gh auth status` reports unauthenticated, then Foreman fails with: `"GitHub authentication required. Run 'gh auth login' to authenticate."`
- AC-001.3: Given `foreman project add <url>` when the project is already registered, then Foreman exits with error: `"Project '<project-id>' already registered. Run 'foreman project list' to see all registered projects."`
- AC-001.4: Given `foreman project add <url>` with a private repository, when the authenticated `gh` account lacks read access, then `gh repo clone` fails and Foreman propagates the error: `"Could not clone repository: access denied."`

---

#### REQ-002: Project Listing and Health

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** Low

`foreman project list` shall display all registered projects with health status and summary statistics.

**Acceptance Criteria:**
- AC-002.1: `foreman project list` outputs a table with columns: `NAME`, `PROJECT ID`, `GITHUB URL`, `STATUS`, `RUNNING`, `READY TASKS`, `NEEDS HUMAN`. A project is **healthy** if its clone directory exists and `git fetch` succeeds within 5 seconds. A project is **stale** if the directory is missing or fetch fails. A project is **paused** if its `status` field is `paused`.
- AC-002.2: `foreman project remove <name>` removes the project from the registry and marks its `status = 'archived'` in Postgres (data retained for history). If the project has active runs, the command exits with error unless `--force` is provided.
- AC-002.3: `foreman project sync <name>` runs `git fetch --all` on the project's clone and updates `last_sync` timestamp in Postgres. `foreman project sync --all` syncs all registered projects sequentially.

---

#### REQ-003: GitHub Webhook Integration

**Priority:** P2 (medium)
**MoSCoW:** Could
**Complexity:** High
**Risk:** [RISK: Webhook security — signature verification must be implemented correctly]

`foreman webhook` shall expose an HTTP endpoint that receives GitHub push and PR events and triggers appropriate Foreman actions (e.g., rebase worktrees on push, update task status on PR merge).

**Acceptance Criteria:**
- AC-003.1: `foreman webhook --listen <port>` starts an HTTP server that verifies GitHub webhook signatures (HMAC-SHA256) before processing events.
- AC-003.2: Given a GitHub `push` event to a project's default branch, when Foreman receives it via webhook, then all active worktrees for that project are automatically rebased onto the updated branch.
- AC-003.3: Given a GitHub `pull_request` event with `action=closed` and `merged=true`, when Foreman receives it, then the associated task in the task store is transitioned to `merged`.

---

### 6.2 Feature Area: Postgres Backing Store

#### REQ-004: Daemon Startup, Postgres Pool, and tRPC Server

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** High
**Risk:** [RISK: Connection pool exhaustion — 20 projects × 5 agents = 100 potential concurrent connections]

`foreman daemon start` shall start the Foreman daemon as a long-lived process that initializes the Postgres connection pool and starts a tRPC HTTP server. The daemon manages all database connections; CLI commands communicate with it via tRPC.

**Configuration:**
```yaml
# ~/.foreman/config.yaml
database:
  url: "${DATABASE_URL:-postgresql://localhost/foreman}"  # defaults to localhost if unset
  pool_size: 20
  idle_timeout_ms: 30_000
  connection_timeout_ms: 5_000
daemon:
  socket_path: "${DAEMON_SOCKET:-~/.foreman/daemon.sock}"  # Unix socket
  port: 3847                                               # localhost fallback
```

**Acceptance Criteria:**
- AC-004.1: `foreman daemon start` starts the daemon process. On startup, it resolves `DATABASE_URL` from the environment or defaults to `postgresql://localhost/foreman`, then validates the connection by running `SELECT 1`. If the connection fails, the daemon exits with: `"Cannot connect to Postgres: <error>. Check DATABASE_URL and ensure Postgres is running."`
- AC-004.2: The daemon listens on a Unix socket at `~/.foreman/daemon.sock` (mode 0600) by default. If the socket file cannot be created, the daemon falls back to `http://localhost:3847`.
- AC-004.3: `PoolManager` is a singleton inside the daemon process, created once at startup. All database operations go through this pool. No database connections are held by CLI processes.
- AC-004.4: All database operations use parameterized queries (`$1`, `$2` placeholders) to prevent SQL injection. No string interpolation of user input into SQL.
- AC-004.5: The pool is configured with `pool_size=20` and `idle_timeout_ms=30_000` by default. Pool size is configurable via `pool_size` in `~/.foreman/config.yaml`. If the pool is exhausted, pending requests queue behind available connections (backpressure).

---

#### REQ-005: Postgres Schema Initialization and Migrations

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** Medium

Foreman shall manage Postgres schema via a migration system. On first startup, Foreman runs all pending migrations. Subsequent startups apply only new migrations.

**Migration tool:** Use a lightweight migration runner (e.g., `db-migrate`, `node-pg-migrate`, or custom) that tracks applied migrations in a `schema_migrations` table.

**Acceptance Criteria:**
- AC-005.1: `foreman db migrate` runs all pending migrations in order. Each migration is atomic (wrapped in a transaction). Migration failures roll back cleanly.
- AC-005.2: `foreman db status` shows which migrations are applied and which are pending, with timestamps.
- AC-005.3: `foreman db rollback --steps N` rolls back the last N migrations. Rollback is only supported for reversible migrations (marked with `reversible: true`).
- AC-005.4: The migration system is idempotent — re-running a migration that has already been applied is a no-op.

---

#### REQ-006: Per-Project Data Isolation

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** Medium

All tables include `project_id` as a required column. All queries in task-context include `WHERE project_id = $1`. The system enforces referential integrity via foreign keys.

**Acceptance Criteria:**
- AC-006.1: The `runs`, `tasks`, `task_dependencies`, `events`, `merge_queue`, `messages`, `bead_write_queue`, `costs`, and `rate_limit_events` tables all include `project_id TEXT NOT NULL REFERENCES projects(id)`.
- AC-006.2: A database trigger prevents insertion of rows with a `project_id` not present in the `projects` table.
- AC-006.3: Queries that omit `project_id` in a project-context operation are rejected at the TypeScript level (compile-time error via `projectId: string` parameter on all store methods).

---

#### REQ-007: Database-Level Locking for Critical Sections

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** Medium

Postgres `FOR UPDATE` row locking shall be used for task claiming, status updates, and merge queue operations to prevent race conditions across concurrent Foreman processes.

**Acceptance Criteria:**
- AC-007.1: `NativeTaskStore.claim()` uses `SELECT ... FOR UPDATE` to lock the task row before updating `status = 'in-progress'` and `run_id`. Concurrent claim attempts on the same task are serialized — the second process waits and then receives `null` (task already claimed).
- AC-007.2: `Refinery.processQueue()` uses `SELECT ... FOR UPDATE` on merge queue entries to prevent two processes from processing the same entry simultaneously.
- AC-007.3: All status transitions on `tasks` use transaction-scoped row locks (`FOR UPDATE`) rather than session-level advisory locks. Advisory locks are deferred to v2 for complex cross-transaction coordination scenarios.

---

### 6.3 Feature Area: Storage and Worktree Management

#### REQ-008: Project Clone Storage

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** Low

Foreman shall manage the lifecycle of cloned GitHub repositories under `~/.foreman/projects/<project-id>/`.

**Acceptance Criteria:**
- AC-008.1: `foreman project add <url>` creates the parent directory `~/.foreman/projects/` if it does not exist.
- AC-008.2: Initial clone uses `git clone --mirror <url> ~/.foreman/projects/<project-id>/`. The mirror is converted to a regular clone on first use: `git clone --bare ... && git config remote.origin.fetch '+refs/*:refs/*' && git fetch`.
- AC-008.3: `foreman project remove <name>` archives the project but does NOT delete the clone directory by default. `--delete-clone` flag removes the cloned repo from disk.
- AC-008.4: The clone is maintained via `git fetch origin` runs. `foreman project sync` performs a fetch. A background sync mechanism (optional, deferred to v2) may run periodic fetches.

---

#### REQ-009: Worktree Lifecycle

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** Medium

Worktrees for dispatched tasks shall be created in `~/.foreman/worktrees/<project-id>/` rather than within the project clone directory.

**Acceptance Criteria:**
- AC-009.1: `dispatcher.createWorktree()` creates worktrees at `~/.foreman/worktrees/<project-id>/<seed-id>` relative to the project clone, e.g., `~/.foreman/worktrees/foreman-abc12/foreman-xyz789`.
- AC-009.2: The VCS backend (Git or Jujutsu) is initialized in the worktree directory using the project's clone as the reference: `git worktree add --checkout <worktree-path> <branch> <project-clone-path>`.
- AC-009.3: `foreman worktree list` shows all worktrees across all registered projects with columns: `PROJECT`, `WORKTREE`, `BRANCH`, `STATUS` (active/clean/dirty), `TASK`.
- AC-009.4: `foreman worktree clean` removes orphaned worktrees (worktrees whose task no longer exists or whose branch is fully merged). Confirmation prompt unless `--force` is provided.

---

### 6.4 Feature Area: Project-Aware CLI

#### REQ-010: `--project` Flag on All Commands

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** Low

All Foreman commands that operate on tasks, runs, or agents shall accept a `--project <name>` flag that scopes the operation to a specific registered project without requiring `cd`.

**Acceptance Criteria:**
- AC-010.1: `foreman <cmd> --project <name>` resolves `<name>` from `~/.foreman/projects.json`. If not found, exits with: `"Project '<name>' not found. Run 'foreman project list' to see registered projects."`
- AC-010.2: `foreman <cmd> --project <path>` accepts an absolute filesystem path to a cloned project directory and operates on it directly (registry lookup bypassed).
- AC-010.3: `foreman <cmd> --all` operates across all registered, non-archived projects. Commands that don't support `--all` exit with: `"Command '<cmd>' does not support --all. Use --project to specify a target."`

---

#### REQ-011: Project-Aware `foreman inbox`

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** Low

`foreman inbox` shall display agent mail from the specified project (or all projects with `--all`), with project name as a filter column.

**Acceptance Criteria:**
- AC-011.1: `foreman inbox --project <name>` shows mail filtered to that project. `foreman inbox --all` shows mail from all registered projects with a `PROJECT` column.
- AC-011.2: `foreman inbox --watch --all` streams mail in real-time across all projects with project name prefixed to each line: `[<project-id>] <message>`.
- AC-011.3: Mail is stored in the Postgres `messages` table keyed by `project_id`. The existing mail schema is preserved; only the storage backend changes from per-project SQLite to shared Postgres.

---

#### REQ-012: Project-Aware `foreman status`

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** Low

`foreman status` shall display runs and agent state for the specified project or all projects.

**Acceptance Criteria:**
- AC-012.1: `foreman status --project <name>` shows the status table for that project (matching current output format, preserving column layout).
- AC-012.2: `foreman status --all` shows a condensed cross-project status table: `PROJECT`, `RUNNING`, `COMPLETED TODAY`, `FAILED`, `READY`, `NEEDS HUMAN`, `LAST ACTIVITY`.

---

#### REQ-013: Project-Aware `foreman board`

**Priority:** P1 (high)
**MoSCoW:** Should
**Complexity:** Low

`foreman board` (existing kanban board) shall work in multi-project mode with project scope.

**Acceptance Criteria:**
- AC-013.1: `foreman board --project <name>` shows the kanban board filtered to that project.
- AC-013.2: `foreman board --all` shows all projects' tasks in the board view, with a project header row separating each project's tasks. Tasks are grouped by project, then by status column.

---

#### REQ-014: `foreman run` in Multi-Project Mode

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** High
**Risk:** [RISK: Backward compatibility — existing single-project users must not be disrupted]

`foreman run` shall dispatch tasks from a specified project. In multi-project mode (when `~/.foreman/projects.json` has entries), `--project` is required. In single-project mode (legacy behavior), `foreman run` operates on the current directory as today.

**Mode detection:** Multi-project mode is active when `~/.foreman/projects.json` contains at least one entry. The mode is read at startup; it does not change during a running process.

**Acceptance Criteria:**
- AC-014.1: Given `~/.foreman/projects.json` has two or more registered projects (multi-project mode), when `foreman run` is invoked without `--project`, then Foreman exits with: `"Multiple projects registered. Use --project <name> to specify the target project."`
- AC-014.2: Given `foreman run --project <name>`, when the project is healthy and has ready tasks, then the dispatcher queries `SELECT * FROM tasks WHERE project_id = <id> AND status = 'ready' ORDER BY priority ASC` and dispatches the highest-priority task.
- AC-014.3: Given single-project mode (zero or one project in `~/.foreman/projects.json`), `foreman run` operates on the current directory (zero projects) or the sole registered project (one project) with no `--project` flag required.
- AC-014.4: `foreman run --project <name> --bead <task-id>` dispatches a specific task regardless of its status, forcing it to `ready` if it was `backlog` (equivalent to implicit approve).

---

### 6.5 Feature Area: Unified Dashboard

#### REQ-015: Cross-Project Dashboard

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** Medium

`foreman dashboard` shall open a TTY dashboard that aggregates task and agent state from Postgres across all registered projects, rendered in a single terminal view.

**Acceptance Criteria:**
- AC-015.1: `foreman dashboard` (dedicated subcommand) reads all registered projects from Postgres `projects` table and opens each project's data via Postgres queries with `WHERE project_id IN (...)`. No separate database files are opened.
- AC-015.2: The dashboard renders with a project-selector header (tabs or sidebar), a "Needs Human" panel (always visible, top priority), a per-project agent status panel, and a task list panel.
- AC-015.3: The dashboard refreshes at a configurable interval (default: 5 seconds). The refresh rate is set via `--refresh <seconds>` CLI flag.
- AC-015.4: Projects whose Postgres queries fail show a `[error]` indicator with the error message. A single project's failure does not crash the dashboard.

---

#### REQ-016: "Needs Human" Triage Panel

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** Low

The dashboard shall display a dedicated "Needs Human" panel surfacing all tasks requiring operator attention: `conflict`, `failed`, `stuck`, or `backlog` (awaiting approval) across all projects.

**Acceptance Criteria:**
- AC-016.1: The panel lists tasks where `status IN ('conflict', 'failed', 'stuck', 'backlog')` across all registered projects. Each row shows: `PROJECT`, `TASK ID`, `TITLE`, `STATUS`, `AGE` (time since `updated_at`). Sorted by priority (P0 first) then age (oldest first).
- AC-016.2: When empty, the panel displays `"✓ No tasks need attention."` in a visually distinct style.
- AC-016.3: Keyboard navigation: `a` approves a `backlog` task, `r` resets a `failed` or `stuck` task, `Enter` shows full task detail. Actions are dispatched to the correct project without directory change.

---

#### REQ-017: Aggregate Metrics Panel

**Priority:** P1 (high)
**MoSCoW:** Should
**Complexity:** Low

The dashboard shall display aggregate metrics across all projects.

**Acceptance Criteria:**
- AC-017.1: Header bar shows: `N projects | M running agents | K tasks dispatched today | J merged today | $X estimated cost today`.
- AC-017.2: Per-project column shows: `READY`, `IN-PROGRESS`, `MERGED`, `FAILED` task counts for that project.

---

### 6.6 Feature Area: Beads Data Import

#### REQ-018: Beads Data Import

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** Medium

`foreman task import --from-beads --project <name>` shall import existing `.beads/beads.jsonl` data from a project's clone directory into Postgres.

**Acceptance Criteria:**
- AC-018.1: Reads `.beads/beads.jsonl` from the project's clone path (`~/.foreman/projects/<project-id>/.beads/beads.jsonl`). Maps each bead to a native task in Postgres `tasks` table with `project_id` set correctly.
- AC-018.2: Beads status mapping: `open` → `backlog`, `in_progress` → `ready` (auto-approved after import), `closed` → `merged`. Dependencies are preserved as `blocks` relationships in `task_dependencies`.
- AC-018.3: `foreman task import --from-beads --project <name> --dry-run` shows what would be imported without writing to Postgres.

---

### 6.7 Feature Area: Non-Functional Requirements

#### REQ-021: Postgres Performance

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** Medium

The Postgres-backed store shall handle 20 projects with 5 concurrent agents per project (100 simultaneous operations) without exceeding 200ms p95 query latency.

**Acceptance Criteria:**
- AC-021.1: Dashboard refresh time (aggregate query across 20 projects) is under 2 seconds p95 on a standard machine with local Postgres.
- AC-021.2: Task dispatch (claim + run creation in one transaction) completes in under 100ms p95.
- AC-021.3: Connection pool size is configurable. Default 20 connections handles 100-agent load under normal conditions. Under extreme load (>100 concurrent operations), operations queue behind available connections.

---

#### REQ-022: Operational Observability

**Priority:** P1 (high)
**MoSCoW:** Should
**Complexity:** Low

Foreman shall log all cross-project operations with project context.

**Acceptance Criteria:**
- AC-022.1: All log entries during a project-scoped operation include `project_id=<id>` in the log line.
- AC-022.2: `foreman doctor` checks: Postgres connectivity, migration status for all registered projects, clone directory health, and GitHub API reachability.

---

#### REQ-023: Graceful Degradation

**Priority:** P1 (high)
**MoSCoW:** Should
**Complexity:** Medium

Foreman shall degrade gracefully when Postgres is temporarily unavailable.

**Acceptance Criteria:**
- AC-023.1: If Postgres is unreachable at startup, Foreman exits with a clear error message and recovery instructions.
- AC-023.2: If Postgres becomes unreachable during a running agent process, the agent logs an error and enters a degraded state — it continues executing but cannot log events or update task status. On reconnection, it resumes normal operation.

---

#### REQ-024: Migration-Free Onboarding

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** Low
**Risk:** [RISK: Existing users with SQLite data must be supported — data is not migrated automatically]

Foreman v1 starts fresh with Postgres. Existing users with per-project `.foreman/foreman.db` SQLite files are not automatically migrated. The daemon does not read SQLite files.

**Acceptance Criteria:**
- AC-024.1: Fresh Foreman installs initialize directly with Postgres. `foreman daemon start` runs migrations to create all required tables.
- AC-024.2: `foreman project add <github-url>` registers a project and stores its data in Postgres. No SQLite file is created for registered projects.
- AC-024.3: Existing users with SQLite data in per-project `.foreman/foreman.db` files are not affected by v1 installation — the old SQLite data remains accessible if they do not upgrade. If they choose to upgrade, `foreman task import --from-beads --project <name>` imports beads data from the project's clone directory.
- AC-024.4: `foreman run --bead <id>` without `--project` works in single-project mode (one project registered) and fails in multi-project mode (2+ projects registered) with: `"Multiple projects registered. Use --project <name> to specify the target project."`

---

#### REQ-025: GitHub Credential Management

**Priority:** P0 (critical)
**MoSCoW:** Must
**Complexity:** Low

Foreman shall manage GitHub credentials securely for project cloning and API access.

**Acceptance Criteria:**
- AC-025.1: `gh` CLI is the exclusive integration layer for all GitHub operations. `gh auth status` is called on startup to verify credentials. If unauthenticated, Foreman exits with `"GitHub authentication required. Run 'gh auth login' to authenticate."`
- AC-025.2: Project addition uses `gh repo clone` for repository cloning. `gh api` is used for repository metadata (default branch, visibility, permissions). No direct HTTP calls to github.com.
- AC-025.3: `gh` manages authentication via OS keychain (macOS Keychain, Linux secret-service). No token storage in Foreman config files.

---

#### REQ-026: Scalability Ceiling

**Priority:** P2 (medium)
**MoSCoW:** Could
**Complexity:** Low

Foreman v1 targets 5–20 simultaneous projects. The architecture shall support scaling to 50 projects with 10 agents each without architectural changes (connection pool size adjustment only).

**Acceptance Criteria:**
- AC-026.1: Dashboard query uses indexed `WHERE project_id IN (...)` — no full-table scans regardless of project count.
- AC-026.2: `foreman doctor` warns when total active agents across all projects exceeds 80% of the configured connection pool size.

---

## 7. Dependency Map

| REQ | Depends On | Blocked By | Notes |
|-----|-----------|-----------|-------|
| REQ-002 (Project Listing) | REQ-001 | — | Needs registry populated by add |
| REQ-004 (Daemon + Pool) | REQ-005 | — | Daemon runs migrations on startup |
| REQ-005 (Schema Migrations) | — | REQ-004 | Schema must exist before daemon can serve requests |
| REQ-006 (Per-Project Isolation) | REQ-005 | — | FK constraints need schema |
| REQ-007 (DB Locking) | REQ-004, REQ-006 | — | Row locking on isolated tables |
| REQ-008 (Clone Storage) | REQ-001 | — | Needs project registered first |
| REQ-009 (Worktree Lifecycle) | REQ-008 | — | Needs clone path structure |
| REQ-010 (--project Flag) | REQ-001 | — | Needs registry to resolve names |
| REQ-011 (Project-Aware Inbox) | REQ-004, REQ-010 | — | Needs daemon + registry |
| REQ-012 (Project-Aware Status) | REQ-004, REQ-010 | — | Needs daemon + registry |
| REQ-013 (Project-Aware Board) | REQ-004, REQ-010 | — | Needs daemon + registry |
| REQ-014 (Multi-Project Run) | REQ-004, REQ-009, REQ-010 | — | Needs daemon + worktree dir |
| REQ-015 (Cross-Project Dashboard) | REQ-004, REQ-010 | — | Needs daemon + registry |
| REQ-016 (Needs Human Panel) | REQ-015 | — | Part of dashboard |
| REQ-017 (Aggregate Metrics) | REQ-015 | — | Part of dashboard |
| REQ-018 (Beads Import) | REQ-005 | — | Needs Postgres schema (via daemon) |
| REQ-021 (PG Performance) | REQ-004, REQ-007 | — | Needs locking + pool tuning |
| REQ-022 (Observability) | REQ-004 | — | Needs daemon |
| REQ-023 (Graceful Degradation) | REQ-004 | — | Needs daemon |
| REQ-024 (Migration-Free Onboarding) | — | — | Independent |
| REQ-025 (GitHub Credentials) | REQ-001 | — | Needs auth for clone |
| REQ-026 (Scalability) | REQ-004, REQ-006 | — | Needs isolation + indexes |

**Implementation clusters (can be developed in parallel):**
1. **Cluster A — Daemon foundation:** REQ-004, REQ-005, REQ-006, REQ-007
2. **Cluster B — GitHub registry:** REQ-001, REQ-002, REQ-025
3. **Cluster C — Storage & worktrees:** REQ-008, REQ-009
4. **Cluster D — Project-aware CLI:** REQ-010, REQ-011, REQ-012, REQ-013, REQ-014
5. **Cluster E — Dashboard:** REQ-015, REQ-016, REQ-017
6. **Cluster F — Import:** REQ-018

---

## 8. Ambiguity Markers

All 7 items resolved via deep-interview (2026-04-21):

| # | Requirement | Resolution |
|---|-------------|------------|
| 1 | REQ-001 | `gh` CLI exclusive — GitHub App vs PAT deferred to v2 |
| 2 | REQ-003 | Built-in webhook server |
| 3 | REQ-004 | Defaults to `postgresql://localhost/foreman` |
| 4 | REQ-007 | `FOR UPDATE` — advisory locks deferred to v2 |
| 5 | REQ-014 | 2+ projects = multi-project mode |
| 6 | REQ-015 | `foreman dashboard` subcommand |
| 7 | REQ-025 | `gh` manages auth — no token storage needed |

**Ambiguity scan complete: 0 items remain. All decisions resolved.**

---

## 9. Implementation Readiness Gate

### Self-Critique Issues

Before presenting to the operator, I identified the following issues:

**Gaps:**
1. **No explicit requirement for `--project` default behavior** — when multi-project mode is active, should the default project be configurable (e.g., `~/.foreman/config.yaml` → `default_project: <name>`), or must `--project` always be explicit? [→ Recommend: explicit `--project` required, no default]
2. **No requirement for project-level config** — each project can have its own `.foreman/config.yaml` for workflow overrides. Should this PRD address per-project config merging, or defer? [→ Recommend: defer per-project config to v2]
3. **Webhook deployment** — REQ-003 describes the webhook but doesn't specify how to expose it (reverse proxy, ngrok, cloud LB). [→ Recommend: defer webhook deployment model]

**Contradictions:**
4. **Backward compat vs. multi-project mode** — REQ-024 says SQLite is not removed in v1, but REQ-014 says multi-project mode requires Postgres. Can a project be registered in the registry but still use its local SQLite? [→ Recommend: Projects in the registry use Postgres; local-only projects (not in registry) use SQLite]

**Ambiguity:**
5. **Dashboard as separate binary or flag?** — unclear from requirements.
6. **Token storage encryption** — no security model specified.
7. **GitHub App vs. PAT** — not specified.

**Missing edge cases:**
8. **Project rename** — if a GitHub repo is renamed, should Foreman auto-update the project ID? [→ Recommend: `foreman project rename <old> <new>` explicit command]
9. **Concurrent project add** — two `foreman project add` for the same URL simultaneously. [→ Recommend: DB unique constraint on `github_url` handles this]
10. **Partial migration failure** — if SQLite → Postgres migration fails mid-way. [→ Recommend: transaction per table, idempotent re-run]

---

## 10. Resolved Issues & Open Questions

### Resolved Decisions (all 7 items)

**Issue 1:** REQ-001 + REQ-025 (GitHub Integration) — **RESOLVED via deep-interview**
Foreman uses `gh` CLI exclusively for all GitHub operations. `gh` must be installed. `gh auth status` verifies credentials. `gh repo clone` handles cloning. `gh api` handles API calls. No direct PAT handling — `gh` manages auth via OS keychain natively. GitHub App tokens deferred to v2.

**Issue 2:** REQ-004 (Postgres DATABASE_URL) — **RESOLVED via deep-interview**
`DATABASE_URL` defaults to `postgresql://localhost/foreman` when unset. Local dev convenience. Production sets it explicitly.

**Issue 3:** REQ-007 (Task Claiming Lock Strategy) — **RESOLVED via deep-interview**
`FOR UPDATE` row locks. Transaction-scoped. Simple, sufficient. Advisory locks deferred to v2.

**Issue 4:** REQ-015 (Dashboard Command Structure) — **RESOLVED via deep-interview**
`foreman dashboard` as dedicated subcommand. Fits existing CLI pattern.

**Issue 5:** REQ-014 (Multi-Project Mode Detection) — **RESOLVED in original PRD**
Multi-project mode activates at 2+ projects. 0/1 project = single-project mode, no `--project` required.

**Issue 6:** REQ-025 (GitHub Token Storage) — **RESOLVED by Issue 1**
No token storage needed — `gh` handles auth via OS keychain.

**Issue 7:** REQ-003 (Webhook Deployment) — **RESOLVED in original PRD**
Built-in `foreman webhook --port 9000` server.

All items resolved — no deferred questions remain.

---

## 11. Acceptance Criteria Summary

| REQ-NNN | Description | Priority | Complexity | AC Count |
|---------|-------------|----------|-----------|----------|
| REQ-001 | GitHub-URL Project Addition | Must | Medium | 4 |
| REQ-002 | Project Listing and Health | Must | Low | 3 |
| REQ-003 | GitHub Webhook Integration | Could | High | 3 |
| REQ-004 | Daemon Startup + tRPC + Pool | Must | High | 5 |
| REQ-005 | Postgres Schema Migrations | Must | Medium | 4 |
| REQ-006 | Per-Project Data Isolation | Must | Medium | 3 |
| REQ-007 | DB-Level Locking | Must | Medium | 3 |
| REQ-008 | Project Clone Storage | Must | Low | 4 |
| REQ-009 | Worktree Lifecycle | Must | Medium | 4 |
| REQ-010 | `--project` Flag on All Commands | Must | Low | 3 |
| REQ-011 | Project-Aware `foreman inbox` | Must | Low | 3 |
| REQ-012 | Project-Aware `foreman status` | Must | Low | 2 |
| REQ-013 | Project-Aware `foreman board` | Should | Low | 2 |
| REQ-014 | `foreman run` in Multi-Project Mode | Must | High | 4 |
| REQ-015 | Cross-Project Dashboard | Must | Medium | 4 |
| REQ-016 | "Needs Human" Triage Panel | Must | Low | 3 |
| REQ-017 | Aggregate Metrics Panel | Should | Low | 2 |
| REQ-018 | Beads Data Import | Must | Medium | 3 |
| REQ-021 | Postgres Performance | Must | Medium | 3 |
| REQ-022 | Operational Observability | Should | Low | 2 |
| REQ-023 | Graceful Degradation | Should | Medium | 2 |
| REQ-024 | Migration-Free Onboarding | Must | Low | 4 |
| REQ-025 | GitHub Credential Management | Must | Low | 3 |
| REQ-026 | Scalability Ceiling | Could | Low | 2 |

---

## 11. Implementation Readiness Gate

| Dimension | Score | Notes |
|-----------|-------|-------|
| Completeness | 4/5 | All 6 feature areas covered. API-first architecture documented. Gaps deferred to v2 by design. |
| Testability | 5/5 | Every Must/Should has ACs in G/W/T format. tRPC procedures map directly to ACs. |
| Clarity | 4/5 | User-observable behaviors. Daemon lifecycle, tRPC router, CLI contracts are precise. |
| Feasibility | 4/5 | All ambiguity resolved. Daemon architecture is simpler than adapter pattern. Recommend phased delivery: Cluster A (daemon) → B (registry) → C (worktrees) → D (CLI) → E (dashboard) → F (import). |
| **Overall** | **4.25** | **PASS — proceed to /ensemble:create-trd** |

**Key implementation risks:**
1. **REQ-004 (Daemon + tRPC server)** — daemon lifecycle management, Unix socket permissions, process supervision. Critical path gate for all other clusters.
2. **REQ-004 (Postgres pool)** — connection pool exhaustion under 100-agent load. Load test in Sprint 1.
3. **REQ-001 (GitHub clone)** — authenticated-only. Test with private repos early.

---

## 12. Next Steps

All ambiguities resolved. PRD is ready for TRD creation.

**Next step:**
```
/ensemble:create-trd docs/PRD/PRD-2026-010-multi-project-orchestrator.md
```

---

## Appendix A: PostgreSQL vs. SQLite Feature Comparison

| Dimension | SQLite | Postgres |
|-----------|--------|----------|
| Connection model | Single writer, multiple readers | Connection pool (configurable size) |
| Concurrent writers | Serialized (busy_timeout) | Parallel (MVCC) |
| Connection pooling | N/A (embedded) | Required (pg-pool) |
| JSON support | Yes (json1) | Yes (jsonb with GIN indexes) |
| Full-text search | Extension required | Built-in (tsvector) |
| Row-level locking | File-level only | Yes (FOR UPDATE, advisory locks) |
| Schema migrations | Manual | Tooled (node-pg-migrate, etc.) |
| Cloud hosting | N/A (local file) | Any Postgres-compatible host |
| Backup | File copy | pg_dump, continuous WAL |

**Key decision rationale:** The primary drivers for Postgres are: (1) concurrent writer support — 20 projects × 5 agents = many concurrent writes; (2) connection pooling — single pool shared across all processes; (3) row-level locking — critical for task claiming without race conditions.

---

## Appendix B: Architecture Comparison

| Dimension | v1 Architecture (tRPC Daemon) | v1 Architecture (Adapter Pattern, superseded) |
|-----------|-------------------------------|---------------------------------------------|
| Database | Postgres only via `PostgresAdapter` | SqliteAdapter + PostgresAdapter via `DbAdapter` |
| CLI ↔ DB | tRPC client → daemon → PostgresAdapter | Direct `ForemanStore` calls (SQLite) |
| New pool | `PoolManager` singleton in daemon | `PoolManager` singleton, shared across processes |
| SQLite support | None (removed) | Kept for backward compat |
| Migration path | None (fresh install) | SQLite → Postgres migration tool |
| Complexity | Lower (one adapter, one path) | Higher (two adapters, interface maintenance) |
| Extension point | tRPC procedures (easy to add) | Adapter method on interface |

**Why daemon over adapter pattern:**

1. **Simpler codebase.** No `DbAdapter` interface to maintain (50+ methods). No dual-adapter burden.
2. **Cleaner extension.** Adding a webhook handler, a dashboard polling endpoint, or agent process communication is a new tRPC procedure — no interface change required.
3. **Process isolation.** The daemon can be restarted independently of the CLI. Long-running agent processes connect to the same daemon.
4. **No SQLite.** Removes `better-sqlite3` from the dependency tree for new installations.
