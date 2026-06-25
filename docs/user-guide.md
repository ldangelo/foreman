# Foreman User Guide

This guide explains how to use Foreman day to day. For exact flags and command syntax, see the [CLI Reference](./cli-reference.md).

## What Foreman Does

Foreman runs AI engineering work through a managed pipeline:

1. Tasks enter the native PostgreSQL-backed task store.
2. `foreman run` dispatches ready tasks to isolated git worktrees.
3. Workflow phases run in order: exploration, implementation, verification, review, documentation, finalization, PR review, and merge where configured.
4. Foreman records progress, phase reports, logs, mail, and merge status.
5. Completed work is finalized and merged through the configured workflow.

Use Foreman when you want multiple AI agents working safely on one repository without sharing a dirty working tree.

## Core Concepts

### Projects

A project is a repository registered with Foreman. Commands that act on a project accept `--project <name-or-path>` so you can operate from another directory.

Common commands:

```bash
foreman init --name my-project
foreman project add owner/repo --name my-project
foreman project list
foreman project edit <project-id> --default-branch dev
foreman status --project my-project
```

The project default branch is the base for newly created task worktrees and finalization targets. In Elixir mode, `foreman project add` clones with GitHub CLI into `~/.foreman/projects/<project-id>` and registers through Elixir; `list`, `edit`, and `remove` read/write the Elixir project projection; `remove` archives the project.

### Tasks

Tasks represent units of work. They have a type, priority, status, title, and description. Typical statuses include backlog, ready, in progress, needs attention, and closed. When a worker fails, Foreman records an append-only task note with the failed phase and reason so `foreman task show`, `foreman board`, and `foreman watch` can expose actionable context.

```bash
foreman task create --title "Fix flaky retry" --type bug --priority high
foreman task approve <task-id>
foreman task show <task-id>
foreman task list
```

### Workflows

A workflow is a YAML phase sequence. Each phase names a reusable `action` (`prompt-agent`, `command-agent`, `bash`, `qlty`, `finalize`, PR gate actions, or `merge`) so Foreman's engine stays generic while YAML defines the steps. Bundled workflows live in `src/defaults/workflows/`; installed or project-local workflows live under `.foreman/workflows/` or `~/.foreman/workflows/` depending on setup. Workflows can declare `task_type: <type>` so type-based dispatch is owned by the workflow YAML; duplicate `task_type` declarations fail doctor/startup validation.

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

Bundled workflows write these reports under the runtime report directory (`~/.foreman/reports/...` via `{task.projectReportsDir}`), not into the repository worktree. Each phase attempt is also preserved as `REPORT.attempt-N.md`, while the canonical report path remains the latest attempt. `RETRY_ATTEMPTS.md` summarizes preserved attempts. See [Workflow YAML Reference](./workflow-yaml-reference.md) for configuration details.

### Worktrees

Each dispatched task runs in its own git worktree. This isolates agent edits from your main checkout and from other agents. Avoid manually editing active worktrees unless you are intentionally intervening.

### Elixir Backend Roles

During the TRD-2026-014 migration, Foreman has three runtime responsibilities:

- **Node CLI**: operator-facing commands, server auto-start, bearer-authenticated JSON requests, projection rendering, and legacy alias/deprecation warnings.
- **Elixir server**: durable command validation, append-only events, rebuildable projections, run/phase actors, scheduler capacity, VCS/PR gates, inbox/debug/attach views, recovery, metrics, and authorization audit events.
- **Node/Pi workers**: Pi SDK-backed agent execution, worker HTTP protocol starts, ordered event/heartbeat/log/artifact streaming, and scoped project/run environment metadata.

For architecture details, deprecated command mappings, and troubleshooting examples, see [Elixir Backend Architecture](./guides/elixir-backend-architecture.md).

### Documentation Gate

