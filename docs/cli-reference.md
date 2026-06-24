# CLI Reference

Complete reference for all `foreman` commands, options, and usage examples.

Project-aware operator commands (`run`, `status`, `reset`, and `retry`) accept `--project <name-or-path>`. Registered names resolve through `~/.foreman/projects.json`; absolute paths are accepted directly for one-off targeting.

## Global Usage

```bash
foreman [command] [options]
foreman --help              # Show all commands
foreman <command> --help    # Show command-specific help
```

### Domain Groups and Deprecated Aliases

`foreman --help` groups commands by domain:

- Setup/health: `init`, `doctor`, `daemon`, `server`
- Planning: `plan`, `sling`
- Execution: `run`, `retry`, `reset`, `stop`, `recover`
- Tasks/views: `task`, `status`, `board`, `watch`, `logs`, `runs`
- Collaboration: `inbox`, `attach`, `debug`
- Delivery/VCS: `worktree`, `merge`, `pr`

Deprecated aliases stay hidden from help and print the replacement spelling when used:

| Deprecated | Use instead |
|------------|-------------|
| `foreman dashboard` | `foreman watch` |
| `foreman bead` | `foreman task create --from-text` |
| `foreman purge-logs` | `foreman purge logs` |
| `foreman purge-zombie-runs` | `foreman purge runs` |
| `foreman run --skip-explore` / `--skip-review` | `foreman run --workflow quick` or a custom workflow |
| removed `foreman mail send` | `foreman inbox send` |

During Elixir migration, incomplete legacy command coverage can be delegated with `FOREMAN_LEGACY_COMPATIBILITY_MODE=1` and `FOREMAN_LEGACY_TS_BIN=/path/to/legacy/foreman` only when `FOREMAN_BACKEND=node` is set. Elixir is the default after cutover; it disables legacy TS delegation and blocks `foreman daemon start|restart` so the Node scheduler cannot run beside the Elixir scheduler.

---

## Project Setup

### `foreman init`

Initialize Foreman in a project. Creates `.foreman/` directory, installs default workflow configs, prompts, and registers the project in the Postgres store.

```bash
foreman init                      # Initialize with auto-detected name
foreman init -n my-project        # Initialize with explicit name
foreman init --force              # Overwrite existing prompt files
foreman init --wizard             # Interactive setup wizard that writes .foreman/config.yaml
```

| Option | Description |
|--------|-------------|
| `-n, --name <name>` | Project name (default: directory name) |
| `--force` | Overwrite existing prompt and workflow files |
| `--wizard` | Prompt for VCS backend, workflow template, issue tracker (`beads`, `jira`, or `github`), optional service credentials, then write `.foreman/config.yaml` |

### `foreman project edit`

Update registered project settings. `--default-branch` controls the base branch used for new task worktrees and finalization targets.

```bash
foreman project edit <project-id> --default-branch dev
```

| Option | Description |
|--------|-------------|
| `--name <name>` | Project display name |
| `--status <status>` | Project status: `active`, `paused`, or `archived` |
| `--default-branch <branch>` | Default/base branch for new project worktrees |

---

## Dispatching Work

### `foreman run`

Dispatch ready tasks to AI agents. Runs in a continuous loop by default — dispatches native tasks from the Postgres task store, skips ready tasks whose dependency blockers are not closed, monitors agents, and merges each completed task's own queued PR/branch. The daemon uses the same dependency-filtered ready queue and logs both dispatched task IDs and skipped-task reasons each dispatch cycle.

