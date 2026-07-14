# CLI Reference

Complete reference for all `foreman` commands, options, and usage examples.

Project-aware operator commands (`run`, `status`, `reset`, and `retry`) accept `--project <name-or-path>`. Registered names resolve through `~/.foreman/projects.json`; absolute paths are accepted directly for one-off targeting.

## Global Usage

```bash
foreman [command] [options]
foreman --help              # Show all commands
foreman <command> --help    # Show command-specific help
```

### Local Development Services

This repository's Devbox/direnv setup starts Docker Compose services before you run Foreman locally. `devbox run dev:up` starts shared Postgres plus Hindsight; `devbox run db:up` starts only the shared pgvector Postgres container. Foreman CLI commands continue to use `DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:55432/foreman` by default; Hindsight uses a separate `hindsight` database in the same container.

### Domain Groups and Deprecated Aliases

`foreman --help` groups commands by domain:

- Setup/health: `init`, `doctor`, `daemon`, `server`
- Planning: `plan`, `sling`
- Execution: `run`, `retry`, `reset`, `stop`, `recover`
- Tasks/views: `task`, `status`, `board`, `watch`, `logs`
- Collaboration: `inbox`, `attach`, `debug`
- Delivery/VCS: `worktree`, `merge`, `pr`

Deprecated aliases stay hidden from help and print the replacement spelling when used:

| Deprecated | Use instead |
|------------|-------------|
| `foreman dashboard` | `foreman watch` |
| `foreman purge-logs` | `foreman purge logs` |
| `foreman purge-zombie-runs` | `foreman purge runs` |
| `foreman run --skip-explore` / `--skip-review` | `foreman run --workflow <custom-workflow>` |
| removed `foreman mail send` | `foreman inbox send` |

Legacy TS delegation and Node daemon start/restart were removed after the Elixir cutover; use `foreman server start` for the scheduler.

---

## Project Setup

### `foreman init`

Initialize Foreman in a project. Creates `.foreman/`, installs default workflow configs/prompts, installs bundled Pi skills to `~/.pi/agent/skills/`, and registers the project with the Elixir backend. The CLI does not run Postgres migrations or open a database connection.

```bash
foreman init                      # Initialize with auto-detected name
foreman init -n my-project        # Initialize with explicit name
foreman init --force              # Reinstall prompt, workflow, and bundled skill files after source edits
foreman init --wizard             # Interactive setup wizard that writes .foreman/config.yaml
```

| Option | Description |
|--------|-------------|
| `-n, --name <name>` | Project name (default: directory name) |
| `--force` | Overwrite existing prompt, workflow, and bundled Pi skill files. Run this after editing bundled source prompts/workflows/skills so installed runtime copies do not drift. |
| `--wizard` | Prompt for VCS backend, workflow template, issue tracker (`jira` or `github`), optional service credentials, then write `.foreman/config.yaml` |

### `foreman project`

Manage Elixir-registered projects.

```bash
foreman project list              # List all registered projects
foreman project add owner/repo     # Add a project from GitHub
foreman project register .         # Register an existing local repository
foreman project remove <id>       # Archive a project
foreman project edit <id>         # Edit project settings
```

| Option | Description |
|--------|-------------|
| `-h, --help` | Display help for command |

**Subcommands:**
| Command | Description |
|---------|-------------|
| `add <github-url>` | Add a project from GitHub URL |
| `register [path]` | Register an existing local repository |
| `list` | List all registered projects |
| `remove <id>` | Archive a project |
| `edit <id>` | Edit project settings |

---

## Dispatching Work

### `foreman run`

Dispatch ready tasks to AI agents by sending a scheduler tick to the Elixir orchestration server, which owns ready-task claiming, capacity, and worker launches.

Default workflows include a `documentation` phase before finalization. The bundled bug workflow starts with a lightweight Explorer phase that uses `Grep`, `Glob`, and targeted `Read` discovery before implementation; Elixir Overwatch rejects Graphify tools so worker discovery does not create slow generated worktree artifacts. The documentation phase updates required operator/developer docs (`CLAUDE.md`, `AGENTS.md`, `README.md`, and this User Guide) when task behavior changes, or writes `DOCUMENTATION_REPORT.md` explaining why no doc update was needed. Workflow PR/merge behavior is controlled by explicit `create-pr`, `pr-wait`, and `merge` phases; top-level `merge:` and `pr:` YAML tags are invalid.

Run `foreman init --force` after editing bundled workflow YAML or prompts. `foreman run`, `foreman run --watch`, and direct worker startup fail fast if installed runtime prompts/workflows are stale, so scheduler-launched agents cannot run with outdated instructions.

Scheduler-launched worktrees start from the registered project `defaultBranch`/`--default-branch` when configured, then fall back to VCS default-branch detection.

```bash
foreman run                       # Dispatch all ready tasks through the Elixir scheduler
foreman run --project my-project   # Dispatch against a registered project without cd
foreman run --dry-run              # Check Elixir server availability without ticking
foreman run --no-watch             # Tick once and exit; monitor with watch/status
```