Foreman workflows now declare dispatcher workspace actions (`prepare-worktree`, `setup-workspace`, `write-task-context`) before worker phases. Workflow YAML resolves from explicit path, project `.foreman/workflows` (`.yaml|.yml`), global `~/.foreman/workflows` (`.yaml|.yml`), then bundled defaults; project-relative explicit paths must stay inside the project root, and project workflows also participate in `task_type` routing. Project action modules in `.foreman/actions/*.js|*.mjs|*.ts` or global modules in `~/.foreman/actions/*.js|*.mjs|*.ts` can override bundled action behavior without rebuilding Foreman; project actions win, and action modules are bundled with esbuild before runtime load so JS/MJS actions may import TS helpers kept outside the actions directory (every direct `.js`/`.mjs`/`.ts` file in `.foreman/actions` or `~/.foreman/actions` is treated as an action). Use `foreman workflows list|show|validate|install|create` to inspect, validate, install bundled YAML, or create workflow stubs (`--global` targets `~/.foreman/workflows`); validation also flags unsafe workflow filenames/names, duplicate `.yaml`/`.yml` variants, broken/duplicate phase references, invalid numeric controls, and malformed or duplicate `task_type` declarations. Use `foreman actions list|show|validate|install|create` to inspect, validate, install bundled action stubs, or create custom stubs (`--global` targets `~/.foreman/actions`); validation flags unsafe names (only letters, numbers, `.`, `_`, `-`, with at least one letter/number), JS/TS syntax or import errors, non-function exports, duplicate `.js`/`.mjs`/`.ts` variants, and unresolved workflow action refs. Generated stubs for known builtin/workspace actions call `ctx.internal.runBuiltin()` by default; edit any stub and call `ctx.internal.runBuiltin()` to wrap default behavior. Custom actions receive `ctx.capabilities` and `ctx.requireCapability(name)` so they can fail fast when the workflow omitted expected host access such as `exec`, `mail`, or `vcs`; Foreman also gates worker helper access for `mail`, `vcs`, and `task-store` capabilities; known privileged builtin/dispatcher actions merge default capabilities with declared additions. The bundled `qlty` action runs `qlty check`, requires the qlty CLI from https://qlty.sh/ on `PATH`, writes `QLTY_REPORT.md`, and bundled developer workflows retry Developer when qlty fails. Before any retry or non-foreman artifact forward, Foreman writes a normalized target input file in the run report directory (for example `DEVELOPER_TASK.md`, `QA_TASK.md`, or `REVIEWER_TASK.md`) with the source phase, source artifact, failure, retry attempt, and feedback content, so target prompts do not need to know every upstream report filename. Workflows include a documentation phase after finalization and before PR creation. The documentation agent checks whether the task changed user behavior, commands, workflows, prompts, setup, troubleshooting, or operator expectations. It updates relevant docs or records why no doc update was needed in `DOCUMENTATION_REPORT.md`. Explorer also writes an Acceptance Contract in `EXPLORER_REPORT.md`; phases with `contract.policy.acceptanceCoverage` must carry and address those criteria before Foreman accepts a passing phase. If a PASS artifact misses declared coverage, Foreman records phase failure/retry events with the override reason. Runtime preflight flags stale project/global prompt overrides when they are missing required acceptance-contract markers.

Docs that must be considered for every fix or feature:

- `CLAUDE.md`
- `AGENTS.md`
- `README.md`
- `docs/user-guide.md`
- `docs/cli-reference.md`

## Day-to-Day Workflow

### 1. Start or Check the Daemon

Foreman uses PostgreSQL and usually runs through the daemon for shared project state.

```bash
foreman daemon status
foreman daemon start
foreman doctor
```

If commands report daemon or database issues, run `foreman doctor` and check [Troubleshooting](./troubleshooting.md).

Elixir backend work uses a separate local server. Elixir is the default backend after cutover; this disables legacy TS delegation and blocks `foreman daemon start|restart` so the Node scheduler cannot run beside the Elixir scheduler. The Elixir scheduler ticks every 5 seconds, reconciles active runs whose worker logs contain terminal completion/failure markers, automatically claims dispatchable `ready` tasks within capacity, and launches the Node/Pi worker bridge.

```bash
foreman server doctor        # auto-starts and validates DB/projections/workers/VCS/providers/integrations
foreman server stop
```

The doctor output includes operational metrics: phase duration timers, retry/failure/recovery counters, worker restart counts, and projection lag. If server auth is enabled, set `FOREMAN_SERVER_AUTH_TOKEN` before calling doctor/metrics endpoints. Run debug views surface the first inconsistent event transition when a status anomaly appears.