Default workflows are YAML-defined phase/action sequences, including dispatcher workspace actions before agent launch. Editable action modules in `.foreman/actions/*.js` are loaded at runtime when present. The bundled fast path has Explorer (when present) hand off directly to Developer, then QA/review/finalize/documentation. TDD red/review phases are opt-in via `foreman run --workflow tdd`, a `workflow:tdd` label, or task type `tdd`. In the TDD workflow, `test-red` writes at most a few focused failing tests and `test-review` verifies those tests cover the acceptance contract and fail for the expected missing behavior, with one Red retry. Direct task runs write `TASK.md` into the worktree before spawning agents. Explorer, Developer, and QA phases are handoff-driven and use phase overwatch/tool telemetry to block broad repo discovery, Developer test execution, full-suite QA runs, and runaway work before the `maxTurns` emergency fuse. Before QA, Foreman gates Developer completion on report self-check evidence, acceptance-contract coverage from `EXPLORER_REPORT.md`, actual git diff, claimed file existence, required docs/tests (or an explicit no-docs-needed self-check), and TypeScript compilation when TS/JS files changed. Runtime preflight also fails on stale project/global prompt overrides that are missing required acceptance-contract markers. Verdict phases with `contract.policy.acceptanceCoverage` must carry and address the Explorer acceptance criteria; missing coverage overrides PASS to FAIL and is recorded as phase failure/retry events. Phase reports are preserved as attempt-numbered copies (`REPORT.attempt-N.md`) with `RETRY_ATTEMPTS.md` listing them.

```bash
foreman run                       # Dispatch all ready tasks (up to max-agents)
foreman run --project my-project   # Dispatch against a registered project without cd
foreman run --task bd-abc1        # Dispatch a specific task by ID
foreman run --dry-run             # Preview what would be dispatched
foreman run --max-agents 3        # Limit concurrent agents to 3
foreman run --resume              # Resume stuck/rate-limited runs
foreman run --resume-failed       # Also resume permanently failed runs
foreman run --no-watch            # Dispatch once and exit (don't monitor)
foreman run --yes                 # Auto-confirm run prompts for non-interactive use
foreman run --no-pipeline         # Single agent mode (no explorer/qa/reviewer)
foreman run --workflow quick      # Run all dispatched tasks with the quick workflow
foreman run --workflow tdd        # Opt into Red/Test Review before Developer
foreman run --model anthropic/claude-opus-4-6  # Force a specific model
```

| Option | Default | Description |
|--------|---------|-------------|
| `--task <id>` | — | Dispatch only this specific task ID (must be ready) |
| `--bead <id>` | — | Alias for `--task` (backward compatibility) |
| `--max-agents <n>` | `5` | Maximum concurrent agents |
| `--model <model>` | — | Force a specific model for all phases |
| `--dry-run` | — | Show what would be dispatched without doing it |
| `--no-watch` | — | Exit immediately after dispatching |
| `--yes` | — | Answer yes to run confirmation prompts, including non-default target branch confirmation |
| `--resume` | — | Resume stuck/rate-limited runs from previous dispatch |
| `--resume-failed` | — | Also resume failed runs (not just stuck) |
| `--no-pipeline` | — | Skip the pipeline — run as single worker agent |
| `--workflow <name>` | — | Run all dispatched tasks with this workflow (overrides `workflow:<name>` labels, workflow YAML `task_type` routing, and legacy task-type mapping; fails fast with the list of available workflows if it cannot be loaded) |
| `--no-auto-dispatch` | — | Disable auto-dispatch when capacity is available |
| `--telemetry` | — | Enable OpenTelemetry tracing (requires OTEL_* env vars) |
| `--project <name-or-path>` | — | Target a registered project name or absolute project path |

> **Deprecated:** `--skip-explore` and `--skip-review` are still parsed for backwards compatibility but have **no effect** on the pipeline (phase shape is defined entirely by the workflow YAML). They are hidden from `--help` and print a deprecation warning. Use `--workflow quick` (a bundled workflow without explorer/reviewer phases) or a custom workflow instead.

Pipeline budgets are optional environment guards. `0` disables a budget: `FOREMAN_MAX_PIPELINE_WALL_CLOCK_MS`, `FOREMAN_MAX_PIPELINE_COST_USD`, `FOREMAN_MAX_PIPELINE_TOOL_CALLS`, and `FOREMAN_MAX_PIPELINE_REVIEW_LOOPS`. When exceeded, Foreman stops the run, writes a native task failure note, and marks the run stuck for operator action.

