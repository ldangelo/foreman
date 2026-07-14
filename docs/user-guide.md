# Foreman User Guide

This guide explains how to use Foreman day to day. For exact flags and command syntax, see the [CLI Reference](./cli-reference.md).

## Overview

Foreman is a multi-agent coding orchestrator that manages AI engineering work through isolated git worktrees with a PostgreSQL-backed event store and scheduler.

### Architecture

Foreman has three runtime layers:

| Layer | Technology | Role |
|-------|------------|------|
| Node CLI | TypeScript/Node | Operator commands, VCS/worktree operations, Pi SDK worker bridge |
| Elixir Server | Elixir/OTP | Event store, task scheduler, projections, overwatch, PR reconciliation |
| Node/Pi Workers | TypeScript + Pi SDK | Agent execution, phase prompts, tool calls |

**Event sourcing:** The Elixir backend uses domain events as the source of truth. Projections and read models (status displays, log summaries) are derived views updated after events are observed.

**Worker bridge:** Worker/Pi SDK tool calls and assistant messages emit ordered worker events before being mirrored into raw logs. Phase reports emit structured report events so Elixir Overwatch can send compact next-phase Agent Mail steering without depending on report filenames.

### Core Workflows

1. **Task Lifecycle:** Task created → enters ready queue → dispatched to worktree → pipeline phases run → finalized → PR created/merged
2. **Dispatch Flow:** `foreman run` sends scheduler tick to Elixir → ready tasks claimed by capacity → workers launched in git worktrees
3. **Pipeline Phases:** Explorer → Developer → cicd-developer/cr-developer/merge-resolver (on failure) → QA → Reviewer → Documentation → Finalize → create-pr → pr-wait → merge
4. **Retry Pattern:** Phase failures match `retryWithByReason` patterns to route to specialized recovery agents

### Skills and Prompts

Foreman uses bundled Pi skills for specialized tasks:

| Skill | Purpose |
|-------|---------|
| `foreman-workflow-pipeline` | Workflow YAML, phase behavior, PR gates |
| `foreman-elixir-backend` | Event store, scheduler, projections |
| `foreman-vcs-backend` | Git/worktree operations |
| `foreman-doc-gate` | Documentation requirements |
| `foreman-pipeline-diagnosis` | Stuck run debugging |
| `foreman-safe-recovery` | Run/worktree cleanup decisions |

Phase prompts live in `src/defaults/prompts/` and are installed to runtime paths by `foreman init --force`.

### MCP/Foreman Tool Integration

Foreman exposes MCP tools for integrated task management:

**Read tools:** `foreman.projects.list`, `foreman.tasks.list`, `foreman.tasks.show`, `foreman.runs.summary`, `foreman.inbox.read`, `foreman.lifecycle.events`

**Write tools:** `foreman.tasks.create`, `foreman.tasks.reset`, `foreman.tasks.approve`, `foreman.tasks.block`, `foreman.inbox.send`

Pi slash commands available in agent sessions: `/task`, `/reset`, `/approve`, `/block`

### Backend Boundaries

| Capability | Owner |
|------------|-------|
| Task CRUD, status | Elixir backend (source of truth) |
| Dispatch, capacity, scheduling | Elixir scheduler |
| Git worktree, branches | Node CLI |
| Agent prompts, tool execution | Pi SDK / Node worker |
| Phase reports, logs | Worker → Elixir events |
| PR creation, merge | Node CLI + Elixir reconciliation |

## What Foreman Does

Foreman runs AI engineering work through a managed pipeline:

1. Tasks enter the native PostgreSQL-backed task store.
2. `foreman run` dispatches ready tasks to isolated git worktrees.
3. Workflow phases run in order: exploration, implementation, verification, review, documentation, finalization, PR wait, and merge where configured.
4. Foreman records progress, phase reports, logs, mail, and merge status. In the Elixir backend, domain events are the source of truth and trigger scheduler/watch behavior; projections/read views, including status/log displays, are read models used for display and decisions after events are observed. Worker/Pi SDK tool calls and assistant messages are emitted as ordered worker events before being mirrored into raw logs. Phase reports also emit structured report events so Elixir Overwatch can send compact next-phase Agent Mail steering without depending on report filenames. Elixir overwatch records tool requests/approvals/denials and sends phase-targeted Agent Mail steering nudges when a worker drifts from policy.
5. Completed work is finalized and merged through the configured workflow.

