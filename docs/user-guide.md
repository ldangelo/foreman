# Foreman User Guide

This guide explains how to use Foreman day to day. For exact flags and command syntax, see the [CLI Reference](./cli-reference.md).

## What Foreman Does

Foreman runs AI engineering work through a managed pipeline:

1. Tasks enter the native PostgreSQL-backed task store.
2. `foreman run` dispatches ready tasks to isolated git worktrees.
3. Workflow phases run in order: exploration, implementation, verification, review, documentation, finalization, PR review, and merge where configured.
4. Foreman records progress, phase reports, logs, mail, and merge status. In the Elixir backend, domain events are the source of truth and trigger scheduler/watch behavior; projections/read views, including status/log displays, are read models used for display and decisions after events are observed. During long phases, overwatch monitors heartbeat movement and sends phase-targeted Agent Mail nudges when an agent appears idle.
5. Completed work is finalized and merged through the configured workflow.

Use Foreman when you want multiple AI agents working safely on one repository without sharing a dirty working tree.

## Core Concepts

### Projects

A project is a repository registered with Foreman. `foreman init` applies pending packaged Postgres migrations before registration, so normal project setup keeps the database schema current. Commands that act on a project accept `--project <name-or-path>` so you can operate from another directory.

Common commands:

```bash
foreman init --name my-project
foreman project list
foreman status --project my-project
```

### Tasks

Tasks represent units of work. They have a type, priority, status, title, and description. Typical statuses include backlog, ready, in progress, needs attention, and closed. When a worker fails, Foreman records an append-only task note with the failed phase and reason so `foreman task show`, `foreman board`, and `foreman watch` can expose actionable context.

```bash
foreman task create --title "Fix flaky retry" --type bug --priority high
foreman task approve <task-id>
foreman task show <task-id>
foreman task list
```

### Workflows

A workflow is a YAML phase sequence. Bundled workflows live in `src/defaults/workflows/`; installed or project-local workflows live under `.foreman/workflows/` or `~/.foreman/workflows/` depending on setup.

Important phase reports:

| Phase | Report |
|-------|--------|
| Explorer | `EXPLORER_REPORT.md` |
| Developer/Fix | `DEVELOPER_REPORT.md` |
| QA | `QA_REPORT.md` |
| Reviewer | `REVIEW.md` |
| Documentation | `DOCUMENTATION_REPORT.md` |
| Finalize | `FINALIZE_VALIDATION.md`, `FINALIZE_REPORT.md` |
| PR wait/review | `PR_WAIT_REPORT.md`, `PR_REVIEW_REPORT.md` |
| Merge | `MERGE_REPORT.md` |

Bundled workflows write these reports under the runtime report directory (`~/.foreman/reports/...` via `{task.projectReportsDir}`), not into the repository worktree. See [Workflow YAML Reference](./workflow-yaml-reference.md) for configuration details.

### Worktrees

Each dispatched task runs in its own git worktree. This isolates agent edits from your main checkout and from other agents. Avoid manually editing active worktrees unless you are intentionally intervening.

### Elixir Backend Roles

During the TRD-2026-014 migration, Foreman has three runtime responsibilities:

- **Node CLI**: operator-facing commands, server auto-start, bearer-authenticated JSON requests, projection rendering, and legacy alias/deprecation warnings.
- **Elixir server**: durable command validation, append-only events, rebuildable projections, run/phase actors, scheduler capacity, VCS/PR gates, inbox/debug/attach views, recovery, metrics, and authorization audit events.
- **Node/Pi workers**: Pi SDK-backed agent execution, worker HTTP protocol starts, ordered event/heartbeat/log/artifact streaming, and scoped project/run environment metadata.

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

Foreman uses the Elixir backend for shared project state and scheduling.

```bash
foreman server start
foreman server doctor        # validates DB/projections/workers/VCS/providers/integrations
foreman doctor
```

If commands report backend or database issues, run `foreman server doctor` and check [Troubleshooting](./troubleshooting.md).

After cutover, legacy TS delegation is removed and `foreman daemon start|restart` is blocked so the Node scheduler cannot run beside the Elixir scheduler. The Elixir scheduler ticks every 5 seconds, automatically claims dispatchable `ready` tasks within capacity, and launches the Node/Pi worker bridge.

```bash
foreman server stop
```

The doctor output includes operational metrics: phase duration timers, retry/failure/recovery counters, worker restart counts, and projection lag. If server auth is enabled, set `FOREMAN_SERVER_AUTH_TOKEN` before calling doctor/metrics endpoints. Run debug views surface the first inconsistent event transition when a status anomaly appears.

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

During the Elixir backend migration, operators can import a TypeScript-era migration JSON payload into the Elixir event store:

```bash
foreman import --to-elixir --file migration.json
foreman import --to-elixir --from-node --project foreman
```