### `foreman run task`

Run a specific task through an explicit workflow, bypassing scheduler state gates. This is intended for debugging, recovery, and manual reruns where the task may be `failed`, `closed`, `in-progress`, or otherwise not `ready`. Worktree/run locking still applies. When the Elixir scheduler launches the legacy Node worker bridge and the task only exists in Elixir projections, Foreman mirrors that task into the Postgres worker store before execution so prompts receive title/type/priority/description metadata.

```bash
foreman run task foreman-12345 task --project foreman --no-watch
foreman run task foreman-12345 ~/.foreman/workflows/task.yaml --target-branch main
```

| Option | Default | Description |
|--------|---------|-------------|
| `--model <model>` | workflow default | Override the model used by spawned worker phases |
| `--dry-run` | — | Resolve task, workflow, and worktree without creating a run |
| `--no-watch` | — | Spawn the worker and return immediately |
| `--target-branch <branch>` | detected default | Override base/target branch for finalization and merge |
| `--project <name>` | current project | Registered project name |
| `--project-path <absolute-path>` | current project | Absolute project path for advanced/scripted use |

> **Deprecated:** `--skip-explore` and `--skip-review` are hidden no-ops here too — pick a workflow without those phases instead (e.g. `foreman run task <task-id> quick`).

---

## Monitoring

### `foreman status`

Show project status: task counts, active agents, cost breakdown, and tool usage.

```bash
foreman status                    # Snapshot of current state
foreman status --project my-project # Status for a registered project without cd
foreman status -w                 # Live refresh every 10 seconds
foreman status -w 5               # Live refresh every 5 seconds
foreman status --live             # Full dashboard TUI
foreman status --json             # Machine-readable output
```

| Option | Default | Description |
|--------|---------|-------------|
| `-w, --watch [seconds]` | `10` | Auto-refresh interval |
| `--live` | — | Enable full dashboard TUI (Ink-based) |
| `--json` | — | Output as JSON |
| `--project <name-or-path>` | — | Show status for a registered project name or absolute project path |
| `--all` | — | Aggregate status across all registered projects |
| `--include-archived` | — | Include archived runs in status output (default: archived runs are hidden to reduce noise) |

**Example output:**

```
Project Status

Tasks
  Total:       65
  Ready:       3
  In Progress: 2
  Completed:   50
  Blocked:     4

Active Agents
▼ ● bd-abc1 RUNNING 3m 27s (attempt 2, prev: failed)
  Model      anthropic/sonnet-4-6
  Cost       $1.56
    explorer   $0.31 (anthropic/haiku-4-5)
    developer  $1.25 (anthropic/sonnet-4-6)
  Turns      18
  Phase      qa
  Tools      70 (last: bash)
  bash     ███████████████ 27
  read     ██████████ 18
  Files      3
```

### `foreman metrics`

Show per-phase pipeline metrics from the Elixir server by default. Add `--costs` (or any cost filter such as `--since`, `--phase`, `--agent`, `--task-type`, or `--compact`) to show cost and token usage aggregated from the task store.

```bash
foreman metrics                         # Human-readable pipeline metrics dashboard
foreman metrics --json                  # Raw pipeline metrics JSON from the server
foreman metrics --costs                 # Human-readable cost/token metrics summary
foreman metrics --costs --json          # Cost/token JSON with timestamp/projectId
foreman metrics --compact               # Cost/token single-line key=value format for scripts
foreman metrics --since 2026-06-01      # Filter cost metrics since this date
foreman metrics --phase explorer        # Filter cost metrics to a specific phase
foreman metrics --agent claude-sonnet-4-6       # Filter cost metrics by agent model
foreman metrics --task-type feature     # Filter cost metrics to a specific task type
foreman metrics --project my-project    # Metrics for a registered project
foreman metrics --project-path /abs/path # Metrics for a project at an absolute path
foreman metrics --costs --json --since 2026-06-01 --phase developer --task-type bug  # Combine cost filters
```