Use Foreman when you want multiple AI agents working safely on one repository without sharing a dirty working tree.

## Local Development Environment

In this repository, `direnv allow` loads Devbox and starts the checked-in Docker Compose stack when you enter the directory. The stack runs one shared pgvector-enabled Postgres container for Foreman and Hindsight: Foreman uses `DATABASE_URL` on `127.0.0.1:55432/foreman` by default, while Hindsight uses the separate `hindsight` database inside the same container.

Useful commands:

```bash
devbox run dev:up          # start shared Postgres + Hindsight
devbox run db:up           # start only Postgres
devbox run hindsight:logs  # tail Hindsight logs
```

Set `FOREMAN_DIRENV_AUTO_COMPOSE=0` before entering the repository to opt out of automatic container startup. Hindsight serves its API at <http://localhost:8888> and control plane at <http://localhost:9999>.

## Core Concepts

### Projects

A project is a repository registered with Foreman. `foreman init` creates the local `.foreman/` config assets and registers the project with the Elixir backend; the CLI does not apply Postgres migrations or connect directly to the database. Commands that act on a project accept `--project <name-or-path>` so you can operate from another directory.

Common commands:

```bash
foreman init --name my-project
foreman project list
foreman status --project my-project
```

### Tasks

Tasks represent units of work. They have a type, priority, status, title, and description. Typical statuses include backlog, ready, in progress, needs attention, and closed. Workflow phases are tracked separately from task status, so custom phase names do not become board columns. When a worker fails, Foreman records an append-only task note with the failed phase and reason so `foreman task show`, `foreman board`, and `foreman watch` can expose actionable context.

```bash
foreman task create --title "Fix flaky retry" --type bug --priority high
foreman task approve <task-id>
foreman task show <task-id>
foreman task list
```

### Workflows

A workflow is a YAML phase sequence. Bundled workflows live in `src/defaults/workflows/`; installed or project-local workflows live under `.foreman/workflows/` or `~/.foreman/workflows/` depending on setup. Workflows can declare `task_type: <type>` so type-based dispatch is owned by the workflow YAML; duplicate `task_type` declarations fail doctor/startup validation. PR and merge behavior is phase-driven: mutating phases can opt into draft PR checkpoints with `checkpointPr: true`, and final PR gates remain explicit `create-pr`, `pr-wait`, and `merge` phases. Top-level `merge:` and `pr:` tags are rejected.

Important phase reports:

| Phase | Report |
|-------|--------|
| Explorer | `EXPLORER_REPORT.md` |
| Developer/Fix | `DEVELOPER_REPORT.md` |
| QA | `QA_REPORT.md` |
| Reviewer | `REVIEW.md` |
| Documentation | `DOCUMENTATION_REPORT.md` |
| Finalize | `FINALIZE_VALIDATION.md`, `FINALIZE_REPORT.md` |
| PR wait | `PR_WAIT_REPORT.md` |
| Merge | `MERGE_REPORT.md` |

Bundled workflows write these reports under the runtime report directory (`~/.foreman/reports/...` via `{task.projectReportsDir}`), not into the repository worktree. The bundled `bug` workflow starts with an explicit read-only Explorer handoff before the editing phase, uses `Grep`, `Glob`, and targeted `Read` discovery, and omits nested delegation tools from fix/remediation phases. Elixir Overwatch rejects Graphify tools in all phases so discovery stays file-based and avoids slow generated worktree artifacts. After editing bundled source workflows or prompts, run `foreman init --force` so installed runtime copies are refreshed before dispatch. `foreman run`, `foreman run --watch`, and worker startup check for stale installed prompts/workflows and abort before scheduling agents when drift is detected. `foreman doctor` reports installed workflow YAML that has drifted from bundled defaults. See [Workflow YAML Reference](./workflow-yaml-reference.md) for configuration details.