Troubleshooting sequence for Elixir-backed state:
1. Check whether the expected durable event exists (`RunStarted`, `PhaseCompleted`, `WorkerRestarted`, `AuthorizationChecked`, etc.).
2. Check projection lag in `foreman server doctor` or `/api/v1/metrics`; rebuild/restart projections if lag does not catch up.
3. For recovery, read the observation event first (`ExternalWorkerObserved`), then the resolution event (`WorkerReattached`, `WorkerRestarted`, or `NeedsOperator`).

Security behavior:
- Worker environments are scoped to the project/run. Explicit project and run secret maps are merged after host environment filtering, and forbidden variables such as `FOREMAN_SERVER_AUTH_TOKEN`, `AWS_*`, `GITHUB_*`, `NPM_*`, `SSH_*`, and `DATABASE_*` are stripped. Workers also do not inherit `FOREMAN_SERVER_HTTP_ENABLED`, so targeted Elixir tests do not try to bind the operator server port.
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

The import maps legacy projects, tasks, runs, workflows, inbox messages, and config to durable events/projections so historical runs remain readable. `--from-node` snapshots the selected Node/Postgres project into Elixir. After importing, `FOREMAN_BACKEND=elixir foreman board --project <name>` reads and mutates task state through Elixir without the Node daemon socket. If migration is not complete, compatibility mode can delegate supported commands to the legacy TS CLI:

```bash
FOREMAN_LEGACY_COMPATIBILITY_MODE=1 \
FOREMAN_LEGACY_TS_BIN=/path/to/legacy/foreman \
foreman status
```

Delegation supports legacy-only command paths only when `FOREMAN_BACKEND=node` is set for explicit legacy operation. Under the Elixir backend, `foreman task create|list|show|approve|update|note|close|import` route through Elixir task commands/projections; `task create --from-text` creates Elixir-backed native tasks, and dependency add/list/remove are command/projection-backed.

### 4. Create a Task

Write a task with enough context for an agent to execute without guessing.

```bash
foreman task create \
  --title "Add cooldown retry for transient CLI review failures" \
  --type feature \
  --priority high \
  --description "When CodeRabbit reports a transient rate limit, schedule retry after cooldown instead of terminal failure."
```

You can also generate task(s) from a natural-language description (or a file path) with LLM parsing:

```bash
foreman task create --from-text "Fix the login timeout bug"
foreman task create --from-text docs/issue.md --dry-run
```

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

Only dependency-unblocked `ready` tasks dispatch. Ready tasks with open blockers stay queued until the blocker closes. The daemon uses the same queue and writes dispatch/skip summaries to its logs so stalled cycles are diagnosable.

Useful variants:

```bash
foreman run --bead <task-id>      # Dispatch one task
foreman run --max-agents 2        # Limit concurrency
foreman run --dry-run             # Preview dispatch
foreman run --no-watch            # Dispatch and exit
foreman run --yes                 # Auto-confirm run prompts for scripts/non-interactive use
foreman run --workflow quick      # Use the quick workflow (no explorer/reviewer phases)
foreman run --workflow tdd        # Opt into Red/Test Review before Developer
```

Bundled `default`, `feature`, and `bug` workflows now use the fast path by default: Explorer/fix hands off directly to Developer, then QA/review/finalize validate the patch. TDD is opt-in via `--workflow tdd`, `workflow:tdd`, or task type `tdd`; that workflow inserts `test-red` and `test-review` before Developer, caps Red to a few focused tests, and retries Red once. Provider-backed prompt phases opt into cooldown retry for transient rate-limit/overload errors. Prompt-backed phases also enable phase overwatch: Foreman tracks tool calls, validates required reports, blocks known drift patterns such as Developer test runs or QA broad full-suite commands, steers runaway work through blocked tool-call messages, treats valid-artifact stop instructions as non-error terminal guidance, and can continue after a max-turn stop when the required artifact is already valid. QA/finalize own test execution. Developer docs gates now accept either a real docs diff or explicit self-check evidence explaining why no docs change is needed. Optional `FOREMAN_MAX_PIPELINE_*` budgets can still stop runaway wall-clock, cost, tool-call, or retry/review loops.

### 7. Monitor Progress