| Option | Default | Description |
|--------|---------|-------------|
| `--json` | — | Output JSON: pipeline JSON by default, cost/token JSON in cost mode |
| `--compact` | — | Output cost/token metrics as a single-line `key=value` string for scripting (e.g., `cost=1.2300 tokens=12345 phases=3 agents=1 filters=since=X,phase=Y`) |
| `--costs` | — | Show task-store cost/token metrics instead of pipeline metrics |
| `--since <iso-timestamp>` | — | Include cost metrics since this ISO timestamp; implies cost mode |
| `--phase <phase-name>` | — | Filter cost metrics to a specific phase (explorer, developer, qa, reviewer, finalize); implies cost mode |
| `--agent <type>` | — | Filter cost metrics to a specific agent model (e.g., claude-sonnet-4-6); implies cost mode |
| `--task-type <type>` | — | Filter cost metrics to tasks of a specific type (feature, bug, chore, task); implies cost mode |
| `--project <name-or-path>` | — | Show metrics for a registered project name |
| `--project-path <absolute-path>` | — | Show metrics for a project at an absolute path (advanced/script usage) |

Pipeline output sections:
- **Per-Phase Breakdown** — pass rate, fail count, timeout count, retry count, avg turns, avg cost, total runs
- **Top Failure Reasons** — grouped by phase, sorted by frequency
- **Stuck Tasks by Reason** — phases stuck due to timeout or failure
- **Recent Pipeline Bottlenecks** — most recently started phases (last 5)
- **Retry Attempts** — aggregate total retry attempts across all phases
- **Circuit Breaker** — count of same-failure circuit breaker hits
- **QA Environment Blocked** — count of environment-blocked QA outcomes
- **Blocked Retries by Reason** — retries blocked by phase/failure reason

**Pipeline JSON fields** (`--json`) include:
- `pipeline_metrics.counters.circuit_breaker_hits` — same-failure circuit breaker hit count
- `pipeline_metrics.counters.qa_environment_blocked` — environment-blocked QA outcome count
- `pipeline_metrics.retry_details.stuck_by_reason` — stuck retries grouped by phase/reason
- `pipeline_metrics.retry_details.blocked_by_reason` — blocked retries grouped by phase/reason
- `pipeline_metrics.retry_details.qa_environment_blocked` — QA environment-blocked count

**Cost metrics example output:**

```
Metrics (since 2026-06-01, phase=developer, agent=claude-sonnet-4-6, task-type=bug)
  Total Cost:   $4.56
  Total Tokens: 123.5k

By Phase
  explorer    $0.31
  developer   $3.25
  qa          $1.00

By Agent
  claude-haiku-4-5       $0.31
  claude-sonnet-4-6      $4.25

Tasks by Status
  ready       3
  in-progress 2
  completed   50
```

### `foreman watch`

Single-pane unified live dashboard: agents, board summary, inbox, and pipeline events. `foreman dashboard` is a deprecated alias for this command (it prints a deprecation notice). For a compact refreshing status view, use `foreman status --watch`.

```bash
foreman watch                     # Live unified dashboard
foreman watch --no-watch          # One-shot snapshot, no polling
foreman watch --refresh 5000      # Refresh every 5 seconds
foreman watch --no-events         # Hide the pipeline events panel
```

| Option | Default | Description |
|--------|---------|-------------|
| `--refresh <ms>` | `5000` | Refresh interval in milliseconds (min: 1000) |
| `--inbox-limit <n>` | `5` | Max inbox messages shown |
| `--inbox-poll <ms>` | `2000` | Inbox-only poll interval in milliseconds |
| `--events-limit <n>` | `5` | Max pipeline events shown |
| `--no-watch` | — | One-shot snapshot, no polling |
| `--no-board` | — | Hide board summary panel |
| `--no-inbox` | — | Hide inbox panel |
| `--no-events` | — | Hide pipeline events panel |
| `--project <id>` | — | Filter to a specific project ID |

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

