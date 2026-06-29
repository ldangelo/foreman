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

During Elixir migration, incomplete legacy command coverage can be delegated with `FOREMAN_LEGACY_COMPATIBILITY_MODE=1` and `FOREMAN_LEGACY_TS_BIN=/path/to/legacy/foreman` only when `FOREMAN_BACKEND=node` is set. Elixir is the default after cutover; it disables legacy TS delegation and blocks legacy daemon/scheduler commands so the Node scheduler cannot run beside the Elixir scheduler. Elixir-backed CLI reads such as status/debug/recover/attach/Jira start the local server before using HTTP projections and fail closed rather than reading stale legacy daemon/local stores when projections are unavailable.

---

## Project Setup

### `foreman init`

Initialize Foreman in a project. Creates `.foreman/` directory, installs default workflow configs/prompts, and registers the project in the default Elixir project registry. With `FOREMAN_BACKEND=node`, registration uses the legacy Postgres store.

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

### `foreman project add|list|edit|remove|sync`

Clone/register, list, sync, and update project settings through the active backend. In Elixir mode, `add` clones with `gh repo clone` into `~/.foreman/projects/<project-id>` and registers the project through the Elixir command API; `list`, `edit`, `remove`, and `sync` use the Elixir projection/command API; `remove` archives the project.

```bash
foreman project add owner/repo --name my-project
foreman project list --status active
foreman project edit <project-id> --default-branch dev
foreman project sync <project-id>
foreman project remove <project-id>
```

| Option | Description |
|--------|-------------|
| `foreman project add <github-url>` | Clone/register a GitHub repo (`owner/repo`, HTTPS, or SSH) |
| `foreman project add --name <name>` | Project display name |
| `foreman project add --default-branch <branch>` | Override detected default branch |
| `foreman project list --status <status>` | Filter by `active`, `paused`, or `archived` |
| `foreman project list --search <term>` | Search by project name |
| `foreman project list --json` | Emit JSON |
| `foreman project edit --name <name>` | Project display name |
| `foreman project edit --status <status>` | Project status: `active`, `paused`, or `archived` |
| `foreman project edit --default-branch <branch>` | Default/base branch for new project worktrees |
| `foreman project sync <project-id>` | Fetch the registered checkout and update `last_sync_at` in the active backend |
| `foreman project remove --force` | Accepted for legacy compatibility; Elixir archives by project ID |

---

## Dispatching Work

### `foreman run`

Tick the Elixir scheduler for ready tasks by default. In default Elixir mode, `foreman run` starts/connects to the local Elixir server, invokes one scheduler tick, and reports claimed runs from projections; `foreman run --dry-run` prints a read-only scheduler preview. Set `FOREMAN_BACKEND=node` for the legacy Node dispatcher.