```bash
foreman status
foreman board
foreman watch
foreman runs
foreman logs <run-id>
foreman logs <run-id> --compact       # Compact/plain tail without message_update noise
foreman attach <run-id>
foreman metrics
foreman metrics --costs --since 2026-06-01
```

Use `foreman board` for kanban-style task triage. Use `foreman task create|list|show|approve|update|note|close` for scriptable Elixir-backed task management; created tasks use the standard compact project-prefixed ID format and appear on the board. Use `foreman inbox --task <id>` for run messages plus current lifecycle/terminal events. Use `foreman status` or `foreman watch` when you need execution health and active run state. Use `foreman runs` to see a traceability dashboard listing all active runs with their phase, elapsed time, last activity, and stuck/fatal indicators — useful for observing scheduler/worker activity even when inbox messages are sparse. Add `--verbose` to show cost, turns, and log/report paths; add `--stuck` to filter to likely-stuck runs. Use `foreman metrics` for a per-phase pipeline observability view showing pass/fail rates, retry counts, average turns/cost, top failure reasons, stuck tasks by reason, recent bottlenecks, aggregate retry attempts, circuit breaker hits, QA environment-blocked outcomes, and blocked retry reasons by phase; add `--json` for `counters.circuit_breaker_hits`, `counters.qa_environment_blocked`, and `retry_details` fields; add `--costs` or cost filters such as `--since`, `--phase`, `--agent`, or `--task-type` to view task-store cost/token metrics in human-readable, `--json`, or `--compact` form. Use `foreman mcp --transport stdio` for local agent integrations, or `foreman mcp --transport http` when Foreman runs remotely from CLI/client sessions; MCP uses the Elixir backend only. In Pi, use slash commands like `/foreman-smoke`, `/foreman-tasks`, `/foreman-task <id>`, `/foreman-approve`, `/foreman-runs`, `/foreman-logs [run-id]`, `/foreman-inbox`, `/foreman-events`, `/foreman-scheduler`, and `/foreman-tick` for common MCP-backed operator checks and approvals. To detect and reset stuck runs, use `foreman reset --detect-stuck`.


### 8. Triage Failures

Failed, stuck, blocked, conflict, and review statuses appear as needs-attention work. Start with artifacts before retrying.

Recommended order:

1. Read the latest pipeline report.
2. Read the failed phase report.
3. Identify whether the failure is transient, implementation-related, merge-related, or infrastructure-related.
4. Reset or retry only after the cause is understood.

```bash
foreman logs <run-id>
foreman reset --bead <task-id> --dry-run
foreman retry <task-id> --dispatch
```

Avoid mass retrying unless failures are known transient and the root cause is external. QA failures that say `report missing test command evidence` mean `QA_REPORT.md` did not include `Command run:` plus `Test suite: X passed, Y failed`; rerun after the QA prompt/report is corrected.

Developer and QA phases are intentionally handoff-driven. Explorer performs code discovery and writes verified edit/verification targets; Developer should execute that plan without broad repo search, and QA should verify the changed files with targeted commands only. Before QA, Foreman gates Developer completion against the git diff, claimed files in `DEVELOPER_REPORT.md`, `Self-Check Evidence`, docs/test requirements inferred from the task text, and `npx tsc --noEmit` when TS/JS files changed. Worker phase starts/completions are mirrored into the Elixir lifecycle event stream so inbox/board/watch can surface post-dispatch activity even when agent mail is sparse. Reviewer is also expected to judge the current Elixir/MCP/read-model path during the cutover, not require legacy Postgres/native TS storage changes unless the task explicitly targets them. During the Elixir cutover, runtime/state/MCP/activity-feed work should target the Elixir event/projection path plus current CLI/read-model consumers, not legacy Postgres/native TS storage unless explicitly requested. Broad discovery commands are blocked by phase overwatch in Developer/QA. If QA or Review still fails after retries, Foreman stops the pipeline instead of proceeding to finalize with invalid/no changes. Retry budgets are charged to the failing/source phase, not the retry target: QA can retry Developer 3 times, and Finalize can retry Developer 6 times. Retry targets read their normalized `{PHASE}_TASK.md` input rather than hardcoding every upstream artifact name.

### 9. Review and Merge