### `foreman runs`

Operator traceability dashboard for active Foreman runs. Lists pending/running runs with task ID, phase, elapsed time, last activity, and stuck/fatal indicators. Makes scheduler/worker activity observable even when inbox messages are sparse.

```bash
foreman runs                              # List active runs
foreman runs --project my-project         # Runs for a specific project
foreman runs --verbose                    # Show log path, report path, cost/turns
foreman runs --json                       # Output as JSON array
foreman runs --stuck                      # Show only runs likely stuck (>15 min inactive)
foreman runs --all                        # Include completed/failed runs in summary
```

| Option | Default | Description |
|--------|---------|-------------|
| `--project <name>` | current directory | Registered project name |
| `--project-path <path>` | — | Absolute project path (advanced/script usage) |
| `--verbose` | — | Show log path, report path, cost, and turns columns |
| `--json` | — | Output runs as a JSON array |
| `--stuck` | — | Show only runs likely stuck (>15 min inactive) |
| `--all` | — | Include completed/failed runs in summary count |

**Output columns:**
- `RUN_ID` — Unique run identifier
- `TASK` — Seed/task ID
- `STATUS` — Current status (pending, running, completed, failed, etc.)
- `PHASE` — Current pipeline phase (explorer, developer, qa, etc.)
- `ELAPSED` — Time since run started
- `LAST_EVENT` — Last tool call observed from Pi activity logs
- `LOG_PATH` / `REPORT_PATH` — Paths to run artifacts (verbose only)
- `COST` / `TURNS` — Cost and turn counts (verbose only)
- `INDICATORS` — Status flags: `STUCK`, `FATAL`, `CONFLICT`, `TEST-FAIL`

**Example output:**

```text
Foreman Runs  (3 shown)

  Use --verbose to show log path, report path, and cost/turns.
  Use --stuck to filter to likely-stuck runs only.

────────────────────────────────────────────────────────────────────────────────────
RUN_ID    TASK                STATUS    PHASE        ELAPSED  LAST_EVENT         INDICATORS
────────────────────────────────────────────────────────────────────────────────────
run-abc1  foreman-12345       RUNNING   developer    5m 32s   read(src/app.ts)   —
run-xyz2  foreman-67890       PENDING   explorer     1m 05s   —                  —
run-qrs3  foreman-11111       RUNNING   qa           12m 48s  bash(npm test)     STUCK
────────────────────────────────────────────────────────────────────────────────────
```

---

## Interactive Board

### `foreman board`

Open the terminal kanban board for native tasks. Press `y` to copy the selected task ID. `open`/`backlog` tasks render in Backlog, terminal `closed`/`merged` tasks render in Closed, and unknown statuses render in Needs Attention instead of being hidden as closed. The board monitors agent inbox messages and task `updated_at` changes, then updates only changed task cards, so phase/status movement appears without a whole-board reload. Press `r` for a full manual refresh; the header shows a `refreshing…` spinner during full reload and `refreshed <time>` after task data updates.

```bash
foreman board
foreman board --project my-project
foreman board --limit 10
```

| Option | Description |
|--------|-------------|
| `--project <name>` | Registered project name |
| `--project-path <absolute-path>` | Absolute project path for scripts/advanced usage |
| `--all` | Render boards for all registered projects |
| `--limit <n>` | Maximum tasks per column |
| `--filter <status>` | Filter by status |

---

## Debugging & Recovery

### `foreman debug`

AI-powered execution analysis. Gathers all artifacts (logs, mail, reports, run progress) for a task and sends them to an AI model for deep-dive diagnostics.

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
- Bead info from `br show`

### `foreman logs`

Show run logs and debugging summaries.