Default workflows are YAML-defined phase/action sequences, including dispatcher workspace actions before agent launch. Workflow YAML resolves from explicit path, project `.foreman/workflows` (`.yaml|.yml`), global `~/.foreman/workflows` (`.yaml|.yml`), then bundled defaults; project-relative explicit paths must stay inside the project root. Use `foreman workflows list|show|validate|install|create` to inspect, validate, install, or create project/global workflow YAML. Editable action modules in `.foreman/actions/*.js|*.mjs|*.ts` or `~/.foreman/actions/*.js|*.mjs|*.ts` are bundled and loaded at runtime when present (project wins), so JS/MJS actions may import TS helper files kept outside the actions directory (every direct `.js`/`.mjs`/`.ts` file there is treated as an action); `foreman init`, `FOREMAN_BACKEND=node foreman doctor --fix`, and `foreman actions install [--global]` install bundled stubs. `foreman actions list` shows resolution, `foreman actions show <action>` prints one resolved path, `foreman actions validate` checks project/global action module names, JS/TS syntax/import resolution, function exports, duplicate `.js`/`.mjs`/`.ts` variants, and unresolved workflow action references, `foreman actions create <action> [--global]` creates a new stub (action names may contain letters, numbers, `.`, `_`, and `-`, with at least one letter/number; known builtin/workspace actions wrap `ctx.internal.runBuiltin()` by default), and legacy `FOREMAN_BACKEND=node foreman doctor` validates the same action issues. The bundled `qlty` action runs `qlty check` (qlty CLI from https://qlty.sh/ must be on `PATH`), writes `QLTY_REPORT.md`, and bundled developer workflows retry Developer when it fails. Before retrying a target phase or forwarding an artifact to a phase, Foreman writes a normalized `{TARGET_PHASE}_TASK.md` input file in the run report directory (for example `DEVELOPER_TASK.md`) with the source phase/artifact, failure, retry attempt, and feedback content. The bundled fast path has Explorer (when present) hand off directly to Developer, then QA/review/finalize/documentation. TDD red/review phases are opt-in via `foreman run --workflow tdd`, a `workflow:tdd` label, or task type `tdd`. In the TDD workflow, `test-red` writes at most a few focused failing tests and `test-review` verifies those tests cover the acceptance contract and fail for the expected missing behavior, with one Red retry. Direct task runs write `TASK.md` into the worktree before spawning agents. Explorer, Developer, and QA phases are handoff-driven and use phase overwatch/tool telemetry to block broad repo discovery, Developer test execution, full-suite QA runs, and runaway work before the `maxTurns` emergency fuse. Before QA, Foreman gates Developer completion on report self-check evidence, acceptance-contract coverage from `EXPLORER_REPORT.md`, actual git diff, claimed file existence, required docs/tests (or an explicit no-docs-needed self-check), and TypeScript compilation when TS/JS files changed. Runtime preflight also fails on stale project/global prompt overrides that are missing required acceptance-contract markers. Verdict phases with `contract.policy.acceptanceCoverage` must carry and address the Explorer acceptance criteria; missing coverage overrides PASS to FAIL and is recorded as phase failure/retry events. Phase reports are preserved as attempt-numbered copies (`REPORT.attempt-N.md`) with `RETRY_ATTEMPTS.md` listing them.

```bash
foreman run                                            # Tick Elixir scheduler once and report claimed runs
foreman run --no-watch                                 # Tick once without follow-up guidance
foreman run --dry-run                                  # Elixir scheduler preview from projections
foreman run --dry-run --task task-abc                  # Preview a specific Elixir task
FOREMAN_BACKEND=node foreman run                       # Dispatch all ready legacy tasks (up to max-agents)
FOREMAN_BACKEND=node foreman run --project my-project  # Dispatch against a registered legacy project without cd
FOREMAN_BACKEND=node foreman run --task bd-abc1        # Dispatch a specific legacy task by ID
FOREMAN_BACKEND=node foreman run --dry-run             # Preview legacy dispatch
FOREMAN_BACKEND=node foreman run --max-agents 3        # Limit concurrent agents to 3
FOREMAN_BACKEND=node foreman run --resume              # Resume stuck/rate-limited runs
FOREMAN_BACKEND=node foreman run --resume-failed       # Also resume permanently failed runs
FOREMAN_BACKEND=node foreman run --no-watch            # Dispatch once and exit (don't monitor)
FOREMAN_BACKEND=node foreman run --yes                 # Auto-confirm run prompts for non-interactive use
FOREMAN_BACKEND=node foreman run --no-pipeline         # Single agent mode (no explorer/qa/reviewer)
FOREMAN_BACKEND=node foreman run --workflow quick      # Run all dispatched tasks with the quick workflow
FOREMAN_BACKEND=node foreman run --workflow tdd        # Opt into Red/Test Review before Developer
FOREMAN_BACKEND=node foreman run --model anthropic/claude-opus-4-6  # Force a specific model
```

| Option | Default | Description |
|--------|---------|-------------|
| `--task <id>` | — | Dispatch only this specific task ID (must be ready) |
| `--bead <id>` | — | Alias for `--task` (backward compatibility) |
| `--max-agents <n>` | `5` | Maximum concurrent agents |
| `--model <model>` | — | Force a specific model for all phases |
| `--dry-run` | — | In Elixir mode, preview scheduler candidates from projections; in Node mode, show what legacy dispatch would run |
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

Run a specific task with an explicit workflow. In default Elixir mode, Foreman writes a `task.update` event (`status=ready`, selected `workflow`) and ticks the Elixir scheduler; the scheduler owns worker launch. Set `FOREMAN_BACKEND=node` only for the legacy direct worker bridge.

```bash
foreman run task foreman-12345 task --project foreman --no-watch
foreman run task foreman-12345 ~/.foreman/workflows/task.yaml --dry-run
FOREMAN_BACKEND=node foreman run task foreman-12345 task --project foreman --no-watch
```

| Option | Default | Description |
|--------|---------|-------------|
| `--model <model>` | workflow default | Override the model used by spawned worker phases |
| `--dry-run` | — | Resolve task/workflow and preview the scheduler request without writing Elixir events; legacy Node also avoids creating a run |
| `--no-watch` | — | Return after scheduler claim/worker spawn instead of showing follow-up guidance |
| `--target-branch <branch>` | detected default | Override base/target branch for finalization and merge |
| `--project <name>` | current project | Registered project name |
| `--project-path <absolute-path>` | current project | Absolute project path for advanced/scripted use |

> **Deprecated:** `--skip-explore` and `--skip-review` are hidden no-ops here too — pick a workflow without those phases instead (e.g. `foreman run task <task-id> quick`).

---

## Monitoring

### `foreman status`

Show project status: task counts, active agents, cost breakdown, and tool usage. In default Elixir mode, status reads Elixir task/run projections and fails closed if projections are unavailable; set `FOREMAN_BACKEND=node` for legacy daemon/local status.

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

Show per-phase pipeline metrics from the Elixir server by default. In default Elixir mode, `--compact` emits pipeline counters as single-line `key=value` output and `--costs` derives cost totals from Elixir phase projections. Legacy Node cost metrics remain available only with `FOREMAN_BACKEND=node`.

```bash
foreman metrics                         # Human-readable pipeline metrics dashboard
foreman metrics --json                  # Raw pipeline metrics JSON from the server
foreman metrics --compact               # Pipeline counters as single-line key=value output
foreman metrics --costs                 # Elixir-derived phase cost summary
foreman metrics --costs --compact --phase developer # Single-line Elixir phase cost summary
FOREMAN_BACKEND=node foreman metrics --costs                 # Legacy task-store cost/token metrics summary
FOREMAN_BACKEND=node foreman metrics --costs --json          # Legacy cost/token JSON with timestamp/projectId
foreman metrics --project my-project    # Metrics for a registered project
foreman metrics --project-path /abs/path # Metrics for a project at an absolute path
```

| Option | Default | Description |
|--------|---------|-------------|
| `--json` | — | Output JSON: pipeline JSON by default, Elixir-derived cost JSON in cost mode |
| `--compact` | — | Output Elixir pipeline or cost counters as single-line `key=value`; with `FOREMAN_BACKEND=node`, output legacy cost/token metrics as `key=value` |
| `--costs` | — | Show Elixir-derived phase cost metrics instead of the full pipeline dashboard |
| `--since <iso-timestamp>` | — | Include filter context for cost output; legacy Node mode applies it to task-store metrics |
| `--phase <phase-name>` | — | Filter Elixir cost output to a specific phase (explorer, developer, qa, reviewer, finalize); legacy Node mode applies it to task-store metrics |
| `--agent <type>` | — | Include agent filter context; legacy Node mode applies it to task-store metrics |
| `--task-type <type>` | — | Include task-type filter context; legacy Node mode applies it to task-store metrics |
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
foreman watch                     # Live unified dashboard (Elixir projections by default)
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

Legacy continuous QA testing agent that monitors a branch for test failures and auto-creates follow-up fix tasks. Default Elixir mode allows read-only `sentinel status`/`sentinel list` compatibility views and blocks mutating/agent commands; use Elixir scheduler/status/recover flows by default, or set `FOREMAN_BACKEND=node` for legacy sentinel.

```bash
# Run once
FOREMAN_BACKEND=node foreman sentinel run-once
FOREMAN_BACKEND=node foreman sentinel run-once --branch dev --test-command "npm test"
FOREMAN_BACKEND=node foreman sentinel run-once --dry-run

# Start background daemon
FOREMAN_BACKEND=node foreman sentinel start
FOREMAN_BACKEND=node foreman sentinel start --interval 15 --failure-threshold 3

# Check sentinel status
foreman sentinel status                     # Elixir compatibility status
foreman sentinel list --json                # Elixir project compatibility list
FOREMAN_BACKEND=node foreman sentinel status
FOREMAN_BACKEND=node foreman sentinel status --json --limit 20

# Stop background daemon
FOREMAN_BACKEND=node foreman sentinel stop
FOREMAN_BACKEND=node foreman sentinel stop --force
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

Operator traceability dashboard for active Foreman runs. In default Elixir mode this reads Elixir run projections directly. Legacy Node/local run stores require `FOREMAN_BACKEND=node`. Lists pending/running runs with task ID, phase, elapsed time, last activity, and stuck/fatal indicators.

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

AI-powered execution analysis. Gathers all artifacts (logs, mail, reports, run progress) for a task and sends them to an AI model for deep-dive diagnostics. In Elixir-backed projects, run lookup, inbox, reports, and raw logs are read from the Elixir HTTP API; missing/unavailable Elixir projections fail closed instead of reading legacy daemon/local stores.

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
- Elixir raw/event log projections
- Elixir task/run metadata

### `foreman recover`

Autonomous recovery for failed/stuck tasks. In Elixir-backed projects, recovery context uses Elixir run, inbox, report, and raw log projections and fails closed when those projections are unavailable; set `FOREMAN_BACKEND=node` for legacy recovery context.

```bash
foreman recover bd-abc1 --raw
foreman recover bd-abc1 --reason finalize-conflict --prepare-clean-replay
```

### `foreman logs`

Show run logs and debugging summaries. Compact/plain/raw event views read from the Elixir server and do not require local `~/.foreman/logs/<run>.log` files; in Elixir mode the default summary falls back to the compact event view when the local worker log is absent. `--follow` still requires local worker log files.

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
| `--raw` | Print raw worker JSON log lines, falling back to the Elixir raw event view when the local file is absent |
| `--follow` | Follow the raw worker log after the summary (legacy Node backend only; Elixir mode fails closed) |

### `foreman doctor`

Health checks for Foreman installation. In default Elixir mode, `foreman doctor` runs the Elixir server/projection/worker health check (same backend as `foreman server doctor`) and renders a human summary by default. Use `--json` or `--raw` for the raw server response. `foreman doctor --clean-logs --dry-run` delegates to the Elixir log-cleanup preview without deleting files. Legacy Node/Postgres maintenance flags require `FOREMAN_BACKEND=node`.

```bash
foreman doctor                                    # Elixir health checks
foreman doctor --json                             # Machine-readable Elixir health
foreman doctor --raw                              # Raw Elixir server doctor response
foreman doctor --clean-logs --dry-run             # Elixir-backed log cleanup preview
foreman server doctor                             # Explicit Elixir server health checks
FOREMAN_BACKEND=node foreman doctor               # Run legacy health checks
FOREMAN_BACKEND=node foreman doctor --fix         # Auto-fix legacy issues
FOREMAN_BACKEND=node foreman doctor --dry-run     # Preview legacy fixes without applying
```

| Option | Description |
|--------|-------------|
| `--fix` | Auto-fix issues (install missing prompts, migrate stores, etc.) |
| `--dry-run` | Preview what --fix would do; with `--clean-logs` in Elixir mode, preview log cleanup without deleting files |
| `--json` | Output as JSON |
| `--raw` | Output the raw Elixir server doctor response |

### `foreman actions`

Manage workflow action modules. Project modules live in `.foreman/actions`; global modules live in `~/.foreman/actions`; project wins over global, and both win over bundled implementations. Bundled built-ins include `qlty`, which runs `qlty check` when the qlty CLI is installed. Modules are bundled with esbuild before runtime load, so JS/MJS actions may import TS helpers kept outside the actions directory; every direct `.js`/`.mjs`/`.ts` file in an actions directory is validated as an action.

```bash
foreman actions list                    # Show bundled/project/global resolution
foreman actions show finalize           # Show resolved module path/source
foreman actions validate                # Validate names, JS/TS syntax/imports, function exports, duplicate variants, and workflow refs
foreman actions install                 # Install bundled stubs into .foreman/actions
foreman actions install --global        # Install bundled stubs into ~/.foreman/actions
foreman actions create notify-slack     # Create .foreman/actions/notify-slack.js
foreman actions create notify-slack --global  # Create ~/.foreman/actions/notify-slack.js
```

| Subcommand | Description |
|------------|-------------|
| `list [--json]` | List known action names and whether project, global, bundled, or missing resolves |
| `show <action> [--json]` | Show one action's resolved source/path; exits nonzero when missing or unsafe |
| `validate [--json]` | Validate project/global module names, JS/TS syntax/import resolution, function exports, duplicate `.js`/`.mjs`/`.ts` variants, and unresolved workflow action refs |
| `install [--force] [--global] [--json]` | Install bundled editable stubs; `--force` overwrites existing files |
| `create <action> [--force] [--global] [--json]` | Create a custom action stub; `--force` overwrites existing files |

### `foreman workflows`

Manage workflow YAML files. Project workflows live in `.foreman/workflows`; global workflows live in `~/.foreman/workflows`; project wins over global, and both win over bundled defaults.

```bash
foreman workflows list                    # Show bundled/project/global resolution
foreman workflows show default            # Show resolved workflow path/source
foreman workflows validate                # Validate loadable workflow YAML
foreman workflows install                 # Install bundled YAML into .foreman/workflows
foreman workflows install --global        # Install bundled YAML into ~/.foreman/workflows
foreman workflows create custom-flow      # Create .foreman/workflows/custom-flow.yaml
foreman workflows create custom-flow --global  # Create ~/.foreman/workflows/custom-flow.yaml
```

| Subcommand | Description |
|------------|-------------|
| `list [--json]` | List workflow names and whether project, global, bundled, or missing resolves |
| `show <workflow> [--json]` | Show one workflow's resolved source/path; exits nonzero when missing |
| `validate [--json]` | Validate loadable project, global, and bundled workflow YAML, unsafe filenames/names, duplicate `.yaml`/`.yml` variants, phase references, numeric controls, malformed/duplicate `task_type` declarations, and duplicate `taskPhases`/`finalPhases` entries |
| `install [--force] [--global] [--json]` | Install bundled editable YAML; `--force` overwrites existing files |
| `create <workflow> [--force] [--global] [--json]` | Create a workflow YAML stub; workflow names may contain letters, numbers, `.`, `_`, and `-`, with at least one letter/number; `--force` overwrites existing files |

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

Elixir backend roles: the **Node CLI** parses commands/renders projections, the **Elixir server** owns commands/events/projections/recovery/security, automatically ticks the scheduler every 5 seconds to reconcile active runs with terminal worker-log markers, claim `ready` tasks within capacity, and launch the Node/Pi worker bridge, and **Node/Pi workers** execute Pi SDK phases and stream worker events. If an Elixir-backed view is wrong, inspect the event timeline first, then projection lag/rebuild state, then recovery events (`ExternalWorkerObserved` before `WorkerReattached`, `WorkerRestarted`, or `NeedsOperator`). After cutover, Elixir is the default backend; `foreman daemon start|stop|status|restart` is a compatibility alias for `foreman server` unless `FOREMAN_BACKEND=node` is set explicitly. See [Elixir Backend Architecture](./guides/elixir-backend-architecture.md).

### `foreman reset`

Reset failed/stuck runs. In default Elixir mode, `foreman reset` records `run.reset` events and requeues matching tasks through Elixir task projections; `--dry-run` gives a read-only projection preview. Set `FOREMAN_BACKEND=node` for the legacy run/task/merge-queue cleanup path.

```bash
foreman reset                                          # Elixir-backed reset/requeue for failed/stuck runs
foreman reset --task task-abc                          # Reset one Elixir task/run
foreman reset --dry-run                                # Elixir-backed reset/recovery preview
foreman reset --dry-run --task task-abc                # Preview one Elixir task/run
FOREMAN_BACKEND=node foreman reset                     # Reset all failed/stuck legacy runs
FOREMAN_BACKEND=node foreman reset --project my-project # Reset runs in a registered project without cd
FOREMAN_BACKEND=node foreman reset --task bd-abc1      # Reset a specific task by ID
FOREMAN_BACKEND=node foreman reset --all               # Reset ALL active runs (nuclear option)
FOREMAN_BACKEND=node foreman reset --detect-stuck      # Find and reset stuck agents
FOREMAN_BACKEND=node foreman reset --preserve-worktree --task bd-abc1  # Reset state but keep branch/worktree
FOREMAN_BACKEND=node foreman reset --retry-failed-phase --task bd-abc1 # Alias for focused phase repair reset
FOREMAN_BACKEND=node foreman reset --dry-run           # Preview what would be reset
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

Reset a task and optionally queue it for immediate scheduler dispatch. In default Elixir mode, retry writes task/run events through the Elixir command API; `--dispatch` marks the task ready for the scheduler's next tick.

```bash
foreman retry bd-abc1             # Reset task to ready
foreman retry bd-abc1 --project my-project  # Retry inside a registered project without cd
foreman retry bd-abc1 --dispatch  # Reset and dispatch immediately
foreman retry bd-abc1 --model anthropic/claude-opus-4-6  # Override model
foreman retry bd-abc1 --dry-run   # Preview
```

| Option | Description |
|--------|-------------|
| `--dispatch` | Dispatch immediately after reset (Elixir: ready task is picked up on the scheduler's next tick) |
| `--model <model>` | Override the agent model |
| `--dry-run` | Show what would happen |
| `--project <name-or-path>` | Target a registered project name or absolute project path |

### `foreman stop`

Stop or list active runs. In default Elixir mode, `foreman stop` reads Elixir run projections, sends SIGTERM/SIGKILL when a worker PID is projected, and records a `run.fail` event with operator stop context; `--list` reads active run projections and `--dry-run` previews matching runs. Set `FOREMAN_BACKEND=node` for the legacy run-store/process stop path.

```bash
foreman stop                                           # Stop active Elixir runs via projected worker/event state
foreman stop --force                                   # Use SIGKILL for projected worker PID
foreman stop --list                                    # List active Elixir runs
foreman stop --dry-run                                 # Preview active Elixir runs matched for stop
foreman stop <run-or-task> --dry-run                   # Preview one Elixir run/task stop match
FOREMAN_BACKEND=node foreman stop                      # Stop all running legacy agents
FOREMAN_BACKEND=node foreman stop bd-abc1              # Stop a specific legacy task's agent
FOREMAN_BACKEND=node foreman stop --list               # List active legacy runs
FOREMAN_BACKEND=node foreman stop --force              # Force kill with SIGKILL
FOREMAN_BACKEND=node foreman stop --dry-run            # Preview
```

| Option | Description |
|--------|-------------|
| `--list` | List active runs without stopping |
| `--force` | Force kill with SIGKILL instead of graceful shutdown |
| `--dry-run` | Preview without stopping |

---

## Merging & PRs

### `foreman merge`

Legacy Node Refinery merge queue. In default Elixir mode, merge/PR state is handled by the Elixir scheduler/finalize workflow; `--list`, `--dry-run`, and `--stats` provide projection-backed read-only visibility, while actual merge operations require `FOREMAN_BACKEND=node`.

```bash
FOREMAN_BACKEND=node foreman merge                     # Process merge queue
FOREMAN_BACKEND=node foreman merge --task bd-abc1      # Merge a specific task by ID
foreman merge --list                                   # Elixir projection-backed merge candidates
foreman merge --dry-run                                # Elixir read-only merge readiness preview
foreman merge --stats                                  # Elixir merge readiness summary
FOREMAN_BACKEND=node foreman merge --list              # List legacy merge queue entries
FOREMAN_BACKEND=node foreman merge --dry-run           # Preview legacy merge operations
FOREMAN_BACKEND=node foreman merge --target-branch dev # Merge into dev instead of main
FOREMAN_BACKEND=node foreman merge --no-tests          # Skip test validation
FOREMAN_BACKEND=node foreman merge --stats             # Show legacy merge cost statistics
FOREMAN_BACKEND=node foreman merge --stats weekly      # Weekly cost breakdown
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

Elixir mode shows projection-backed PR candidates from completed runs; PR creation remains owned by the Elixir scheduler/finalize workflow. Set `FOREMAN_BACKEND=node` for explicit legacy Refinery PR creation.

```bash
foreman pr                                             # Show Elixir PR candidates
foreman pr --json                                      # JSON candidate view
FOREMAN_BACKEND=node foreman pr                        # Create PRs for all completed tasks
FOREMAN_BACKEND=node foreman pr --draft                # Create as draft PRs
FOREMAN_BACKEND=node foreman pr --base-branch dev      # PR against dev instead of main
```

| Option | Default | Description |
|--------|---------|-------------|
| `--base-branch <branch>` | `main` | Base branch for PRs |
| `--draft` | — | Draft flag for legacy PR creation; echoed in Elixir candidate JSON |
| `--json` | — | Output Elixir PR candidates as JSON |

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

View the Agent Mail inbox — messages sent between pipeline phases and the foreman orchestrator. In Elixir/default backend mode, inbox reads Elixir inbox/run/event projections through the HTTP API and does not require the Node daemon socket. A selected run shows its current lifecycle status and recent lifecycle events by default so terminal failures/completions are visible even when no agent message was written.

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

`inbox send` records an operator-to-worker message in the Elixir inbox stream by default. The message is stored even when direct worker delivery is unsupported; inspect `delivery_status` in the inbox projection for delivery state. `foreman inbox --ack` records Elixir read markers, so later `--unread` views hide acknowledged messages.


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

Run the Ensemble PRD → TRD pipeline. In default Elixir mode, bare `foreman plan <description>` submits server-backed `plan.prd` and `plan.trd` commands; use `foreman plan prd` / `foreman plan trd` to run one stage. Set `FOREMAN_BACKEND=node` only for the legacy local planning dispatcher.

```bash
foreman plan "Add user authentication with OAuth"      # Elixir PRD + TRD planning
foreman plan docs/description.md                       # From a file
foreman plan "..." --prd-only                          # Stop after PRD generation
foreman plan --from-prd docs/PRD.md "unused"           # Start from existing PRD
foreman plan "..." --output-dir docs/auth              # Custom output directory
foreman plan "..." --dry-run                           # Preview server planning commands
FOREMAN_BACKEND=node foreman plan "..."                # Legacy local planner
foreman plan prd "Add user authentication"   # Server-backed PRD planning
foreman plan trd docs/PRD.md                  # Server-backed TRD planning
```

Bare `foreman plan`, `foreman plan prd`, and `foreman plan trd` submit `plan.prd` / `plan.trd` commands to the local Elixir orchestration server. Explicit subcommands auto-start the server by default; use `--no-auto-start` to require an already-running server.

| Option | Default | Description |
|--------|---------|-------------|
| `--prd-only` | — | Stop after PRD generation |
| `--from-prd <path>` | — | Start from an existing PRD file |
| `--output-dir <dir>` | `./docs` | Output directory for PRD/TRD |
| `--runtime <runtime>` | `claude-code` | AI runtime (`claude-code` or `codex`) |
| `--dry-run` | — | Show steps without executing |

Server-backed `plan prd` / `plan trd` options: `--project <path>`, `--output-dir <dir>`, `--provider <provider>`, `--run-id <id>`, `--command-id <id>`, `--no-auto-start`.

### `foreman sling trd`

Convert a Technical Requirements Document into a native task hierarchy with dependencies. Default Elixir mode writes task/dependency events through the Elixir server; `FOREMAN_BACKEND=node` uses the legacy daemon writer.

```bash
foreman sling trd docs/TRD.md    # Create Elixir-backed native tasks from TRD
foreman sling trd docs/TRD.md --dry-run  # Preview
foreman sling trd docs/TRD.md --json     # Output parsed structure
foreman sling trd docs/TRD.md --auto     # Skip confirmation prompts
foreman sling trd docs/TRD.md --skip-completed   # Skip [x] items
foreman sling trd docs/TRD.md --close-completed  # Create and close [x] items
FOREMAN_BACKEND=node foreman sling trd docs/TRD.md --auto # Legacy daemon import
```

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview without creating tasks |
| `--auto` | Skip confirmation prompts |
| `--json` | Output parsed structure as JSON |
| `--br-only` | Legacy compatibility no-op; accepted for old scripts |
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

## Issue Tracker Integrations

### `foreman jira`

Configure and inspect Jira monitoring.

```bash
foreman jira configure --api-url https://example.atlassian.net --email ops@example.com --api-token $JIRA_TOKEN --project OPS --start-status Ready --issue-type-workflow task=default
foreman jira status [--json]
foreman jira test --api-url https://example.atlassian.net --email ops@example.com --api-token $JIRA_TOKEN [--json]
foreman jira enable-webhook [--secret-env FOREMAN_JIRA_WEBHOOK_SECRET]
foreman jira disable-webhook
```

In default Elixir mode, `configure`, `enable-webhook`, and `disable-webhook` write accepted integration commands to the Elixir event store, `status` reads those events, and `test` validates credentials directly against Jira without opening the legacy daemon socket. Set `FOREMAN_BACKEND=node` for the legacy daemon-managed Jira poller/webhook implementation.

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
FOREMAN_BACKEND=node foreman run
```

Elixir is the default backend after cutover, so legacy delegation is disabled and `foreman daemon start|stop|status|restart` maps to the Elixir server unless `FOREMAN_BACKEND=node` is set explicitly. Use `foreman server start` for the Elixir backend; set `FOREMAN_BACKEND=node` only for explicit legacy operation. `FOREMAN_PROJECT_LEGACY_FALLBACK=true` is a narrow mixed-cutover escape hatch for project registry fallback when Elixir projections are unavailable or incomplete; prefer fixing/rebuilding Elixir projections instead. Elixir cutover parity: `foreman run` ticks the Elixir scheduler, `foreman board` uses Elixir task projections and task commands, `foreman watch`, `foreman runs`, and `status --live` render Elixir projections, `foreman inbox` reads Elixir inbox projections and `inbox send` writes Elixir operator messages, `foreman attach --list|--stream|--worktree|--kill` reads Elixir run/inbox projections, default attach records an Elixir attach request before resuming exposed Pi sessions, and `attach --kill` records an Elixir `run.fail` event after signaling a projected worker PID when present, `foreman task create|list|show|approve|update|note|close|import` route through Elixir task commands/projections, `task list --show-run|--run-status|--stuck` and `task show` read Elixir run projections for run activity, `task create --from-text` creates Elixir-backed native tasks, dependency add/list/remove are command/projection-backed, `foreman project add|list|edit|remove|sync` route through Elixir project commands/projections, and `foreman jira` avoids legacy daemon socket access for configure/status/test/webhook toggles. Remaining legacy-only paths such as `foreman issue` config/sync/webhook/status Postgres commands, mutating `foreman merge` without `--list/--dry-run/--stats`, and PR creation via `FOREMAN_BACKEND=node foreman pr` fail fast in Elixir mode with an explicit `FOREMAN_BACKEND=node` hint until their Elixir routes land. `foreman issue import` now ingests GitHub issues through Elixir external-trigger events, and `foreman sling trd` imports through Elixir task events by default.

---

## Agent Sessions

### `foreman attach`

Attach to a running or completed agent session to inspect its state. In Elixir mode, `--list`, `--stream`, and `--worktree` read Elixir projections; default attach records an attach request and resumes an exposed Pi session when the worker heartbeat includes one. `--kill` sends SIGTERM to a projected worker PID when present and records an Elixir `run.fail` operator-stop event. `--follow` is a legacy local-file control and requires `FOREMAN_BACKEND=node`.

```bash
foreman attach                    # Attach to latest session
foreman attach bd-abc1            # Attach to a specific task by ID
foreman attach --list             # List attachable sessions
FOREMAN_BACKEND=node foreman attach --follow  # Tail legacy local log file
foreman attach --stream           # Stream Agent Mail messages
foreman attach --worktree         # Open a shell in the agent's worktree
foreman attach --kill <id>                    # Stop via Elixir run event and projected worker PID
FOREMAN_BACKEND=node foreman attach --kill    # Kill legacy agent process
```

| Option | Description |
|--------|-------------|
| `--list` | List attachable sessions |
| `--follow` | Follow log file (legacy Node backend only; Elixir mode fails closed) |
| `--stream` | Stream Agent Mail messages in real time |
| `--worktree` | Open an interactive shell in the worktree |
| `--kill` | Stop the run; Elixir records `run.fail` and signals a projected worker PID, legacy Node kills the local process |

---

## Worktree Management

### `foreman worktree`

Manage git worktrees used by Foreman agents. In default Elixir mode, `worktree list` joins VCS worktrees with Elixir run projections, `worktree clean --dry-run` previews cleanup candidates, and `worktree clean` removes cleanable Foreman worktrees using Elixir projection status while recording `WorktreeCleaned` events. Set `FOREMAN_BACKEND=node` for legacy store-based cleanup.

```bash
foreman worktree list                                  # Show Foreman worktrees with Elixir run metadata
foreman worktree list --json                           # Machine-readable Elixir-backed output
foreman worktree clean                                 # Elixir-backed cleanup + cleanup events
foreman worktree clean --dry-run                       # Elixir-backed cleanup preview only
FOREMAN_BACKEND=node foreman worktree clean            # Remove orphaned worktrees
FOREMAN_BACKEND=node foreman worktree clean --all      # Remove ALL worktrees including active
FOREMAN_BACKEND=node foreman worktree clean --force    # Force-delete branches
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

Cleanup for old agent logs and stale run records. In default Elixir mode, `purge logs` deletes terminal/orphaned log files using Elixir run projections for safety and `purge logs --dry-run` previews candidates without deleting files. `purge runs` archives stale failed Elixir runs whose tasks are closed or gone; `--purge` removes those run projections. The old `foreman purge-logs` and `foreman purge-zombie-runs` spellings remain as hidden deprecated aliases.

#### `foreman purge logs`

Remove old agent log files from `~/.foreman/logs/` based on a retention policy.

```bash
foreman purge logs                                     # Elixir-backed local log cleanup
foreman purge logs --dry-run                           # Elixir-backed local log cleanup preview
foreman purge logs --days 30                           # Custom retention window
FOREMAN_BACKEND=node foreman purge logs                # Legacy log cleanup
FOREMAN_BACKEND=node foreman purge logs --days 30      # Custom retention window
FOREMAN_BACKEND=node foreman purge logs --all          # Delete all terminal-status logs regardless of age
```

| Option | Default | Description |
|--------|---------|-------------|
| `--days <n>` | `7` | Delete logs from runs older than N days |
| `--dry-run` | — | Preview without making changes |
| `--all` | — | Delete all terminal-status logs regardless of age (use with caution) |

#### `foreman purge runs`

Archive failed run records for tasks that are already closed or no longer exist. In default Elixir mode, the command writes `RunArchived` events by default; `--purge` writes `RunPurged` events that remove matching runs from the projection. Legacy cleanup remains available with `FOREMAN_BACKEND=node`.

```bash
foreman purge runs                                     # Elixir-backed stale run archive
foreman purge runs --dry-run                           # Elixir-backed stale run preview
foreman purge runs --purge                             # Elixir-backed stale run projection purge
foreman purge runs --dry-run --purge                   # Preview permanent purge candidates
FOREMAN_BACKEND=node foreman purge runs                # Legacy stale run cleanup
FOREMAN_BACKEND=node foreman purge runs --dry-run      # Preview legacy cleanup
```

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview without making changes |
| `--purge` | Remove matching run projections instead of archiving them |

> **Removed commands:** `foreman monitor` has been removed — use `foreman reset --detect-stuck` instead. `foreman mail send` has been removed — use `foreman inbox send`.