### Bundled Foreman Skills

`foreman init` installs bundled Pi skills from `src/defaults/skills` to `~/.pi/agent/skills/`. Foreman worker sessions load the required skill set even when user Pi skills are sandboxed.

Guidance skills include `foreman-elixir-backend` for server/event/projection work, `foreman-workflow-pipeline` for workflow YAML and phase artifacts, `foreman-worker-pi-sdk` for worker/Pi SDK boundaries, `foreman-pipeline-diagnosis` for stuck or missing-artifact triage, `foreman-safe-recovery` for retry/reset/cleanup decisions, `foreman-vcs-backend` for Git/Jujutsu abstraction work, and `foreman-doc-gate` for documentation decisions. See [Skill Integration](skill-integration.md) for impact and packaging details.

### Worktrees

Each dispatched task runs in its own git worktree. This isolates agent edits from your main checkout and from other agents. Avoid manually editing active worktrees unless you are intentionally intervening.

Scheduler-launched worktrees start from the registered project default branch when configured, then fall back to VCS default-branch detection.

### Elixir Backend Roles

During the TRD-2026-014 migration, Foreman has three runtime responsibilities:

- **Node CLI**: operator-facing commands, server auto-start, bearer-authenticated JSON requests, projection rendering, and legacy alias/deprecation warnings.
- **Elixir server**: durable command validation, append-only events, rebuildable projections, run/phase actors, scheduler capacity, VCS/PR gates, inbox/debug/attach views, recovery, metrics, and authorization audit events.
- **Node/Pi workers**: Pi SDK-backed agent execution, worker HTTP protocol starts, ordered event/heartbeat/tool-call/assistant-message/artifact streaming, Foreman-specific typed tools for mail/handoffs/artifacts/validation/blockers/progress/safe commands, authoritative terminal run/task events, and scoped project/run environment metadata. The Elixir launcher records process-exit facts and emits a diagnostic fallback failure only when a worker exits without an authoritative terminal event; raw logs mirror worker events for compatibility/debugging.

For architecture details, deprecated command mappings, and troubleshooting examples, see [Elixir Backend Architecture](./guides/elixir-backend-architecture.md).

### Documentation Gate

Foreman workflows include a documentation phase before finalization. The documentation agent checks whether the task changed user behavior, commands, workflows, prompts, setup, troubleshooting, or operator expectations. It updates relevant docs or records why no doc update was needed in `DOCUMENTATION_REPORT.md`.

Docs that must be considered for every fix or feature:

- `CLAUDE.md`
- `AGENTS.md`
- `README.md`
- `docs/user-guide.md`
- `docs/cli-reference.md`

## Day-to-Day Workflow

### 1. Start or Check the Elixir Server

Foreman uses the Elixir backend for shared project state, database access, and scheduling. Node CLI/client code and Node/Pi workers communicate with Elixir over HTTP commands/projections instead of connecting directly to the database. Workers enqueue/report merge readiness; they do not drain database-backed merge queues themselves.

```bash
foreman server start
foreman server doctor        # validates DB/projections/workers/VCS/providers/integrations
foreman doctor
```

If commands report backend or database issues, run `foreman server doctor` and check [Troubleshooting](./troubleshooting.md). `foreman server status` shows `MIX_ENV`, event store, and project store for the active server.

After cutover, legacy TS delegation is removed and `foreman daemon start|restart` is blocked so the Node scheduler cannot run beside the Elixir scheduler. The Elixir scheduler ticks every 5 seconds, automatically claims dispatchable `ready` tasks within capacity, and launches the Node/Pi worker bridge. `MIX_ENV=test` uses port `14766` by default and refuses user port `4766` or non-temp storage unless the dangerous overrides `FOREMAN_ALLOW_TEST_PORT_COLLISION=1` / `FOREMAN_ALLOW_TEST_PERSISTENT_STORAGE=1` are set.

```bash
foreman server stop
```