Auto-merge workflows create PRs, wait for PR checks/review, require the ready state to remain stable briefly, and merge through the configured merge phase. The merge gate also waits again if GitHub surfaces a late pending check. If the final gate cannot authenticate to GitHub, Foreman writes a failing `MERGE_REPORT.md`; if only `gh pr merge` authentication fails after the gate, Foreman falls back to its direct VCS merge path for the same branch. If an operator merges the PR manually, the PR merge event updates the linked run and task to `merged`. If merge fails, inspect `MERGE_REPORT.md` and any PR review artifacts.

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

The board also monitors agent inbox updates and task `updated_at` changes. When a new inbox message arrives for a run or a task is updated externally, the board reloads only the changed task cards and moves them if status changed; it does not refresh the entire board. `open` tasks appear in Backlog, `closed`/`merged` tasks appear in Closed, and unknown statuses appear in Needs Attention so they are visible for triage. Press `r` for a full manual refresh. The header shows an animated `refreshing…` indicator while full reload is in progress, then a `refreshed <time>` marker when the latest event-driven or manual update finishes. For exact options and keybindings, see [CLI Reference](./cli-reference.md#foreman-board).

## Retry and Reset Guidance

Use retry/reset surgically.

- Use `foreman retry <task-id> --dispatch` when the latest failure is safe to rerun.
- Use `foreman reset --bead <task-id>` to clear failed/stuck run state and make the task retryable.
- Use `foreman reset --bead <task-id> --preserve-worktree` (or `--retry-failed-phase`) when a repair should keep the failed run's branch/worktree instead of starting from a clean checkout. Preserved worktrees refresh `.foreman/workflows` and `.foreman/prompts` from the project before the next dispatch.
- Use `--dry-run` before destructive cleanup.
- Do not reset active work with uncommitted controller changes unless those changes are committed or exported.

Transient failures include provider rate limits, provider overloads (`529 overloaded_error`), temporary network failures, and unavailable external CLIs. Max-turn failures are treated as expensive human-review signals; inspect the diff/log before retrying.

### Direct Task Execution with `foreman run task`

For debugging, recovery, and manual reruns where the task may be in any state (failed, closed, in-progress, backlog, etc.), use `foreman run task`:

```bash
foreman run task <task-id> <workflow-path> [options]
```

**Key behaviors:**

- **Bypasses state gating** — runs regardless of task status (ready, backlog, closed, failed, etc.)
- **Preserves safety mechanisms** — worktree and run locking still apply
- **Explicit workflow** — specify the workflow as a positional argument (not via `--workflow` flag)
- **Suitable for:**
  - Re-running a completed/closed task with a different workflow
  - Testing a new workflow against an existing task
  - Debugging by running a subset of phases
  - Recovery scenarios where the task state doesn't reflect the desired action

**Common uses:**

```bash
# Run a closed task with the default task workflow
foreman run task foreman-12345 task --project my-project --no-watch

# Run with a custom workflow path
foreman run task foreman-12345 ~/.foreman/workflows/custom.yaml --target-branch main

# Dry run to preview without executing
foreman run task foreman-12345 task --dry-run

# Run with a specific model override
foreman run task foreman-12345 task --model anthropic/claude-opus-4-6
```

**When to use `foreman run task` vs `foreman run --task`:**

| Command | State gating | Workflow selection | Typical use |
|---------|--------------|--------------------|-------------|
| `foreman run --task <id>` | Yes (task must be `ready`) | `--workflow` flag | Normal dispatch |
| `foreman run task <id> <workflow>` | No (any state) | Positional argument | Debug, recovery, testing |

## Run Archiving and Filtering

Old failed runs can accumulate and obscure current state in `foreman runs`, `foreman status`, and operator views. Foreman archives and filters historical failed runs so they remain inspectable without cluttering active views.

- Archived runs are hidden from default views but remain in storage for inspection.
- `runs.archived` controls visibility in PostgreSQL-backed stores.
- Recent-active run reads include pending/running runs plus failed runs from the last 30 days, excluding archived runs.
- Use `foreman status --include-archived` when historical runs need inspection.
- `foreman purge runs` archives failed runs whose tasks are closed; permanent deletion is available via the explicit purge option.

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