```bash
foreman logs <task-or-run-id>          # Summary with phase/tool activity
foreman logs <run-id> --compact        # Compact event-backed tail, no message_update noise
foreman logs <run-id> --plain          # Alias for --compact
foreman logs <run-id> --view plain     # Explicit plain compact view
foreman logs <run-id> --raw --tail 200 # Raw JSON tail
```

| Option | Description |
|--------|-------------|
| `--run <id>` | Run ID, overriding the positional task/run ID |
| `--tail <n>` | Number of entries/lines to show (applied after `message_update` filtering in compact/plain view) |
| `--compact` | Fetch the compact event-backed view and strip `message_update` noise |
| `--plain` | Alias for `--compact`; also used by `--view plain` for human-readable compact output |
| `--view <compact|plain|raw>` | Select event-backed log view |
| `--raw` | Print raw worker JSON log lines |
| `--follow` | Follow the raw worker log after the summary |

### `foreman doctor`

Health checks for Foreman installation. Validates br binary, Pi SDK, DB integrity, prompt files, workflow configs, and duplicate workflow YAML `task_type` declarations.

```bash
foreman doctor                    # Run all health checks
foreman doctor --fix              # Auto-fix issues
foreman doctor --dry-run          # Preview fixes without applying
foreman doctor --json             # Machine-readable output
```

| Option | Description |
|--------|-------------|
| `--fix` | Auto-fix issues (install missing prompts, migrate stores, etc.) |
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
| `--port <port>` | Override local HTTP port (default `4766`) |
| `--no-auto-start` | For `doctor`, fail instead of starting a stopped server |

`server doctor` validates event-store readability, projection catch-up/lag, worker projections, VCS adapters, provider adapters, and integration projections. The JSON output includes counters/timers for phase duration, retries, failures, recoveries, worker restarts, circuit breaker hits, QA environment blocks, and projection lag. The `/api/v1/pipeline-metrics` endpoint also exposes `retry_details` (stuck/blocked by reason) and `blocked_by_reason` as top-level shortcuts. When server auth is enabled, set `FOREMAN_SERVER_AUTH_TOKEN` so doctor/metrics calls send the bearer token. Binding the Elixir HTTP server beyond loopback also requires this token. Worker starts strip forbidden host variables (`FOREMAN_SERVER_AUTH_TOKEN`, `AWS_*`, `GITHUB_*`, `NPM_*`, `SSH_*`, `DATABASE_*`) and scope explicit project/run secrets to the run. Destructive server commands record `AuthorizationChecked` and `AuditRecorded` events.

Elixir backend roles: the **Node CLI** parses commands/renders projections, the **Elixir server** owns commands/events/projections/recovery/security, automatically ticks the scheduler every 5 seconds to reconcile active runs with terminal worker-log markers, claim `ready` tasks within capacity, and launch the Node/Pi worker bridge, and **Node/Pi workers** execute Pi SDK phases and stream worker events. If an Elixir-backed view is wrong, inspect the event timeline first, then projection lag/rebuild state, then recovery events (`ExternalWorkerObserved` before `WorkerReattached`, `WorkerRestarted`, or `NeedsOperator`). After cutover, Elixir is the default backend; `foreman daemon start|restart` fails fast and directs operators to `foreman server start` unless `FOREMAN_BACKEND=node` is set explicitly. See [Elixir Backend Architecture](./guides/elixir-backend-architecture.md).

### `foreman reset`

Reset failed or stuck runs. By default this cleans up worktrees, deletes branches, and resets task status to a dispatchable state. Use `--preserve-worktree`/`--retry-failed-phase` for focused repair when you want to keep the current branch and worktree after a phase failure; preserved worktrees refresh their `.foreman/workflows` and `.foreman/prompts` from the project before redispatch.