The doctor output includes operational metrics: phase duration timers, retry/failure/recovery counters, worker restart counts, and projection lag. `foreman server status` distinguishes the durable event store, persisted/in-memory projection store, and project config store. With `FOREMAN_SERVER_EVENT_STORE_ADAPTER=postgres` and `DATABASE_URL`, project/task/run/inbox read models persist in Postgres projection tables; term mode keeps projections in memory and rebuilds from the term event log. If server auth is enabled, set `FOREMAN_SERVER_AUTH_TOKEN` before calling doctor/metrics endpoints. Run debug views surface the first inconsistent event transition when a status anomaly appears and include timeline payload/file-change fields for Cockpit fallback rendering.

Troubleshooting sequence for Elixir-backed state:
1. Check whether the expected durable event exists (`RunStarted`, `PhaseCompleted`, `WorkerRestarted`, `AuthorizationChecked`, etc.).
2. Check projection lag in `foreman server doctor` or `/api/v1/metrics`; rebuild/restart projections if lag does not catch up.
3. For recovery, read the observation event first (`ExternalWorkerObserved`), then the resolution event (`WorkerReattached`, `WorkerRestarted`, or `NeedsOperator`).

Security behavior:
- Worker environments are scoped to the project/run. Explicit project and run secret maps are merged after host environment filtering, and forbidden variables such as `FOREMAN_SERVER_AUTH_TOKEN`, `AWS_*`, `GITHUB_*`, `NPM_*`, `SSH_*`, and `DATABASE_*` are stripped.
- Exposing the Elixir HTTP server beyond loopback requires `FOREMAN_SERVER_AUTH_TOKEN`; clients must send `Authorization: Bearer <token>`.
- Destructive server commands record `AuthorizationChecked` and `AuditRecorded` events for auditability.

### 2. Plan Larger Work

For larger features, generate planning artifacts before creating implementation tasks. The legacy `foreman plan <description>` pipeline still runs the local PRD → TRD flow. The server-backed planning subcommands send PRD/TRD planning to the local Elixir orchestration server:

```bash
foreman plan prd "Build a planning system" --project my-project --output-dir docs/PRD
foreman plan trd docs/PRD/PRD-example.md --project my-project --output-dir docs/TRD
```

Use `foreman server doctor` first if the Elixir server is not already running. `--project` selects the registered project and `--output-dir` selects where the planning artifact should be written.

### 3. Migrate Legacy State

During the Elixir backend migration, operators can import a prebuilt TypeScript-era migration JSON payload into the Elixir event store. The CLI no longer builds that payload by reading Postgres directly:

```bash
foreman import --to-elixir --file migration.json
foreman import --to-elixir --from-node --project foreman
```

The import maps legacy projects, tasks, runs, workflows, inbox messages, and config to durable events/projections so historical runs remain readable. `--from-node` is deprecated because the CLI no longer reads Node/Postgres state directly. After importing, `foreman board --project <name>` reads and mutates task state through Elixir without the Node daemon socket.

```bash
foreman status
```


### 4. Create a Task

Write a task with enough context for an agent to execute without guessing.

```bash
foreman task create \
  --title "Add cooldown retry for transient CLI review failures" \
  --type feature \
  --priority high \
  --description "When CodeRabbit reports a transient rate limit, schedule retry after cooldown instead of terminal failure."
```

Natural-language task generation was removed after the Elixir cutover; create structured tasks with `--title` and `--description`.

Good task descriptions include:

- Problem statement
- Expected behavior
- Constraints and non-goals
- Acceptance criteria
- Known files or commands, if relevant

### 5. Approve the Task

Tasks usually start in backlog. Approve when ready for dispatch. Worker prompts receive task title, type, priority, and description from the Elixir backend; Node/Pi workers do not open a direct database pool.

```bash
foreman task approve <task-id>
```

### 6. Dispatch Work

```bash
foreman run --project my-project
```

Only dependency-unblocked `ready` tasks dispatch. Ready tasks with open blockers stay queued until the blocker closes. The Elixir scheduler uses the same queue and writes dispatch/skip summaries to its events/logs so stalled cycles are diagnosable.

Useful variants:

```bash
foreman run --dry-run             # Check Elixir server availability without ticking
foreman run --no-watch            # Tick once and exit
```

Bundled workflows use a deterministic builtin finalize step: Foreman commits, conditionally rebases/tests when the target moved after QA, pushes `foreman/<task-id>`, retries non-fast-forward branch publication with `--force-with-lease`, and writes finalize reports without asking an LLM to drive git. Optional `FOREMAN_MAX_PIPELINE_*` budgets can stop runaway wall-clock, cost, tool-call, or retry/review loops.

### 7. Monitor Progress

```bash
foreman status
foreman watch
foreman board
foreman logs <run-id>
foreman attach <run-id>
```

Use `foreman watch` as the canonical live cockpit. From the same full-height TTY session you can move through the task/run selector, inbox timeline, status/workflow flow chart, board context, and detail tabs for logs, reports, and files. `foreman inbox`, `foreman status --live`, and TTY `foreman board` open the same cockpit with different initial views; non-TTY output, `foreman inbox --non-interactive`, `foreman status --json`, `foreman status --watch`, `foreman watch --no-watch`, and filtered/all board paths remain scriptable. The cockpit phase rail follows the selected run or task's workflow phase order and shows per-phase retry counts; tasks without active runs display phases from workflow YAML as pending (including `pr-wait` and `merge`). The status view shows ordered phase nodes, retry arrows, current failure/error text, artifacts, and active phase activity. Use `/` for search, `1/2/3` for active/attention/all scopes, `!`/`p`/`d` for failed/PR/dirty-worktree filters, and `a` or `:` for the action palette. Palette reset requires explicit `y` confirmation and then runs `foreman reset` for the selected task; non-reset actions still print copy/manual command text.

### 8. Triage Failures

Failed, stuck, blocked, conflict, and review statuses appear as needs-attention work. Start with artifacts before retrying.

Recommended order:

1. Read the latest pipeline report.
2. Read the failed phase report.
3. Identify whether the failure is transient, implementation-related, merge-related, or infrastructure-related.
4. Reset or retry only after the cause is understood.

```bash
foreman logs <run-id>
foreman retry <task-id> --dry-run
foreman retry <task-id> --dispatch
```

Avoid mass retrying unless failures are known transient and the root cause is external.

### 9. Review and Merge

Merge-capable workflows checkpoint draft PRs after successful mutating phases, then wait for PR checks/review, require zero failed checks plus a briefly stable ready state, and merge through explicit `create-pr`, `pr-wait`, and `merge` phases. The final `create-pr` phase refreshes the existing draft and marks it ready instead of creating a second PR. The merge gate is the final PR readiness authority and waits again if GitHub surfaces a late pending check. If PR wait or merge fails, inspect `PR_WAIT_REPORT.md` or `MERGE_REPORT.md`; configured workflows route retryable failures to targeted remediation phases: CI/CD check failures to `cicd-developer`, CodeRabbit findings to `cr-developer`, merge conflicts to `merge-resolver`, and unknown failures to `developer`/the workflow fallback.

The Elixir server also reconciles recorded GitHub PR state in the background. If GitHub reports a recorded PR as merged, Foreman records the merge metadata on the run and marks the associated task `merged`, matching the refinery post-merge task state. If GitHub reports the PR closed without merge, Foreman records the run PR state as closed and closes the associated task.


```bash
foreman merge
foreman pr
```

## Operating the Board

`foreman board` on a TTY opens the unified cockpit in board view. Use it when you want board context beside inbox and status details. For legacy/scriptable board rendering, use non-TTY output, `--all`, or `--filter`.

The legacy board interaction model still applies when Foreman uses the non-cockpit board path (`--filter`, `--all`, or non-TTY): `h/l` columns, status cycling, `R` ready, close/edit keys, and task creation remain there.

Common cockpit keys:

| Key | Action |
|-----|--------|
| `j` / `k` | Move within the task/run selector |
| `i` | Inbox timeline view |
| `s` | Status/workflow view |
| `b` | Board context view |
| `m` / `e` / `l` / `r` / `f` | Messages, events, logs, reports, files tabs; messages render newest-first with local `mm/dd hh:mm`, sender, receiver, and message columns |
| `/` | Search tasks, runs, messages, events, and report paths |
| `1` / `2` / `3` | Active, attention, all scopes |
| `!` / `p` / `d` | Failed, has PR, dirty worktree filters |
| `a` / `:` | Action palette; reset asks for `y` confirmation and executes `foreman reset`; other entries print copy/manual commands |
| `q` / `Esc` | Quit |

## Retry and Cleanup Guidance

Use retry and doctor cleanup surgically.

- Use `foreman reset <task-id>` when active work is stale, a closed/completed task should be reopened, or a task must pick up new Foreman runtime behavior; it stops active workers when present, closes any open/draft PR recorded for the task before deleting the remote branch, marks prior active runs failed with the reset reason, removes stale task worktrees, local/origin `foreman/<task>` branches, and prior run logs/reports, clears run linkage, resets the task to ready, and dispatches it again. Merged tasks remain terminal.
- Use `foreman retry <task-id> --dispatch` when the latest failure is safe to rerun.
- Use `foreman retry <task-id>` for retryable failed/stuck run recovery.
- Use `foreman doctor --dry-run` to preview cleanup of zombie/stale runs and merged/orphaned worktrees.
- Use `foreman doctor --fix` for safe cleanup after review, including reinstalling missing/stale prompt and workflow runtime files; it does not replace inspecting valuable in-progress work.
- Use `foreman abandon <task-or-run-id> --reason "..."` when obsolete work should not land; preview with `--dry-run` and opt into branch deletion with `--delete-branch --force`.
- Use `foreman abandon --missing-branches --dry-run` to preview bulk cleanup of completed runs whose `foreman/<task>` branch is already gone, then rerun without `--dry-run` to clear repeated merge warnings.
- Use `foreman clean-state --dry-run` when you want to reset Foreman to a clean operator state by dropping stale/obsolete non-active work; apply with `--force`, and add `--delete-branches`/`--delete-origin-branches` only when branch deletion is intended.

Transient failures include provider rate limits, provider overloads (`529 overloaded_error`), temporary network failures, and unavailable external CLIs. Max-turn failures are treated as expensive human-review signals; inspect the diff/log before retrying.

### Direct Task Execution with `foreman run task`

Operator use of `foreman run task` was removed after the Elixir cutover. Use scheduler-backed `foreman run` for ready work or `foreman retry` for retry flows instead.

## Documentation Expectations

Every user-visible change should update docs in the same task. Examples:

| Change | Docs to consider |
|--------|------------------|
| New command or flag | `docs/cli-reference.md`, `docs/user-guide.md`, `README.md` |
| Workflow YAML option | `docs/workflow-yaml-reference.md`, `docs/user-guide.md` |
| Agent behavior/prompt contract | `CLAUDE.md`, `AGENTS.md`, `docs/user-guide.md` |
| Setup/install behavior | `README.md`, `docs/user-guide.md`, `docs/troubleshooting.md` |
| Operational failure mode | `docs/user-guide.md`, `docs/troubleshooting.md` |

If no docs need updating, `DOCUMENTATION_REPORT.md` must explain why.

## Safety Rules

- Keep the controller workspace clean before rerunning important tasks.
- Commit or patch-export important local changes before reset/cleanup; pushed draft PR checkpoints are safe to keep while local worktrees are removed, but reset closes the old PR before deleting its remote branch.
- Prefer targeted retries over bulk retries.
- Inspect reports before changing task state.
- Do not manually mutate active worktrees unless you intend to take ownership of that run.
- Keep workflow changes synchronized between bundled defaults and active project overrides when both are in use.

## Troubleshooting Quick Links

- Command syntax: [CLI Reference](./cli-reference.md)
- Workflow config: [Workflow YAML Reference](./workflow-yaml-reference.md)
- VCS backends: [VCS Configuration Guide](./guides/vcs-configuration.md)
- Troubleshooting: [Troubleshooting Guide](./troubleshooting.md)