| Option | Default | Description |
|--------|---------|-------------|
| `--max-agents <n>` | `5` | Maximum concurrent agents |
| `--model <model>` | — | Force a specific model (overrides `FOREMAN_DEFAULT_MODEL`) |
| `--dry-run` | — | Show what would be dispatched without doing it |
| `--no-watch` | — | Exit immediately after dispatching (don't monitor agents) |
| `--telemetry` | — | Enable OpenTelemetry tracing on spawned agents (requires `OTEL_*` env vars) |
| `--resume` | — | Resume stuck/rate-limited runs from a previous dispatch |
| `--resume-failed` | — | Also resume failed runs (not just stuck/rate-limited) |
| `--no-pipeline` | — | Skip the explorer/qa/reviewer pipeline — run as single worker agent |
| `--workflow <name>` | — | Run all dispatched tasks with this workflow (overrides `workflow:<name>` labels and task-type mapping) |
| `--task <id>` | — | Dispatch only this specific task by ID (must be ready) |
| `--no-auto-dispatch` | — | Disable automatic dispatch when an agent completes and capacity is available |
| `--stagger <duration>` | — | Stagger delay between dispatches to prevent thundering herd (e.g. `30s`, `1m`) |
| `--project <name>` | — | Registered project name (default: current directory) |
| `--project-path <absolute-path>` | — | Absolute project path (advanced/script usage) |
| `--runtime-mode <mode>` | — | Runtime mode: `normal`\|`test` (test uses deterministic phase-runner seams) |
| `--yes` | — | Answer yes to run confirmation prompts (for non-interactive dispatch) |

> **Deprecated:** `--skip-explore` and `--skip-review` are still parsed for backwards compatibility but have **no effect** on the pipeline (phase shape is defined entirely by the workflow YAML). They are hidden from `--help` and print a deprecation warning. Use `--workflow <custom-workflow>` with a project-local or global workflow that has the phase shape you want.

Pipeline budgets are optional environment guards. `0` disables a budget: `FOREMAN_MAX_PIPELINE_WALL_CLOCK_MS`, `FOREMAN_MAX_PIPELINE_COST_USD`, `FOREMAN_MAX_PIPELINE_TOOL_CALLS`, and `FOREMAN_MAX_PIPELINE_REVIEW_LOOPS`. When exceeded, Foreman stops the run, writes a native task failure note, and marks the run stuck for operator action.

### `foreman run task`

Operator use of `foreman run task` was removed after the Elixir cutover. The hidden `--run-id` bridge is reserved for Elixir scheduler-launched Node/Pi workers; when that bridge sees an Elixir-only task, Foreman mirrors task metadata into the worker store before execution so prompts receive title/type/priority/description metadata.

| Option | Default | Description |
|--------|---------|-------------|
This command remains registered only so operator invocations receive an explicit removal message. The internal `--run-id` bridge is hidden and reserved for Elixir scheduler launches.

---

## Monitoring

### `foreman status`

Show project status: task counts, active agents, cost breakdown, and tool usage. `--live` opens the unified cockpit directly to the status/workflow view; `--watch` remains the compact refreshing status output; `--json` remains machine-readable.

```bash
foreman status                    # Snapshot of current state
foreman status --project my-project # Status for a registered project without cd
foreman status -w                 # Live refresh every 10 seconds
foreman status -w 5               # Live refresh every 5 seconds
foreman status --live             # Unified cockpit opened to status/workflow
foreman status --json             # Machine-readable output
```

| Option | Default | Description |
|--------|---------|-------------|
| `-w, --watch [seconds]` | `10` | Compact auto-refresh interval |
| `--live` | — | Open the unified cockpit in status/workflow view |
| `--json` | — | Output as JSON |
| `--project <name-or-path>` | — | Show status for a registered project name or absolute project path |
| `--all` | — | Aggregate status across all registered projects |

The cockpit status view renders ordered phase nodes, retry arrows, current failure/error text, artifacts, last activity, and active phase summary. Use `m/e/l/r/f` to inspect messages, events, logs, reports, and files for the selected task/run.

### `foreman logs`

Show run logs and debugging summary.

```bash
foreman logs bd-abc1              # Show summary for a task
foreman logs bd-abc1 --tail 200    # Show more raw log lines
foreman logs bd-abc1 --follow      # Follow logs in real-time
foreman logs bd-abc1 --raw         # Print raw JSON log only
```

| Option | Default | Description |
|--------|---------|-------------|
| `--run <runId>` | — | Run ID (overrides positional ID) |
| `--project <name>` | — | Registered project name (default: current directory) |
| `--project-path <absolute-path>` | — | Absolute project path (advanced/script usage) |
| `--tail <lines>` | `80` | Raw log lines to show |
| `--follow` | — | Follow the raw JSON log after printing the summary |
| `--raw` | — | Print only the raw JSON log tail |

### `foreman watch`

Canonical live operator cockpit. The TTY view fills the terminal viewport and combines active/attention task selection, inbox timeline, status/workflow flow chart, board context, detail tabs, search/filter controls, and an action palette. Palette reset requires explicit `y` confirmation and then runs `foreman reset` for the selected task; non-reset actions still print copy/manual command text. `foreman dashboard` is a deprecated alias for this command (it prints a deprecation notice). For a compact refreshing status view, use `foreman status --watch`.

```bash
foreman watch                     # Unified live cockpit
foreman watch --no-watch          # One-shot snapshot, no polling
foreman watch --refresh 5000      # Refresh every 5 seconds
```

| Option | Default | Description |
|--------|---------|-------------|
| `--refresh <ms>` | `5000` | Cockpit refresh interval; also applies to `--no-watch` setup defaults |
| `--inbox-limit <n>` | `5` | One-shot snapshot inbox message limit |
| `--inbox-poll <ms>` | `2000` | Ignored by the cockpit; retained for compatibility with prior watch loops |
| `--events-limit <n>` | `5` | One-shot snapshot pipeline event limit |
| `--no-board` | — | Only meaningful with `--no-watch`: hide board summary panel |
| `--no-inbox` | — | Only meaningful with `--no-watch`: hide inbox panel |
| `--no-events` | — | Only meaningful with `--no-watch`: hide pipeline events panel |
| `--no-watch` | — | Print one deterministic snapshot and exit |
| `--project <id>` | — | Filter to a specific project |

Cockpit keys: `j/k` select, `i` inbox, `s` status/workflow, `b` board, `m/e/l/r/f` detail tabs, `/` search, `1/2/3` active/attention/all scopes, `!` failed, `p` has PR, `d` dirty worktree, `a`/`:` action palette, `q`/`Esc` quit. Palette reset asks for `y` confirmation and executes `foreman reset` for the selected task; all other entries print copy/manual command text only.

### `foreman sentinel`

Continuous QA testing agent that monitors a branch for test failures and auto-creates follow-up fix tasks.

```bash
# Run once
foreman sentinel run-once
foreman sentinel run-once --branch dev --test-command "npm test"
foreman sentinel run-once --dry-run

# Start background daemon
foreman sentinel start
foreman sentinel start --interval 15 --failure-threshold 3

# Check sentinel status
foreman sentinel status
foreman sentinel status --json --limit 20

# Stop background daemon
foreman sentinel stop
foreman sentinel stop --force
```

**`sentinel run-once` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--branch <branch>` | `main` | Branch to test |
| `--test-command <cmd>` | `npm test` | Test command to run |
| `--failure-threshold <n>` | `2` | Consecutive failures before filing a bug task |
| `--dry-run` | — | Simulate without running tests or creating tasks |

**`sentinel start` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--branch <branch>` | `main` | Branch to monitor |
| `--interval <minutes>` | `30` | Check interval |
| `--test-command <cmd>` | `npm test` | Test command |
| `--failure-threshold <n>` | `2` | Consecutive failures before bug |
| `--dry-run` | — | Simulate |

Sentinel persists each run in `sentinel_runs` and records `sentinel-start`, `sentinel-pass`, and `sentinel-fail` events for audit/watch surfaces.

**`sentinel status` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--limit <n>` | `10` | Recent runs to show |
| `--json` | — | Output as JSON |

**`sentinel stop` options:**

| Option | Description |
|--------|-------------|
| `--force` | Force kill with SIGKILL |

---

## Interactive Board

### `foreman board`

On a TTY, open the unified cockpit in board view. The board pane groups selected active/attention rows by lifecycle status, keeps workflow phase separate, and lets operators jump to inbox/status details without starting a second terminal loop. Non-TTY output, `--all`, and `--filter` keep the legacy/scriptable board path.

```bash
foreman board                     # TTY: unified cockpit opened to board view
foreman board --project my-project
foreman board --limit 10
foreman board --filter ready      # Legacy/scriptable filtered board path
```

| Option | Description |
|--------|-------------|
| `--project <name>` | Registered project name |
| `--project-path <absolute-path>` | Absolute project path for scripts/advanced usage |
| `--all` | Render legacy/scriptable boards for all registered projects |
| `--limit <n>` | Maximum tasks per column / cockpit fetch limit |
| `--filter <status>` | Use the legacy/scriptable filtered board path |

## Debugging & Recovery

### `foreman debug`

AI-powered execution analysis. Gathers all artifacts (logs, mail, reports, run progress, and debug timeline payload/file-change fields) for a task and sends them to an AI model for deep-dive diagnostics.

```bash
foreman debug bd-abc1             # Full AI analysis with Opus
foreman debug bd-abc1 --raw       # Dump all artifacts without AI
foreman debug bd-abc1 --model anthropic/claude-sonnet-4-6  # Cheaper model
foreman debug bd-abc1 --run 14dd  # Analyze a specific run (not latest)
```

| Option | Default | Description |
|--------|---------|-------------|
| `--run <id>` | latest | Specific run ID to analyze |
| `--model <model>` | `anthropic/claude-opus-4-6` | Model for analysis |
| `--raw` | — | Print collected artifacts without AI analysis |

**Artifacts collected:**
- Run summary (status, cost, turns, tool breakdown)
- All Agent Mail messages (chronological)
- Pipeline reports (EXPLORER_REPORT.md, QA_REPORT.md, REVIEW.md, etc.)
- Agent worker logs (`~/.foreman/logs/<runId>.log`)
- Task info from `native task store show`

### `foreman recover`

Autonomous recovery agent for pipeline failures.

```bash
foreman recover bd-abc1 --reason test-failed   # Recover from test failure
foreman recover bd-abc1 --raw                   # Show collected context without AI
foreman recover bd-abc1 --execute-clean-replay  # Full clean replay flow
```

| Option | Default | Description |
|--------|---------|-------------|
| `--reason <reason>` | — | Failure reason: `test-failed` \| `stuck` \| `stale-blocked` \| `finalize-conflict` |
| `--run-id <id>` | latest | Specific run ID |
| `--output <text>` | — | Pre-captured test output to include in context |
| `--model <model>` | — | Model to use for recovery |
| `--raw` | — | Print collected context without invoking AI |
| `--prepare-clean-replay` | — | Create a fresh clean-replay workspace |
| `--apply-clean-replay` | — | Copy intended changed files into clean replay workspace |
| `--validate-clean-replay` | — | Run typecheck and build in clean replay workspace |
| `--commit-clean-replay` | — | Stage and commit the clean replay workspace |
| `--push-clean-replay` | — | Push the validated clean replay branch |
| `--execute-clean-replay` | — | Run full clean replay: apply, validate, commit, and push |

### `foreman doctor`

Health checks for Foreman installation. Validates Pi SDK, DB integrity, required bundled Pi skills, prompt files, workflow configs, duplicate workflow YAML `task_type` declarations, stale run records, zombie runs, and stale/orphaned worktrees. Installed prompt files and workflow YAML are compared to bundled runtime contracts; stale copies are reported so `foreman doctor --fix` or `foreman init --force` can reinstall them.

```bash
foreman doctor                    # Run all health checks
foreman doctor --fix              # Auto-fix issues
foreman doctor --dry-run          # Preview fixes without applying
foreman doctor --json             # Machine-readable output
```

| Option | Description |
|--------|-------------|
| `--fix` | Auto-fix safe issues: install missing/stale prompts and workflows, reinstall missing required bundled Pi skills, migrate stores, mark zombie runs failed, reset retryable failed/stuck runs, delete stale aged run records when supported, and remove stale/orphaned worktrees that are safe to clean. |
| `--dry-run` | Preview what --fix would do |
| `--json` | Output as JSON |

### `foreman server`

Manage the experimental Elixir orchestration server used by TRD-2026-014.

```bash
foreman server start              # Start local Elixir server
foreman server status             # Show PID/URL and health
foreman server doctor             # Auto-start then run server doctor checks
foreman server doctor --no-auto-start  # Doctor check only
foreman server stop               # Stop server started by Foreman
```

| Option | Description |
|--------|-------------|
| `--port <port>` | Override local HTTP port (default `4766`; `14766` for `MIX_ENV=test`) |
| `--no-auto-start` | For `doctor`, fail instead of starting a stopped server |

`server status` shows the active `MIX_ENV`, event store, projection store, and project config store. In Postgres event-store mode, read projections persist in `foreman_project_projections`, `foreman_task_projections`, `foreman_run_projections`, and `foreman_inbox_message_projections`; in term mode projections remain in memory and rebuild from the term log. `MIX_ENV=test` refuses user port `4766` and non-temp storage unless `FOREMAN_ALLOW_TEST_PORT_COLLISION=1` / `FOREMAN_ALLOW_TEST_PERSISTENT_STORAGE=1` are set intentionally. `server doctor` validates event-store readability, projection catch-up/lag, worker projections, VCS adapters, provider adapters, and integration projections. The JSON output includes counters/timers for phase duration, retries, failures, recoveries, worker restarts, and projection lag. When server auth is enabled, set `FOREMAN_SERVER_AUTH_TOKEN` so doctor/metrics calls send the bearer token. Binding the Elixir HTTP server beyond loopback also requires this token. Worker starts strip forbidden host variables (`FOREMAN_SERVER_AUTH_TOKEN`, `AWS_*`, `GITHUB_*`, `NPM_*`, `SSH_*`, `DATABASE_*`) and scope explicit project/run secrets to the run. Destructive server commands record `AuthorizationChecked` and `AuditRecorded` events.

Elixir backend roles: the **Node CLI** parses commands/renders projections, the **Elixir server** owns aggregate-validated commands/events/projections/recovery/security/overwatch and all database access, automatically ticks the scheduler every 5 seconds to claim `ready` tasks within capacity and launch the Node/Pi worker bridge, and **Node/Pi workers** execute Pi SDK phases, stream worker events, emit authoritative terminal run/task events, stream Pi SDK tool calls/assistant messages as ordered worker events, expose typed Foreman tools (`mail_send`, `mail_read`, `phase_handoff`, `artifact_write`, `validation_result`, `task_block`, `progress_update`, `safe_command_run`), and ask Elixir overwatch to approve/deny tool calls before execution. Node workers and CLI clients do not connect directly to the database; they use Elixir HTTP commands/projections and do not drain DB-backed merge queues from inside the worker. Raw log files are compatibility/debug projections of the worker event stream. The launcher records process-exit facts and emits a diagnostic fallback failure only when a worker exits without an authoritative terminal event; that fallback may parse the final worker output to avoid stale phase attribution, but authoritative worker terminal events remain preferred. If an Elixir-backed view is wrong, inspect the event timeline first, then projection lag/rebuild state, then recovery events (`ExternalWorkerObserved` before `WorkerReattached`, `WorkerRestarted`, or `NeedsOperator`). After cutover, Elixir is the backend; `foreman daemon start|restart` fails fast and directs operators to `foreman server start`. See [Elixir Backend Architecture](./guides/elixir-backend-architecture.md).

The Elixir server also includes a PR monitor. For runs with recorded GitHub PR URLs, it periodically runs GitHub PR inspection from the registered project path, records merged PR metadata on the run, and updates the associated task to `merged` when GitHub reports `MERGED`. A GitHub closed-but-unmerged PR records the run PR state as closed and closes the associated task.


### `foreman reset`

Reset Elixir-backed task work. The command stops active worker processes when present, marks prior active runs failed with the reset reason, removes stale task worktrees unless `--keep-worktree` is set, closes any open/draft PR recorded for the task before deleting its remote branch, deletes local/origin `foreman/<task>` branches, removes prior run logs/reports, clears run linkage and failure fields, sets the task back to `ready`, and requests scheduler dispatch. Closed/completed tasks can be reopened this way; merged tasks remain terminal.

```bash
foreman reset foreman-abc12
foreman reset foreman-abc12 --reason "stale worker"
foreman reset foreman-abc12 --dry-run
foreman reset foreman-abc12 --keep-worktree
```

| Option | Description |
|--------|-------------|
| `--reason <text>` | Reason recorded in run history |
| `--dry-run` | Preview worker/worktree/branch/log cleanup, open/draft PR closure, active-run terminalization, and reset/dispatch steps |
| `--keep-worktree` | Do not remove the task worktree |
| `--project <name-or-path>` | Target a registered project name or absolute project path |

### `foreman retry`

Reset a task and optionally re-dispatch it immediately.

```bash
foreman retry bd-abc1             # Reset task to ready
foreman retry bd-abc1 --project my-project  # Retry inside a registered project without cd
foreman retry bd-abc1 --dispatch  # Reset and dispatch immediately
foreman retry bd-abc1 --model anthropic/claude-opus-4-6  # Override model
foreman retry bd-abc1 --dry-run   # Preview
```

| Option | Description |
|--------|-------------|
| `--dispatch` | Dispatch immediately after reset |
| `--model <model>` | Override the agent model |
| `--dry-run` | Show what would happen |
| `--project <name-or-path>` | Target a registered project name or absolute project path |

### `foreman abandon`

Abandon obsolete Foreman work that should not land.

```bash
foreman abandon <task-or-run-id> --reason "too stale to land"
foreman abandon <task-or-run-id> --dry-run
foreman abandon <task-or-run-id> --delete-branch --force
foreman abandon --missing-branches --dry-run
foreman abandon --missing-branches --reason "branch missing"
```

Abandon removes matching merge-queue entries, archives/removes the run worktree, marks the task `blocked` unless `--keep-task` is used, and marks the run failed with an audit event. Branch deletion is opt-in via `--delete-branch`; use `--force` for unmerged branches. Use `--missing-branches` to bulk-abandon completed runs whose `foreman/<task>` branch is missing locally, which clears stale rows that otherwise make `foreman merge` warn repeatedly.

### `foreman clean-state`

Reset Foreman to a clean operator state by intentionally dropping stale/obsolete Foreman work.

```bash
foreman clean-state --dry-run
foreman clean-state --force
foreman clean-state --force --delete-branches
foreman clean-state --force --delete-branches --delete-origin-branches
```

`clean-state` removes stale/conflict merge-queue entries, marks non-active related runs abandoned (`failed` with `merge_strategy: none`), removes non-active Foreman worktrees, and marks related tasks blocked unless `--keep-tasks` is used. It never mutates active pending/running runs. Mutating cleanup requires `--force`; without `--force` it previews only. Origin branch deletion is never implicit; opt in with `--delete-origin-branches`.

### `foreman stop`
Removed after Elixir cutover. Use Elixir-backed run/recovery controls instead.

### `foreman merge`

Merge completed agent work into the target branch via the refinery. Merge-capable workflows enqueue work from an explicit `merge` phase; workflows without that phase are not merge-queued by workflow execution. For PR-gated workflows, merge rechecks PR readiness and waits if GitHub surfaces a late pending check after `pr-wait`. The Elixir server also reconciles recorded GitHub PRs after creation, so a PR merged outside `foreman merge` is observed and the associated Foreman task becomes `merged`.

```bash
foreman merge                     # Process merge queue
foreman merge --task bd-abc1      # Merge a specific task by ID
foreman merge --list              # List tasks ready to merge
foreman merge --dry-run           # Preview merge operations
foreman merge --target-branch dev # Merge into dev instead of main
foreman merge --no-tests          # Skip test validation
foreman merge --stats             # Show merge cost statistics
foreman merge --stats weekly      # Weekly cost breakdown
```

| Option | Default | Description |
|--------|---------|-------------|
| `--target-branch <branch>` | auto-detected | Branch to merge into |
| `--no-tests` | — | Skip running tests during merge |
| `--test-command <cmd>` | `npm test` | Test command to run |
| `--task <id>` | — | Merge a single task by ID |
| `--list` | — | List tasks ready to merge |
| `--dry-run` | — | Preview merge operations |
| `--resolve <runId>` | — | Resolve a merge conflict |
| `--strategy <strategy>` | — | Conflict resolution: `theirs` or `abort` |
| `--auto-retry` | — | Auto-retry with exponential backoff |
| `--stats [period]` | — | Show merge cost stats (`daily`, `weekly`, `monthly`, `all`) |
| `--json` | — | Output as JSON |

### `foreman pr`

Create GitHub pull requests for completed work.

```bash
foreman pr                        # Create PRs for all completed tasks
foreman pr --draft                # Create as draft PRs
foreman pr --base-branch dev      # PR against dev instead of main
```

| Option | Default | Description |
|--------|---------|-------------|
| `--base-branch <branch>` | `main` | Base branch for PRs |
| `--draft` | — | Create draft PRs |

---

## GitHub Issues Integration

### `foreman issue`

GitHub Issues integration commands for viewing, listing, importing, and syncing issues.

```bash
foreman issue list                # List GitHub issues
foreman issue view bd-123        # View a specific issue
foreman issue import bd-123       # Import an issue as a Foreman task
foreman issue labels              # List repository labels
foreman issue milestones          # List repository milestones
foreman issue configure           # Configure GitHub sync
foreman issue status              # Show sync status
foreman issue link bd-123 --pr 456  # Link PR to issue
```

**`issue view` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `<issue>` | — | Issue number or URL |
| `--project <name>` | current directory | Registered project name |
| `--json` | — | Output as JSON |

**`issue list` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--project <name>` | current directory | Registered project name |
| `--state <state>` | open | Issue state: open, closed, all |
| `--labels <labels>` | — | Filter by labels (comma-separated) |
| `--milestone <milestone>` | — | Filter by milestone |
| `--limit <n>` | 50 | Maximum issues to show |
| `--json` | — | Output as JSON |

**`issue configure` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--project <name>` | current directory | Registered project name |
| `--auto-import` | — | Automatically import new issues |
| `--sync-labels` | — | Sync labels from GitHub |

**`issue import` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `<issue>` | — | Issue number, URL, or path to local repo |
| `--project <name>` | current directory | Registered project name |
| `--type <type>` | — | Task type: task, bug, feature |
| `--priority <priority>` | — | Task priority: critical, high, medium, low |
| `--dry-run` | — | Preview without creating task |
| `--json` | — | Output as JSON |

**`issue labels` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--project <name>` | current directory | Registered project name |
| `--json` | — | Output as JSON |

**`issue milestones` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--project <name>` | current directory | Registered project name |
| `--state <state>` | active | Milestone state: open, closed, all |
| `--json` | — | Output as JSON |

**`issue webhook` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--project <name>` | current directory | Registered project name |
| `--enable` | — | Enable webhook |
| `--disable` | — | Disable webhook |
| `--url <url>` | — | Webhook URL |
| `--events <events>` | — | Webhook events (comma-separated) |
| `--json` | — | Output as JSON |

**`issue status` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--project <name>` | current directory | Registered project name |
| `--json` | — | Output as JSON |

**`issue link` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `<issue>` | — | Issue number or URL |
| `--pr <number>` | — | PR number to link |
| `--unlink` | — | Unlink instead of linking |
| `--project <name>` | current directory | Registered project name |
| `--json` | — | Output as JSON |

---

## MCP Server

### `foreman mcp`

Run the Foreman MCP server for agent/tool integrations. Use stdio for local MCP clients that spawn Foreman directly, or HTTP for long-running local/remote clients.

```bash
foreman mcp --transport stdio
foreman mcp --transport http --host 127.0.0.1 --port 4777
foreman mcp --transport http --host 0.0.0.0 --mcp-auth-token "$FOREMAN_MCP_AUTH_TOKEN"
foreman mcp --transport http --server-url http://foreman.internal:4766
```

| Option | Default | Description |
|--------|---------|-------------|
| `--transport <stdio\|http>` | `stdio` | MCP transport |
| `--host <host>` | `127.0.0.1` | HTTP bind host |
| `--port <port>` | `4777` | HTTP bind port |
| `--server-url <url>` | local Elixir URL | Elixir backend URL for remote Foreman |
| `--mcp-auth-token <token>` | unset | Require bearer token for HTTP MCP requests |
| `--no-auto-start` | — | Do not auto-start the local Elixir server |

Initial tools include one-call smoke status, health, scheduler status/tick, projects, tasks, approvals, task reset, run summaries plus per-run inspection, inbox, lifecycle events, and debug timelines. Most MCP reads/writes go through the Elixir backend; `foreman.tasks.reset` intentionally runs the local CLI reset flow so it can clean local worktrees, branches, and log/report artifacts. `foreman.projects.list` returns the same normalized project fields as `foreman project list --json` and hides archived projects unless a status filter is provided. `foreman.runs.list` returns only run id, date, and status; `foreman.runs.inspect` returns one run's full payload by run id. The project-local Pi extension exposes common slash commands (`/foreman-smoke`, `/foreman-tasks`, `/foreman-task`, `/foreman-approve`, `/foreman-runs`, `/foreman-inbox`, `/foreman-events`, `/foreman-scheduler`, `/foreman-tick`) backed by these tools. See [MCP Server](./mcp-server.md) for design and future remote-use cases.

---

## Agent Mail

### `foreman inbox`

View the Agent Mail inbox — messages sent between agents and the foreman orchestrator. In Elixir/default backend mode, inbox reads the Elixir event-backed inbox projection (`InboxMessageAppended` / `InboxDeliveryUpdated`) and does not require the Node daemon socket. When run on a TTY with no explicit selector, `foreman inbox` opens the unified cockpit focused on the inbox view: task list, selected-run timeline, status/board jump keys, details, and `m/e/l/r/f` tabs for messages, events, logs, reports, and files. The cockpit phase rail follows the selected run's workflow phase order and shows per-phase retry counts. Message rows render newest-first with local `mm/dd hh:mm`, sender, receiver, and message columns. The cockpit refreshes live while keeping the selected run pinned; `/`, `1/2/3`, `!`, `p`, and `d` search/filter rows; `a` or `:` opens the action palette. Palette reset requires explicit `y` confirmation and then runs `foreman reset` for the selected task; non-reset actions still print copy/manual command text. Use `--non-interactive` for scriptable output. Task/run drilldowns stay scriptable by default and enter the cockpit only with `--interactive`.

```bash
foreman inbox                     # TTY: unified cockpit opened to inbox view; non-TTY summary
foreman inbox --non-interactive   # Scriptable active/attention summary
foreman inbox task bd-abc1        # Scriptable task drilldown; add --logs --reports --files
foreman inbox task bd-abc1 --interactive # Cockpit with this task selected
foreman inbox run <run-id> --interactive # Cockpit with this run selected
foreman inbox --task bd-abc1      # Legacy task selector; still supported
foreman inbox --all               # Task-first all-run summary
foreman inbox --all --watch       # Live stream ALL messages across all runs
foreman inbox --watch             # Live stream latest run's messages
foreman inbox --unread            # Show only unread messages
foreman inbox --limit 100         # Show more messages
foreman inbox --compact           # Summarize task/run, phases, tools, denials, notable events
foreman inbox task bd-abc1 --logs --reports --files
foreman inbox --ack               # Mark shown messages as read
```

| Option | Default | Description |
|--------|---------|-------------|
| `--agent <name>` | all | Filter to specific agent/role |
| `--run <id>` | latest | Filter to a specific run ID |
| `--task <id>` | — | Legacy selector: resolve run by task ID |
| `--all` | — | Show/watch task-first output across all runs |
| `--watch` | — | Poll every 2 seconds for new messages |
| `--unread` | — | Show only unread messages |
| `--limit <n>` | `50` | Maximum messages/summary rows |
| `--events-limit <n>` | `50` | Maximum lifecycle events |
| `--interactive` | — | For task/run subcommands, open the cockpit with the selected id |
| `--non-interactive` | — | Force scriptable output even when stdout is a TTY |
| `--scope <scope>` | attention | Task summary scope: active, attention, all, terminal |
| `--messages` / `--events` | — | Task/run drilldown sections |
| `--logs` / `--reports` / `--files` | — | Task/run drilldown artifact sections |

### `foreman inbox send`

Send an Agent Mail message within a pipeline run (replaces the removed `foreman mail send`).

```bash
foreman inbox send \
  --run-id "abc123" \
  --from "developer" \
  --to "foreman" \
  --subject "phase-complete" \
  --body '{"phase":"developer","status":"complete"}'
```

| Option | Default | Description |
|--------|---------|-------------|
| `--run-id <id>` | `$FOREMAN_RUN_ID` | Run ID (falls back to env var) |
| `--from <agent>` | *required* | Sender agent role (e.g. `explorer`, `developer`) |
| `--to <agent>` | *required* | Recipient agent role (e.g. `foreman`, `developer`) |
| `--subject <subject>` | *required* | Message subject (e.g. `phase-started`, `phase-complete`, `agent-error`) |
| `--body <json>` | `'{}'` | Message body (must be a valid JSON string) |

---

## Task Planning

### `foreman plan`

Run the Ensemble PRD → TRD pipeline. Converts a product description into a Technical Requirements Document with decomposed tasks.

```bash
foreman plan "Add user authentication with OAuth"
foreman plan docs/PRD.md          # From a file
foreman plan "..." --prd-only     # Stop after PRD generation
foreman plan --from-prd docs/PRD.md  # Start from existing PRD
foreman plan "..." --output-dir docs/auth  # Custom output directory
foreman plan "..." --dry-run      # Preview steps
foreman plan prd "Add user authentication"   # Server-backed PRD planning
foreman plan trd docs/PRD.md                  # Server-backed TRD planning
```

`foreman plan prd` and `foreman plan trd` submit `plan.prd` / `plan.trd` commands to the local Elixir orchestration server. They auto-start the server by default; use `--no-auto-start` to require an already-running server.

| Option | Default | Description |
|--------|---------|-------------|
| `--prd-only` | — | Stop after PRD generation |
| `--from-prd <path>` | — | Start from an existing PRD file |
| `--output-dir <dir>` | `./docs` | Output directory for PRD/TRD |
| `--runtime <runtime>` | `claude-code` | AI runtime (`claude-code` or `codex`) |
| `--dry-run` | — | Show steps without executing |

Server-backed `plan prd` / `plan trd` options: `--project <path>`, `--output-dir <dir>`, `--provider <provider>`, `--run-id <id>`, `--command-id <id>`, `--no-auto-start`.

### `foreman sling trd`

Convert a Technical Requirements Document into a native task hierarchy with dependencies.

```bash
foreman sling trd docs/TRD.md    # Create native tasks from TRD
foreman sling trd docs/TRD.md --dry-run  # Preview
foreman sling trd docs/TRD.md --json     # Output parsed structure
foreman sling trd docs/TRD.md --auto     # Skip confirmation prompts
foreman sling trd docs/TRD.md --skip-completed   # Skip [x] items
foreman sling trd docs/TRD.md --close-completed  # Create and close [x] items
```

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview without creating tasks |
| `--auto` | Skip confirmation prompts |
| `--json` | Output parsed structure as JSON |
| `--skip-completed` | Skip `[x]` completed tasks |
| `--close-completed` | Create and immediately close `[x]` tasks |
| `--no-parallel` | Disable parallel sprint detection |
| `--force` | Recreate tasks even if they exist |
| `--no-risks` | Skip risk register items |
| `--no-quality` | Skip quality requirements |

### `foreman task create`

Create a new structured task in backlog status. Natural-language task generation (`--from-text`) was removed after the Elixir backend cutover.

```bash
foreman task create --title "Fix login timeout" --type bug --priority 1
foreman task create --title "Fix login timeout" --description "Session expires too early"
```

| Option | Default | Description |
|--------|---------|-------------|
| `--title <text>` | — | Task title (required) |
| `--description <text>` | — | Optional task description |
| `--type <type>` | `task` | Task type. Bundled auto-routed types: `task`, `bug`, `feature`, `epic`, `smoke`; project/global workflows can declare additional `task_type` values. |
| `--priority <level>` | `medium` | Priority: `0`–`4` or `critical`/`high`/`medium`/`low`/`backlog` |
| `--from-text <description>` | — | Removed after Elixir cutover; use `--title` and `--description` |
| `--parent <id>` / `--dry-run` / `--no-llm` / `--model` | — | Removed natural-language generator options |
| `--project <name>` | current directory | Registered project name |
| `--project-path <absolute-path>` | — | Absolute project path (advanced/script usage) |

---

## Migration and Coexistence

### `foreman import --to-elixir`

Import a TypeScript-era migration payload into the Elixir event store. The payload is JSON and may include `projects`, `tasks`, `runs`, `workflows`, `inbox_messages`, and `config`.

```bash
foreman import --to-elixir --file migration.json
foreman import --to-elixir --from-node --project foreman
foreman import --to-elixir --file migration.json --command-id migration-2026-014
foreman import --to-elixir --file migration.json --no-auto-start
```

| Option | Description |
|--------|-------------|
| `--file <path>` | Migration JSON payload to import |
| `--from-node` | Deprecated. The CLI no longer reads Node/Postgres state directly; export a migration JSON separately and use `--to-elixir --file <path>`. |
| `--command-id <id>` | Explicit server command id for idempotent retries |
| `--no-auto-start` | Require an already-running Elixir server |

Elixir is the backend after cutover. Legacy TS delegation has been removed, and `foreman daemon start|restart` now fails with guidance to use `foreman server start`. Operator commands either route through Elixir-backed APIs/events/projections or report removal.

---

## Agent Sessions

### `foreman attach`

Attach to a running or completed agent session to inspect its state.

```bash
foreman attach                    # Attach to latest session
foreman attach bd-abc1            # Attach to a specific task by ID
foreman attach --list             # List attachable sessions
foreman attach --follow           # Tail the agent log file
foreman attach --stream           # Stream Agent Mail messages
foreman attach --worktree         # Open a shell in the agent's worktree
foreman attach --kill             # Kill the agent process
```

| Option | Description |
|--------|-------------|
| `--list` | List attachable sessions |
| `--follow` | Follow log file (like `tail -f`) |
| `--stream` | Stream Agent Mail messages in real time |
| `--worktree` | Open an interactive shell in the worktree |
| `--kill` | Kill the agent process |

---

## Worktree Management

### `foreman worktree`

Manage git worktrees used by Foreman agents.

```bash
foreman worktree list             # Show all active worktrees
foreman worktree list --json      # Machine-readable output
foreman worktree clean            # Remove orphaned worktrees
foreman worktree clean --all      # Remove ALL worktrees including active
foreman worktree clean --force    # Force-delete branches
foreman worktree clean --dry-run  # Preview removal
```

**`worktree list` options:**

| Option | Description |
|--------|-------------|
| `--json` | Output as JSON |

**`worktree clean` options:**

| Option | Description |
|--------|-------------|
| `--all` | Remove ALL worktrees including active ones |
| `--force` | Force-delete branches (including remote) |
| `--dry-run` | Preview removal without deleting |

---

## Maintenance

### `foreman purge`

Purge old agent logs and stale run records. The old `foreman purge-logs` and `foreman purge-zombie-runs` spellings remain as hidden deprecated aliases.

#### `foreman purge logs`

Remove old agent log files from `~/.foreman/logs/` based on a retention policy.

```bash
foreman purge logs                # Delete logs older than 7 days
foreman purge logs --days 30      # Custom retention window
foreman purge logs --dry-run      # Preview
foreman purge logs --all          # Delete all terminal-status logs regardless of age
```

| Option | Default | Description |
|--------|---------|-------------|
| `--days <n>` | `7` | Delete logs from runs older than N days |
| `--dry-run` | — | Preview without making changes |
| `--all` | — | Delete all terminal-status logs regardless of age (use with caution) |

#### `foreman purge runs`

Remove failed run records for tasks that are already closed or no longer exist. Reduces database clutter.

```bash
foreman purge runs                # Clean up stale records
foreman purge runs --dry-run      # Preview
```

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview without making changes |

---

## GitHub Issues Integration

### `foreman issue`

GitHub Issues integration commands.

```bash
foreman issue view owner/repo#123      # View a specific issue
foreman issue list owner/repo          # List open issues
foreman issue configure owner/repo    # Configure a repository for sync
foreman issue import owner/repo#123   # Import issue as Foreman task
foreman issue labels owner/repo       # List repository labels
foreman issue milestones owner/repo   # List repository milestones
foreman issue webhook owner/repo      # Manage GitHub webhooks
foreman issue status owner/repo       # Show sync status
foreman issue link owner/repo#123 --pr owner/repo#456  # Link PR to issue
```

| Option | Description |
|--------|-------------|
| `-h, --help` | Display help for command |

**Subcommands:**
| Command | Description |
|---------|-------------|
| `view` | View a GitHub issue |
| `list` | List GitHub issues for a repository |
| `configure` | Configure a GitHub repository for sync |
| `import` | Import GitHub issue(s) as Foreman tasks |
| `labels` | List labels for a GitHub repository |
| `milestones` | List milestones for a GitHub repository |
| `webhook` | Manage GitHub webhooks for a repository |
| `status` | Show sync status for a GitHub repository |
| `link` | Link a GitHub pull request to an issue (or unlink) |

> **Removed commands:** `foreman monitor` has been removed. `foreman mail send` has been removed — use `foreman inbox send`.