```bash
foreman reset                     # Reset all failed/stuck runs
foreman reset --project my-project # Reset runs in a registered project without cd
foreman reset --task bd-abc1      # Reset a specific task by ID
foreman reset --all               # Reset ALL active runs (nuclear option)
foreman reset --detect-stuck      # Find and reset stuck agents
foreman reset --preserve-worktree --task bd-abc1  # Reset state but keep branch/worktree
foreman reset --retry-failed-phase --task bd-abc1 # Alias for focused phase repair reset
foreman reset --dry-run           # Preview what would be reset
```

| Option | Default | Description |
|--------|---------|-------------|
| `--task <id>` | — | Reset a specific task's runs |
| `--bead <id>` | — | Alias for `--task` (backward compatibility) |
| `--all` | — | Reset ALL active runs |
| `--detect-stuck` | — | Run stuck detection first |
| `--timeout <minutes>` | `15` | Stuck detection timeout |
| `--dry-run` | — | Preview changes |
| `--preserve-worktree` | — | Reset task/run state without removing the worktree or branch; refreshes preserved `.foreman/workflows` and `.foreman/prompts` |
| `--retry-failed-phase` | — | Focused repair reset; preserves the worktree and branch for the next dispatch and refreshes workflow/prompt config |
| `--project <name-or-path>` | — | Target a registered project name or absolute project path |

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

### `foreman stop`

Gracefully stop running agents.

```bash
foreman stop                      # Stop all running agents
foreman stop bd-abc1              # Stop a specific task's agent
foreman stop --list               # List active runs
foreman stop --force              # Force kill with SIGKILL
foreman stop --dry-run            # Preview
```

| Option | Description |
|--------|-------------|
| `--list` | List active runs without stopping |
| `--force` | Force kill with SIGKILL instead of graceful shutdown |
| `--dry-run` | Preview without stopping |

---

## Merging & PRs

### `foreman merge`

Merge completed agent work into the target branch via the refinery. For PR-gated workflows, merge rechecks PR readiness and waits if GitHub surfaces a late pending check after `pr-wait`. If GitHub CLI PR merge authentication fails, Foreman falls back to its direct VCS merge path for the same branch; if a PR was merged manually, the PR merge event marks the linked run and task as `merged` in projections.

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
| `--bead <id>` | — | Alias for `--task` (backward compatibility) |
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

Initial tools include one-call smoke status, health, scheduler status/tick, projects, tasks, approvals, runs, logs, inbox, lifecycle events, and debug timelines. MCP reads/writes through the Elixir backend only. `foreman.runs.logs` tails raw worker `.log/.err/.out` files when present, which is the best source for fatal stacks, provider overloads, QA evidence failures, and phase-loop diagnostics. The project-local Pi extension exposes common slash commands (`/foreman-smoke`, `/foreman-tasks`, `/foreman-task`, `/foreman-approve`, `/foreman-runs`, `/foreman-logs`, `/foreman-inbox`, `/foreman-events`, `/foreman-scheduler`, `/foreman-tick`) backed by these tools. See [MCP Server](./mcp-server.md) for design and future remote-use cases.

---

## Agent Mail

### `foreman inbox`

View the Agent Mail inbox — messages sent between pipeline phases and the foreman orchestrator. In Elixir/default backend mode, inbox reads the shared Postgres run/message/event tables directly and does not require the Node daemon socket. A selected run shows its current lifecycle status and recent lifecycle events by default so terminal failures/completions are visible even when no agent message was written.

```bash
foreman inbox                     # Show latest run's messages
foreman inbox --task bd-abc1      # Messages for a specific task by ID
foreman inbox --all --watch       # Live stream ALL messages across all runs
foreman inbox --watch             # Live stream latest run's messages
foreman inbox --unread            # Show only unread messages
foreman inbox --limit 100         # Show more messages
foreman inbox --ack               # Mark shown messages as read
```