The import maps legacy projects, tasks, runs, workflows, inbox messages, and config to durable events/projections so historical runs remain readable. `--from-node` snapshots the selected Node/Postgres project into Elixir. After importing, `foreman board --project <name>` reads and mutates task state through Elixir without the Node daemon socket.

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

The legacy Node/beads natural-language generator was removed after the Elixir cutover; create structured tasks with `--title` and `--description`.

Good task descriptions include:

- Problem statement
- Expected behavior
- Constraints and non-goals
- Acceptance criteria
- Known files or commands, if relevant

### 5. Approve the Task

Tasks usually start in backlog. Approve when ready for dispatch. During the Elixir cutover, a task created only in Elixir is mirrored into the Postgres worker store when the worker bridge starts, so worker prompts receive the task title, type, priority, and description instead of placeholder metadata.

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

Bundled workflows use a deterministic builtin finalize step: Foreman commits, conditionally rebases/tests when the target moved after QA, pushes `foreman/<task-id>`, and writes finalize reports without asking an LLM to drive git. Optional `FOREMAN_MAX_PIPELINE_*` budgets can stop runaway wall-clock, cost, tool-call, or retry/review loops.

### 7. Monitor Progress

```bash
foreman status
foreman board
foreman watch
foreman logs <run-id>
foreman attach <run-id>
```

Use `foreman board` for kanban-style task triage. Use `foreman inbox --task <id>` for event-projected agent messages (including message contents) plus current lifecycle/terminal events; add `--events` to see phase completions, retries, verdicts, and overwatch nudges. Use `foreman status` or `foreman watch` when you need execution health and active run state. Use `foreman mcp --transport stdio` for local agent integrations, or `foreman mcp --transport http` when Foreman runs remotely from CLI/client sessions; MCP uses the Elixir backend only. In Pi, use slash commands like `/foreman-smoke`, `/foreman-tasks`, `/foreman-task <id>`, `/foreman-approve`, `/foreman-runs`, `/foreman-inbox`, `/foreman-events`, `/foreman-scheduler`, and `/foreman-tick` for common MCP-backed operator checks and approvals. For stuck runs, use `foreman retry` or Elixir recovery workflows.

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

Auto-merge workflows create PRs, wait for PR checks/review, require the ready state to remain stable briefly, and merge through the configured merge phase. The merge gate also waits again if GitHub surfaces a late pending check. If merge fails, inspect `MERGE_REPORT.md` and any PR review artifacts.

```bash
foreman merge
foreman pr
```

## Operating the Board

`foreman board` is the primary interactive task board.

Common keys:

| Key | Action |
|-----|--------|
| `h` / `l` | Move between columns |
| `j` / `k` | Move within a column |
| `Enter` | Show task details |
| `r` | Refresh board from store |
| `R` | Mark selected task ready |
| `s` / `S` | Cycle status forward/backward |
| `c` / `C` | Close task |
| `e` / `E` | Edit task in editor |
| `n` | Create task |
| `?` | Help |
| `q` | Quit |

The board also monitors agent inbox updates. When a new inbox message arrives for a run, the board reloads only the task tied to that run and moves that card if its status changed; it does not refresh the entire board. `open` tasks appear in Backlog, `closed`/`merged` tasks appear in Closed, and unknown statuses appear in Needs Attention so they are visible for triage. Press `r` for a full manual refresh. The header shows an animated `refreshing…` indicator while full reload is in progress, then a `refreshed <time>` marker when the latest event-driven or manual update finishes. For exact options and keybindings, see [CLI Reference](./cli-reference.md#foreman-board).

## Retry and Cleanup Guidance

Use retry and doctor cleanup surgically.

- Use `foreman reset <task-id>` when active work is stale or must pick up new Foreman runtime behavior; it stops the worker, abandons the current run while keeping the task, resets the task to ready, and dispatches it again.
- Use `foreman retry <task-id> --dispatch` when the latest failure is safe to rerun.
- Use `foreman retry <task-id>` for retryable failed/stuck run recovery.
- Use `foreman doctor --dry-run` to preview cleanup of zombie/stale runs and merged/orphaned worktrees.
- Use `foreman doctor --fix` for safe cleanup after review; it does not replace inspecting valuable in-progress work.
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
- Commit or patch-export important local changes before reset/cleanup.
- Prefer targeted retries over bulk retries.
- Inspect reports before changing task state.
- Do not manually mutate active worktrees unless you intend to take ownership of that run.
- Keep workflow changes synchronized between bundled defaults and active project overrides when both are in use.

## Troubleshooting Quick Links

- Command syntax: [CLI Reference](./cli-reference.md)
- Workflow config: [Workflow YAML Reference](./workflow-yaml-reference.md)
- VCS backends: [VCS Configuration Guide](./guides/vcs-configuration.md)
- Troubleshooting: [Troubleshooting Guide](./troubleshooting.md)