| Option | Default | Description |
|--------|---------|-------------|
| `--agent <name>` | all | Filter to specific agent/role |
| `--run <id>` | latest | Filter to specific run ID |
| `--task <id>` | — | Resolve run by task ID |
| `--bead <id>` | — | Alias for `--task` (backward compatibility) |
| `--all` | — | Show/watch messages across all runs |
| `--watch` | — | Poll every 2 seconds for new messages |
| `--unread` | — | Show only unread messages |
| `--limit <n>` | `50` | Maximum messages to show |
| `--ack` | — | Mark shown messages as read |
| `--events` | — | Show an expanded pipeline event section |
| `--events-limit <n>` | `50` | Maximum lifecycle events to show |

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
foreman sling trd docs/TRD.md --br-only  # Compatibility path: write to beads_rust only
```

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview without creating tasks |
| `--auto` | Skip confirmation prompts |
| `--json` | Output parsed structure as JSON |
| `--br-only` | Compatibility path: write to beads_rust only |
| `--skip-completed` | Skip `[x]` completed tasks |
| `--close-completed` | Create and immediately close `[x]` tasks |
| `--no-parallel` | Disable parallel sprint detection |
| `--force` | Recreate tasks even if they exist |
| `--no-risks` | Skip risk register items |
| `--no-quality` | Skip quality requirements |

### `foreman task create`

Create a new task in backlog status, or generate task(s) from a natural-language description with `--from-text` (replaces the deprecated `foreman bead`, which remains as a hidden alias).

```bash
foreman task create --title "Fix login timeout" --type bug --priority 1
foreman task create --from-text "Fix the login timeout bug"
foreman task create --from-text docs/issue.md       # From a file
foreman task create --from-text "..." --parent bd-abc1  # Set parent task ID
foreman task create --from-text "..." --dry-run     # Preview
foreman task create --from-text "..." --no-llm      # Skip AI parsing (text becomes the title)
```

| Option | Default | Description |
|--------|---------|-------------|
| `--title <text>` | — | Task title (required unless `--from-text` is used) |
| `--description <text>` | — | Optional task description |
| `--type <type>` | `task` | Task type: `task`, `bug`, `feature`, `epic`, `chore`, `docs`, `question` |
| `--priority <level>` | `medium` | Priority: `0`–`4` or `critical`/`high`/`medium`/`low`/`backlog` |
| `--from-text <description>` | — | Create task(s) from a natural-language description (or file path) using an LLM |
| `--parent <id>` | — | Parent task ID (only with `--from-text`) |
| `--dry-run` | — | Preview without creating (only with `--from-text`) |
| `--no-llm` | — | Skip LLM parsing — create a single task with the text as title (only with `--from-text`) |
| `--model <model>` | — | Claude model for AI parsing (only with `--from-text`) |
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
| `--from-node` | Build the migration payload from the current Node/Postgres project selected by `--project` / `--project-path` |
| `--command-id <id>` | Explicit server command id for idempotent retries |
| `--no-auto-start` | Require an already-running Elixir server |

While migration is incomplete, compatibility mode can delegate these commands to a legacy TS Foreman binary: `run`, `status`, `watch`, `reset`, `retry`, `stop`, `merge`, `pr`, `attach`, `inbox`, `task`, `plan`, `sling`, `doctor`.

```bash
FOREMAN_LEGACY_COMPATIBILITY_MODE=1 \
FOREMAN_LEGACY_TS_BIN=/path/to/legacy/foreman \
foreman run
```

Elixir is the default backend after cutover, so legacy delegation is disabled and `foreman daemon start|restart` cannot launch the Node scheduler unless `FOREMAN_BACKEND=node` is set explicitly. Use `foreman server start` for the Elixir backend; set `FOREMAN_BACKEND=node` only for explicit legacy operation. Elixir cutover parity: `foreman board` uses Elixir task projections and task commands; remaining daemon-backed commands fail before socket access with an explicit parity-gap message until their Elixir route lands.

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

> **Removed commands:** `foreman monitor` has been removed — use `foreman reset --detect-stuck` instead. `foreman mail send` has been removed — use `foreman inbox send`.
