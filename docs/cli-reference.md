# CLI Reference

Complete reference for all `foreman` commands, options, and usage examples.

Project-aware operator commands (`run`, `status`, `reset`, and `retry`) accept `--project <name-or-path>`. Registered names resolve through `~/.foreman/projects.json`; absolute paths are accepted directly for one-off targeting.

> **INCORRECT.** Of the four verbs named, only `run` is dispatched, and it takes
> `--project-id`, not `--project`. `status`, `reset` and `retry` are not
> top-level commands (see the block below). `--project` is real on `task`.


> ## Read this first: most of this file documents commands that do not exist
>
> The Go CLI dispatches exactly six top-level verbs (`packages/foreman_cli/cmd/foreman/main.go`); every other verb
> returns `foreman: unknown command`. The complete real surface, taken from the
> subcommand switches and flag sets in that package, is:
>
> foreman init              --force   # --force is REQUIRED
>
> foreman project create    --format --id --idempotency-key --path --task-provider --task-provider-database-path
> foreman project get       --format
> foreman project update    --format --idempotency-key --task-provider --task-provider-database-path
> foreman project delete    --force --idempotency-key
> foreman project list      --format --include-archived
>
> foreman task create       --description --id --project --status --task-type --title --trd-path --workflow-type
> foreman task approve      --approved-by --command-id --id
> foreman task retry        --id --reason
> foreman task get          (no flags)
> foreman task list        --project --status
> foreman task update      --description --id --priority --status --title
>
> foreman run list          --limit --project-id --status
> foreman run get           (no flags)
> foreman run cancel        --id --reason
> foreman run remove        --id
> foreman run reset         --id
> foreman run submit        --backend --base-branch --project-id --prompt --work-id --workflow
>
> foreman workflow install  --remote --retries --retry-delay-ms --source --target
> foreman workflow remove   --all
>
> Every verb except `init` REQUIRES a subcommand: bare `foreman run`,
> `foreman task`, `foreman project` or `foreman workflow` returns
> `missing subcommand`. Any section below showing flags directly on a bare verb
> (notably `foreman run --prompt …`) is not a real invocation.
>
> Twenty-six documented top-level verbs are not dispatched at all: `abandon`,
> `attach`, `board`, `clean-state`, `debug`, `doctor`, `import`, `inbox`,
> `issue`, `logs`, `merge`, `metrics`, `monitor`, `plan`, `pr`, `purge`,
> `recover`, `reset`, `retry`, `sentinel`, `server`, `sling`, `status`, `stop`,
> `watch`, `worktree`. Each section below that describes one now carries a
> **NOT IMPLEMENTED** note naming the nearest real command where one exists.
>
> The sections have been annotated rather than deleted: they read as a record of
> intended design, and deleting them would discard that. But they are not a
> reference, and this file is the one an operator or agent reaches for first —
> which is not hypothetical. REQ-007 of
> `docs/PRD/PRD-2026-d306444f-phase-commit-control.md` was specified against the
> `foreman inbox` surface documented below as though it worked, and had to be
> dropped once the aggregate behind it turned out to be unreachable. AGENTS.md's
> Documentation Discipline warns against trusting a stale build artifact over
> source; this is the same failure with the roles reversed, where the *document*
> is the stale artifact.
>
> Note also that this file is *incomplete* about what is real: it has no section
> for `foreman task approve`, `task get`, `task retry`, `run get`, `run cancel`,
> `run reset`, `workflow install` or `workflow remove`, all of which exist. The
> block above is authoritative; AGENTS.md's Operator Reference is accurate and
> was verified against the Go source.

## Global Usage

```bash
foreman [command] [options]
foreman --help              # Show all commands
foreman <command> --help    # Show command-specific help
```

### Local Development Services

> **INCORRECT.** Neither `devbox run dev:up` nor `devbox run db:up` exists.
> `devbox.json` defines 22 scripts; the stack is brought up with `devbox run up`
> (see AGENTS.md, Devbox). Database scripts are `db:migrate`, `db:reset`,
> `db:rollback`, `db:console`.

This repository's Devbox/direnv setup starts Docker Compose services before you run Foreman locally. `devbox run dev:up` starts shared Postgres plus Hindsight; `devbox run db:up` starts only the shared pgvector Postgres container. `.envrc` sources `.env`, and Foreman CLI/server commands use `DATABASE_URL` from `.env` or the process environment. If `DATABASE_URL` is unset, the compose-managed Foreman database is exposed on `127.0.0.1:55432` by default; Hindsight uses a separate `hindsight` database in the same container.

### Domain Groups and Deprecated Aliases

> **NOT IMPLEMENTED — this entire section.** `foreman --help` prints a flat
> command list (the `usage` const in `main.go`), not domain groups. There is no
> alias machinery at all: `main.go` contains no alias, deprecation or shorthand
> handling, and its `default:` branch returns `unknown command`, so every
> spelling in the table below — including the `Use instead` column — is
> unroutable. Of the 23 distinct verbs listed in the groups, three exist —
> `init`, `run`, `task`; `retry` and `reset` exist only as the subcommands
> `task retry` and `run reset`.
>
> `foreman server start` in the closing line does not exist either; use
> `mix phx.server`.

`foreman --help` groups commands by domain:

- Setup/health: `init`, `doctor`, `daemon`, `server`
- Planning: `plan`, `sling`
- Execution: `run`, `retry`, `reset`, `stop`, `recover`
- Tasks/views: `task`, `status`, `board`, `watch` (`monitor` alias), `logs`
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

> **PARTLY INCORRECT — including what the command does.** `foreman init` does
> not initialize a project: it POSTs an empty body to
> `/api/admin/workflows/install` and prints the response (`init.go:20-43`). It
> does not create `.foreman/`, install Pi skills, or register the project. It
> declares one flag, `--force`, which is **required** — bare `foreman init`
> returns `--force is required to refresh the installed runtime copy`
> (`init.go:27-32`). `-n`/`--name` and `--wizard` do not exist, and `init` takes
> no positional name.

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

**Subcommands:**
| Command | Description |
|---------|-------------|
| `create` | Register a new project |
| `get <id>` | Fetch a project projection |
| `update <id>` | Update a project's task provider |
| `delete <id>` | Soft-delete (archive) a project |
| `list` | List project projections |

### `foreman project create`

Register a new project. `--id`, `--path`, and `--task-provider` are required. `--task-provider=beads` also requires `--task-provider-database-path` with an absolute Beads database path.

```
foreman project create \
  --id project-123 \
  --path /srv/foreman/project-123 \
  --task-provider beads \
  --task-provider-database-path /srv/foreman/project-123/.beads
```

| Option | Description |
|--------|-------------|
| `--id <id>` | Project ID (required) |
| `--path <path>` | Project path (required) |
| `--task-provider <provider>` | Task provider (required) |
| `--task-provider-database-path <path>` | Absolute task-provider database path; required when `--task-provider=beads` |
| `--idempotency-key <key>` | Idempotency key |
| `--format json` | Print the raw command response as JSON |

### `foreman project get <id>`

Fetch a project projection.

```
foreman project get project-123
```

| Option | Description |
|--------|-------------|
| `--format json` | Print the raw projection as JSON |

### `foreman project update <id>`

Update a project's task provider. `--task-provider` is required. `--task-provider=beads` also requires `--task-provider-database-path` with an absolute Beads database path.

```
foreman project update --task-provider beads --task-provider-database-path /srv/foreman/project-123/.beads project-123
```

| Option | Description |
|--------|-------------|
| `--task-provider <provider>` | Task provider (required) |
| `--task-provider-database-path <path>` | Absolute task-provider database path; required when `--task-provider=beads` |
| `--idempotency-key <key>` | Idempotency key |
| `--format json` | Print the raw command response as JSON |

### `foreman project delete <id>`

Soft-delete (archive) a project. The server rejects the archive while active runs remain.

```
foreman project delete --force project-123
```

| Option | Description |
|--------|-------------|
| `--force` | Print active run ids if archive is blocked |
| `--idempotency-key <key>` | Idempotency key |

### `foreman project list`

List project projections. Default table columns: ID, PATH, ARCHIVED, REGISTERED, VERSION.

```
foreman project list --include-archived
```

| Option | Description |
|--------|-------------|
| `--include-archived` | Include archived projects |
| `--format json\|ndjson` | Output format |

---

## Agent Command Assets

### `foreman commands`

Generate, validate, or install agent command assets for Foreman operators. The generated assets are thin wrappers over real Go CLI commands: workflow-backed `foreman task create`, `foreman task list`, `foreman task update`, `foreman task get <task-id>`, ad-hoc `foreman run submit`, `foreman run list`, and `foreman run get <run-id>`. They inherit `FOREMAN_API_URL` and `FOREMAN_API_TOKEN`; generated files must not embed secret values.

**Subcommands:**
| Command | Description |
|---------|-------------|
| `inventory` | Print the canonical command inventory. |
| `generate` | Render copyable assets for one target agent or all agents. |
| `install` | Install verified native assets for one target agent. |
| `validate` | Render all targets and check CLI verbs/flags, unresolved placeholders, and unsupported-target reasons. |

### `foreman commands inventory`

Print generated command IDs, CLI mappings, and descriptions. Pass `--json` for the full structured inventory.

```bash
foreman commands inventory
foreman commands inventory --json
```

### `foreman commands generate --agent <agent>`

Render command assets for `claude`, `pi`, `omp`, `codex`, `opencode`, or `all`. Without `--output`, the command prints JSON containing each rendered file. With `--output`, it writes generated files below `<output>/<agent>/`.

```bash
foreman commands generate --agent all --output ./foreman-agent-commands
```

### `foreman commands install --agent <agent>`

Install native command files only when Foreman has a verified native path/format. Claude Code project-local Markdown slash commands are verified and install to `.claude/commands/foreman` by default. Existing files are refused unless `--force` is supplied. For Pi and OMP agents, `--scope global` uses the recommended global skill directory when no `--target` is specified. For other agents (Codex, OpenCode), `--scope global` requires an explicit `--target` directory that the operator has verified.

```bash
foreman commands install --agent claude --scope project
foreman commands install --agent claude --target .claude/commands/foreman --force
```

Pi/OMP install to ~/.pi/agent/skills/<id>/SKILL.md. Codex and OpenCode remain generate-only.

### `foreman commands validate`

Validate the generated inventory and rendered assets against the Go CLI contract.

```bash
foreman commands validate
```

The workflow task shortcuts create tasks that require later approval. The `foreman-run-submit` asset is the one-step ad-hoc execution path and documents that `--backend codex|opencode` being accepted by the CLI does not prove runtime provider readiness.

---

## Dispatching Work

### `foreman run`

> **NOT IMPLEMENTED as described.** `foreman run` is not a dispatch verb; it
> requires one of `list`, `get`, `cancel`, `remove`, `reset`, `submit`, and a
> bare `foreman run` returns `missing subcommand`. None of the twenty flags this
> section documents exist anywhere in `run.go` — `--model`, `--watch`,
> `--no-watch`, `--yes`, `--dry-run`, `--resume`, `--resume-failed`,
> `--max-agents`, `--stagger`, `--skip-explore`, `--skip-review`, `--no-pipeline`,
> `--no-auto-dispatch`, `--runtime-mode`, `--telemetry`, `--project`,
> `--project-path`, `--default-branch`, `--task`, `--foreman`. To start work, use
> `foreman task create` + `foreman task approve`, or `foreman run submit`.

Dispatch ready tasks to AI agents by sending a scheduler tick to the Elixir orchestration server, which owns ready-task claiming, capacity, and worker launches.

Default workflows include a `documentation` phase before finalization. The bundled bug workflow starts with a lightweight Explorer phase that uses `Grep`, `Glob`, and targeted `Read` discovery before implementation; Elixir Overwatch rejects Graphify tools so worker discovery does not create slow generated worktree artifacts. The documentation phase updates required operator/developer docs (`CLAUDE.md`, `AGENTS.md`, `README.md`, and this User Guide) when task behavior changes, or writes `DOCUMENTATION_REPORT.md` explaining why no doc update was needed.

Workflow PR/merge behavior is not driven by `create-pr`, `pr-wait`, or `merge` phases — no such phase is implemented or dispatched, and a phase declaring none of `command`/`prompt`/`bash` fails to load with `{:missing_phase_action, index}`. A run still has one Foreman branch, defaulting to `foreman/<task-id>/<run-id>` for unique branches per retry, but a phase can now declare `stack_pr: true` to create or reuse a phase PR from that run branch to the recorded run base branch after that phase's commit decision. Top-level `merge:` and `pr:` YAML tags remain invalid, and there is no `stacked:` or `checkpointPr` setting. A phase-level `commit:` boolean controls only whether that phase commits its work; `stack_pr:` does not force a commit. A phase may also declare `timeout_minutes: <positive integer>` to set its execution timeout in minutes; omitting it preserves app-config `failure_policies` / `default_timeout_ms` behavior. Created/reused phase PR records suppress final AutoPR; no-op phase PR records do not. `foreman run get <id>` JSON includes `run.phase_prs` when phase records exist. See "PR creation and merge reconciliation" in the User Guide.

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

### `foreman run list [--status <status>] [--project-id <id>] [--limit <n>]`

List run projections as JSON. Issues `GET /api/runs` with optional query filters forwarded to the server-side projection store. Use it before run maintenance to find failed or stuck runs.

```bash
foreman run list                                # all runs, no filter
foreman run list --limit 20                     # cap result count
foreman run list --status failed --limit 10     # filter by status
foreman run list --project-id foreman           # filter by project
```

| Option | Description |
|--------|-------------|
| `--status <status>` | Filter by run status (`in_progress`, `completed`, `failed`, `cancelled`, etc.). |
| `--project-id <id>` | Filter by registered project id. |
| `--limit <n>` | Maximum number of runs to return. Must be non-negative. |

### `foreman run remove --id <run-id>`

Remove a run and clean up its worktree/branch. Issues `POST /api/commands` with a `run.remove` envelope. The server terminates the run, releases its run slot and per-DB Beads lease, and best-effort cleans the projected worktree plus the local branch.

```bash
foreman run remove --id run-f971378012da4da2fec3ec74dbac325d
```

| Option | Description |
|--------|-------------|
| `--id <run-id>` | Run ID (required). |

### `foreman run submit --workflow <name> --prompt <text> --project-id <id> [--work-id <id>] [--backend <backend>] [--base-branch <branch>]`

> **PARTLY INCORRECT.** The flag is `--base-branch`, not `--base`, and there is
> no `--short`. Real set: `--workflow --prompt --project-id --work-id --backend
> --base-branch`. Note that `--base-branch` is accepted by the CLI but, per
> AGENTS.md, is still not consumed server-side — the PR base is the branch the
> run's work was cut from.

Posts a `task.create` envelope (`provider_tracked: false`, `auto_approve:
true`) rather than a separate `work.submit` ingress — the `work.*` command
types have been retired; ad-hoc dispatch is unified onto the task path.

- `--workflow` (required) — the workflow name to execute. Validated
  server-side by `Catalog.load/1`; there is no client-side allowlist.
- `--prompt` (required) — the input prompt/text for the workflow.
- `--project-id` (required) — the project ID.
- `--work-id` (optional) — alias for the task ID. Minted client-side as
  `adhoc-<hex>` when omitted, so the server's no-id `task.create` flow
  (which resolves the ID through the task provider) is never triggered for
  an untracked task.
- `--backend` (optional) — backend to use. Valid atoms are
  `:jido_harness` (the production default, dispatched via the
  `JidoHarnessAdapter` to whichever `:jido_harness, :providers`
  entry is currently ready), or the registered `name/0` of any
  adapter module registered with the catalog (for example `:pi` for
  the legacy `PiAdapter`). The only Jido.Harness providers the
  runtime currently supports are `:pi`, `:claude`, and `:litellm` — `:codex`,
  `:opencode`, and other unlisted atoms return
  `{:error, :backend_not_found}`. Defaults to `:jido_harness` when
  the JidoHarnessAdapter is in the runtime's adapter list; falls back
  to the first available adapter in the list otherwise.
- `--base-branch <branch>` (optional, half-consumed per
  [TRD-2026-80ba0665](TRD/TRD-2026-80ba0665-branch-parent-resolution.md))
  — parent branch for the new task's worktree and PR. **The default now
  resolves server-side from the operator's checkout**: `RunExecutor` records
  `git symbolic-ref --short HEAD` of the project checkout when the run's first
  phase starts, and `AutoPR` opens the PR against that branch, replacing the
  historical `"main"` fallback. A detached checkout resolves to no branch,
  which is `{:auto_pr_base_branch_unresolved, reason}` at `error` and no PR.
  **The flag itself remains protocol-level capture only**: the CLI accepts and
  forwards it inside the `task.create` envelope, but nothing server-side
  reads it, so an explicit value cannot yet override the checkout. Use
  `gh pr edit <n> --base <branch>` to retarget a PR onto a different base.

Example:

```text
foreman run submit --workflow implement-trd --prompt "Fix the CLI submit bug" --project-id foreman
```

```bash
foreman run reset --id run-f971378012da4da2fec3ec74dbac325d
```

| Option | Description |
|--------|-------------|
| `--id <run-id>` | Run ID (required). |


---

## Monitoring

### `foreman status`

> **NOT IMPLEMENTED.** `foreman status` is not dispatched. Nearest real: `foreman run list [--status <s>] [--project-id <id>] [--limit <n>]` and `foreman run get <id>`.

Show project status: task counts, active agents, costs (total and per-turn), tokens, elapsed time (total and per-turn), and tool usage. `--live` opens the unified cockpit directly to the status/workflow view; `--watch` remains the compact refreshing status output; `--json` remains machine-readable.

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

> **NOT IMPLEMENTED.** `foreman logs` is not dispatched. Run logs are readable through the MCP tool `foreman_run_get_logs` (see MCP Server below), which is backed by the durable worker-event log described in AGENTS.md.

Show run logs with structured rendering. When the Elixir backend is available, worker stdout/stderr is read from durable `WorkerStdout` / `WorkerStderr` event projections and rendered as timestamped, color-coded lines with stream, type, and phase labels. Known runs with no captured output render as empty; unknown runs report not found. Falls back to raw log file parsing when the backend is unavailable.

```bash
foreman logs bd-abc1              # Show structured log entries
foreman logs bd-abc1 --tail 200    # Show more log lines
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

### `foreman metrics`

> **NOT IMPLEMENTED.** `foreman metrics` is not dispatched, and no CLI surface replaces it.

Show detailed task metrics including cost and time statistics. This provides a focused view of accumulated metrics separate from the full status dashboard.

```bash
foreman metrics                  # Show all metrics
```

**Displayed metrics:**
- **Total Cost** — Cumulative cost in USD across all turns
- **Total Turns** — Total number of turns executed (denominator for per-turn metrics)
- **Cost per Turn** — Average cost per turn in USD
- **Total Time** — Cumulative elapsed time (formatted as hours/minutes/seconds)
- **Time per Turn** — Average time per turn

Per-turn metrics show `—` when total turns is zero.

### `foreman watch`

> **NOT IMPLEMENTED.** `foreman watch` is not dispatched. Poll `foreman run get <id>` instead.

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

Cockpit keys: `j/k` select, `i` inbox, `s` status/workflow, `b` board, `n` create task (TTY form with type/priority dropdowns), `m/e/l/r/f` detail tabs, `/` search, `1/2/3` active/attention/all scopes, `!` failed, `p` has PR, `d` dirty worktree, `a`/`:` action palette, `q`/`Esc` quit. Palette reset asks for `y` confirmation and executes `foreman reset` for the selected task; the Go cockpit `R` key resets the selected run or a selected task card's latest known run. All other entries print copy/manual command text only.

### `foreman monitor`

> **NOT IMPLEMENTED.** `foreman monitor` is not dispatched. Poll `foreman run get <id>` instead.

Alias for the canonical `foreman watch` command, with the same options and behavior.

```bash
foreman monitor                     # Unified live cockpit (same as foreman watch)
foreman monitor --no-watch          # One-shot snapshot, no polling
foreman monitor --refresh 5000      # Refresh every 5 seconds
```

### `foreman sentinel`

> **NOT IMPLEMENTED.** `foreman sentinel` is not dispatched, and no CLI surface replaces it.

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

> **NOT IMPLEMENTED.** `foreman board` is not dispatched. `foreman run list` is the only run overview.

On a TTY, open the unified cockpit in board view. The board pane groups rows by task-status lifecycle columns, keeps workflow phase and run/PR state as separate card metadata, and lets operators jump to inbox/status details without starting a second terminal loop. Terminal events update task status first, so a merged PR appears in `done` because the task is marked `merged`. Non-TTY output, `--all`, and `--filter` keep the legacy/scriptable board path.

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

> **NOT IMPLEMENTED.** `foreman debug` is not dispatched, and no CLI surface replaces it.

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
- Pipeline reports (EXPLORER_REPORT.md, QA_REPORT.md, REVIEW.md, PR_WAIT_REPORT.md with CodeRabbit finding details, etc.)
- Agent worker logs (`~/.foreman/logs/<runId>.log`)
- Task info from `native task store show`

### `foreman recover`

> **NOT IMPLEMENTED.** `foreman recover` is not dispatched, and no CLI surface replaces it.

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

> **NOT IMPLEMENTED.** `foreman doctor` is not dispatched. A `foreman_doctor` MCP tool does exist and reports jido_harness provider readiness — a much narrower check than this section describes.

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

> **NOT IMPLEMENTED.** `foreman server` is not dispatched. The Phoenix server is started with `mix phx.server` from `packages/foreman_server/` (AGENTS.md, Operator Reference). See also the projection-table correction above.

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

> **Correction.** No `*_projections` tables exist. The repository has exactly two
> migrations — `create_jido_storage_tables` and `create_idempotency_keys_table`
> — and none of `foreman_project_projections`, `foreman_task_projections`,
> `foreman_run_projections` or `foreman_inbox_message_projections` appears in any
> source file. `foreman server` is not a command either (see the note under
> Agent Mail and `foreman-x4ca`). Left in place as intended design; the
> `foreman_inbox_message_projections` name in particular is the read side of the
> deleted `InboxThread` aggregate and was never built.

Elixir backend roles: the **Node CLI** parses commands/renders projections, the **Elixir server** owns aggregate-validated commands/events/projections/recovery/security/overwatch and all database access, automatically ticks the scheduler every 5 seconds to claim `ready` tasks within capacity and launch the Node/Pi worker bridge, and **Node/Pi workers** execute Pi SDK phases, stream worker events, emit authoritative terminal run/task events, stream Pi SDK tool calls/assistant messages as ordered worker events, expose typed Foreman tools (`mail_send`, `mail_read`, `phase_handoff`, `artifact_write`, `validation_result`, `task_block`, `progress_update`, `ask_operator`, `abort_phase`, `needs_retry`, `safe_command_run`), and ask Elixir overwatch to approve/deny tool calls before execution. Node workers and CLI clients do not connect directly to the database; they use Elixir HTTP commands/projections and do not drain DB-backed merge queues from inside the worker. Raw log files are compatibility/debug projections of the worker event stream. The launcher records process-exit facts and emits a diagnostic fallback failure only when a worker exits without an authoritative terminal event; that fallback may parse the final worker output to avoid stale phase attribution, but authoritative worker terminal events remain preferred. If an Elixir-backed view is wrong, inspect the event timeline first, then projection lag/rebuild state, then recovery events (`ExternalWorkerObserved` before `WorkerReattached`, `WorkerRestarted`, or `NeedsOperator`). After cutover, Elixir is the backend; `foreman daemon start|restart` fails fast and directs operators to `foreman server start`. See [Elixir Backend Architecture](./guides/elixir-backend-architecture.md).

The Elixir server also includes a PR monitor. For runs with recorded GitHub PR URLs, it periodically runs GitHub PR inspection from the registered project path, records merged PR metadata on the run, and updates the associated task to `merged` when GitHub reports `MERGED`. A GitHub closed-but-unmerged PR records the run PR state as closed and closes the associated task. As a real-time optimization, the server exposes `POST /webhooks/github` for GitHub `pull_request` webhook events (HMAC-SHA256 verified via `FOREMAN_GITHUB_WEBHOOK_SECRET`); polling remains as fallback. `foreman server doctor` reports whether the webhook secret is configured.


### `foreman reset`

> **NOT IMPLEMENTED.** `foreman reset` is not dispatched. The real command is `foreman run reset --id <run-id>`, which clears a failed or stuck run projection — it does not stop workers, close PRs, or delete branches as described here.

Reset Elixir-backed task work. The command stops active worker processes when present, removes stale task worktrees unless `--keep-worktree` is set, closes any open/draft PR recorded for the task before deleting its remote branch, deletes local/origin `foreman/<task>` branches, removes prior run logs/reports, clears run linkage and failure fields, sets the task back to `ready`, and requests scheduler dispatch. If GitHub reports the recorded PR was already merged, reset leaves that PR unchanged, preserves prior run artifacts for auditability, continues branch/worktree cleanup, marks any still-active run completed, marks the task closed, and skips scheduler dispatch to avoid redundant reruns. Closed/completed tasks can be reopened this way; merged tasks remain terminal.

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

> **NOT IMPLEMENTED.** `foreman retry` is not dispatched. The real command is `foreman task retry --id <task-id> [--reason <text>]`; there is no `--dispatch`, `--model`, or positional-id form.

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

> **NOT IMPLEMENTED.** `foreman abandon` is not dispatched. Nearest real: `foreman run remove --id <run-id>`, which removes a run and cleans its worktree/branch.

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

> **NOT IMPLEMENTED.** `foreman clean-state` is not dispatched. This stub is also duplicated below at the fuller section of the same name.

Reset Foreman to a clean operator state by intentionally dropping stale/obsolete Foreman work.

### `foreman run kill-switch`

> **NOT IMPLEMENTED.** `foreman run kill-switch` is not a `run` subcommand. `runRun` dispatches exactly `list`, `get`, `cancel`, `remove`, `reset`, `submit`. Nearest real: `foreman run cancel --id <run-id> --reason <text>`.

Kill a stuck active run and route to a recovery phase without losing artifacts. This is the first-class operator kill-switch for stuck phases — it stops the active worker, marks the current phase as failed with `retryWith` routing, and preserves the worktree, PR, and reports by default.

```bash
foreman run kill-switch <run-id>                              # safe-by-default: preserve worktree, PR, reports
foreman run kill-switch <run-id> --route-to qa                # route to qa instead of developer
foreman run kill-switch <run-id> --reason "blocking CodeRabbit review"
foreman run kill-switch <run-id> --dry-run
foreman run kill-switch <run-id> --reset                       # also reset task to backlog
foreman run kill-switch <run-id> --force                       # confirm worktree deletion
foreman run kill-switch <run-id> --close-pr                    # close the GitHub PR
foreman run kill-switch <run-id> --discard-reports             # delete ~/.foreman/reports/<run-id>/
```

**Typical workflow (pr-wait blocking review):**

1. Observe a run stuck in `pr-wait` with a terminal-negative CodeRabbit review.
2. Kill the stuck phase: `foreman run kill-switch <run-id> --route-to cr-developer --reason "terminal CodeRabbit CHANGES_REQUESTED"`.
3. The run is marked failed with `retryWith → cr-developer`; worktree and PR are preserved.

**Safe-by-default behavior (no destructive flags needed):**

| Action | Default | Flag to change |
|--------|---------|---------------|
| Mark phase failed with `retryWith` → target | **ON** | `--route-to <phase>` |
| Stop the worker process | **ON** | — |
| Preserve worktree (`~/.foreman/worktrees/...`) | **ON** | `--force` to delete |
| Preserve PR (no close, no comment) | **ON** | `--close-pr` to close |
| Preserve reports (`~/.foreman/reports/<run-id>/`) | **ON** | `--discard-reports` to delete |
| Reset task to backlog | OFF | `--reset` |
| Delete worktree | OFF | `--force` + confirmation |
| Close the PR | OFF | `--close-pr` |
| Discard reports | OFF | `--discard-reports` |

| Option | Description |
|--------|-------------|
| `<run-id>` | Run ID to kill |
| `--route-to <phase>` | Target workflow phase for `retryWith` routing (default: `developer`); unknown phases are rejected and `retryOnly` targets are activated explicitly |
| `--reason <text>` | Reason recorded in kill-switch event and run history |
| `--reset` | Also reset the task to backlog (opt-in; default preserves task status) |
| `--force` | Confirm worktree deletion intent |
| `--close-pr` | Close the GitHub PR (handled by Elixir backend) |
| `--discard-reports` | Delete the reports directory for this run |
| `--dry-run` | Preview what would happen without making changes |
| `--project <name>` | Registered project name (default: current directory) |
| `--project-path <absolute-path>` | Absolute project path (advanced/script usage) |

### `foreman clean-state`

> **NOT IMPLEMENTED.** `foreman clean-state` is not dispatched, and no CLI surface replaces it. Duplicate of the stub above.

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

> **NOT IMPLEMENTED.** `foreman merge` is not dispatched. PR creation is automatic and server-side (`Workflow.AutoPR.maybe_create_pr/1`, called from `RunExecutor.finalize_run/1`); there is no operator merge verb.

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

> **NOT IMPLEMENTED.** `foreman pr` is not dispatched. See the AutoPR note under `foreman merge`.

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

> **NOT IMPLEMENTED.** `foreman issue` is not dispatched, and no CLI surface replaces it.

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

There is **no `foreman mcp` subcommand**. The Go CLI does not implement one.
The MCP server is part of the Elixir application and is reached one of two
ways.

### HTTP transport (recommended)

The MCP server runs as a supervised child of `ForemanServer.Application`
(`ForemanServer.MCP`) and is mounted by `ForemanServerWeb.MCPRouter` on the
existing Phoenix endpoint. When the server is running, MCP is already
available — nothing extra to start:

```
http://127.0.0.1:4766/mcp
```

It is gated on config, enabled by default in `dev`:

```elixir
config :foreman_server, :mcp,
  enabled: true,
  mount: "/mcp",
  allow_workflow_writes: false,
  allow_insecure_local: true
```

| Key | Default (dev) | Description |
|--------|--------|-------------|
| `enabled` | `true` | Start the MCP server child |
| `mount` | `/mcp` | Path on the Phoenix endpoint |
| `allow_workflow_writes` | `false` | Advertise and permit write tools |
| `allow_insecure_local` | `true` | Accept requests with no bearer token |

With `allow_insecure_local: false`, requests must send
`Authorization: Bearer <token>` matching `:foreman_server, :api_bearer_token`.

Client config for a Streamable HTTP MCP client (Oh My Pi shown; see
`docs/mcp-config.md` upstream for the schema):

```json
{
  "mcpServers": {
    "foreman": { "type": "http", "url": "http://127.0.0.1:4766/mcp" }
  }
}
```

### stdio transport

For MCP clients that spawn the server as a child process:

```bash
cd packages/foreman_server && mix foreman.mcp.stdio
```

stdout carries JSON-RPC frames only; diagnostics go to stderr. The token is
read from the `initialize` request's `_meta.authorization` field
(`"Bearer <token>"`).

This starts a second copy of the application, so prefer the HTTP transport
when a Foreman server is already running.

### Tools

Read tools are always advertised: `foreman_doctor`, `foreman_queue_status`,
`foreman_project_list`, `foreman_project_get`, `foreman_workflow_list`,
`foreman_workflow_get`, `foreman_workflow_validate`, `foreman_prompt_get`,
`foreman_work_get`, `foreman_run_get`, `foreman_run_status`,
`foreman_run_get_logs`, `foreman_run_get_events`, `foreman_run_get_activity`,
`foreman_task_list`, `foreman_task_get`.

`foreman_run_get_events` reads the `run:<run_id>` stream only. Worker liveness
and stdout/stderr events are appended to `worker:<run_id>:<worker_id>` streams
instead, so use `foreman_run_get_activity` for per-worker heartbeat counts,
last sequence, and last-heartbeat timestamps. `foreman_run_get_logs` reads the
bounded worker log projection: known runs with no captured output return an
empty success and unknown runs return `NOT_FOUND`, so "this run wrote nothing"
is never confused with "no such run". The default response is the latest 500
entries; the in-memory projection retains up to 5,000 entries or 1 MiB per run,
whichever binds first, and reports any eviction as `truncated: true` with
non-zero `omitted_entries` / `omitted_bytes` — a truncated read can never look
complete. There is no store-unavailable error: the projection is server state,
so for a known run the read always succeeds.

`foreman_run_status` returns a bounded projection DTO with `run_id`, `status`,
`terminal`, `project_id`, `task_id`, `workflow_name`, `current_phase`,
`started_at_ms`, `last_event_at_ms`, and `failure_reason`; it does not scrape
logs or raw events.

`foreman_task_list` accepts optional `project_id`, canonical `status` (`open`,
`ready`, `in_progress`, `blocked`, `closed`, `failed`), `limit` (default 100,
max 500), and `offset` (default 0), and returns `{tasks, total, limit, offset,
next_offset}` in task-id ascending order. `foreman_task_get` returns one full task
projection or `NOT_FOUND`.

Write tools (`foreman_task_create`, `foreman_task_update`, `foreman_run_cancel`,
`foreman_workflow_put`, `foreman_workflow_delete`, `foreman_prompt_put`) are
unadvertised and refused unless `allow_workflow_writes: true`.
`foreman_task_create` requires `description` for `FOREMAN_TASK_DESCRIPTION`, passes
`prompt` separately for `:prompt`-action phases, and defaults `auto_approve: true`.
`foreman_task_update` requires `task_id` and at least one of `title`,
`description`, `priority`, or `status`; unsupported fields are dropped at the
handler boundary and no-op updates return `INVALID_PARAMS` before dispatch.

Both transports share `ForemanServer.MCP.Dispatch`, so their tool sets and
behavior cannot diverge.

---

## Agent Mail

> **NOT IMPLEMENTED.** Neither `foreman inbox` nor `foreman inbox send` exists.
> The **Go CLI**'s command switch
> (`packages/foreman_cli/cmd/foreman/main.go:85-98`) dispatches exactly
> `project`, `task`, `run`, `workflow` and `init`; anything else returns
> `foreman: unknown command`. That is the only `foreman` entry point in the
> repository — `packages/` holds `foreman_cli`, `foreman_server` and
> `jido_harness`, and the string `inbox` appears in no Go, TypeScript or
> JavaScript source in any of them. Passages elsewhere in this file describing a
> Node CLI or `foreman daemon` refer to a retired architecture.
>
> The Elixir side this section describes is gone too. It named an "event-backed
> inbox projection (`InboxMessageAppended` / `InboxDeliveryUpdated`)", but the
> only code that ever produced those events was
> `ForemanServer.Aggregates.InboxThread`, which was unreachable from every
> direction at once — `inbox.send` absent from the command allowlist, no
> `"inbox:"` clause in `CommandRouter.aggregate_module_for/1`, no event structs,
> no `ProjectionStore` handler, no HTTP route, no MCP tool, and no caller. It has
> been deleted (see AGENTS.md §5.3). There is no
> `foreman_inbox_message_projections` table in the codebase either, despite the
> mention under `server status`.
>
> Retained as a record of the intended design, not as a description of behavior.
> Do not implement against it without re-deriving the design: an entire
> requirement (REQ-007 of `PRD-2026-d306444f-phase-commit-control.md`) was
> specified against this inbox as though it worked, and had to be dropped.

### `foreman inbox`

View the Agent Mail inbox — messages sent between agents and the foreman orchestrator. In Elixir/default backend mode, inbox reads the Elixir event-backed inbox projection (`InboxMessageAppended` / `InboxDeliveryUpdated`) and does not require the Node daemon socket. When run on a TTY with no explicit selector, `foreman inbox` opens the unified cockpit focused on the inbox view: task list, selected-run timeline, status/board jump keys, details, and `m/e/l/r/f` tabs for messages, events, logs, reports, and files. The cockpit phase rail follows the selected run's workflow phase order and shows per-phase retry counts. Message rows render oldest-first (chronological) with local `mm/dd hh:mm`, sender, receiver, and message columns. The cockpit refreshes live while keeping the selected run pinned; `/`, `1/2/3`, `!`, `p`, and `d` search/filter rows; `a` or `:` opens the action palette. Palette reset requires explicit `y` confirmation and then runs `foreman reset` for the selected task; non-reset actions still print copy/manual command text. Use `--non-interactive` for scriptable output. Task/run drilldowns stay scriptable by default and enter the cockpit only with `--interactive`.

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
foreman inbox task bd-abc1 --select-report   # Interactive report file picker → opens in $EDITOR
foreman inbox run <run-id> --select-report      # Interactive run report file picker → opens in $EDITOR
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
| `--logs` | — | Task/run subcommand: show last 24 structured log entries (timestamp, stream, type, phase, message) with color coding; falls back to raw log files if Elixir backend unavailable |
| `--reports` | — | Task/run subcommand: show phase report files |
| `--files` | — | Task/run subcommand: show file changes |
| `--select-report` | — | Task/run subcommands only: interactively select a report file to open in `$EDITOR` |

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

Use `agent-error` only for unrecoverable infrastructure/runtime failures. QA/product failures should write a FAIL report so workflow retry routing can send feedback to the configured remediation phase.

---

## Task Planning

### `foreman plan`

> **NOT IMPLEMENTED.** `foreman plan` is not dispatched. Planning runs are started as ordinary tasks: `foreman task create --workflow-type plan …`.

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

> **NOT IMPLEMENTED.** `foreman sling trd` is not dispatched. Use `foreman task create --workflow-type implement-trd --trd-path <path>`.

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

> **PARTLY INCORRECT.** `foreman task create` is real, but eight flags shown
> below do not exist: `--type` (the real flag is `--task-type`), `--priority`
> (set it via a raw `task.create` envelope; see AGENTS.md), `--parent`,
> `--model`, `--dry-run`, `--from-text`, `--no-llm`, `--project-path`. Passing
> any of them is a flag parse error.
>
> The real set is `--id --project --title --description --task-type
> --workflow-type --trd-path --status`. Two corrections to note: `--command-id`
> is a `task approve` flag, not a `task create` one, and `--status` — which the
> options table below omits entirely — is real and defaults to **`open`**, not
> the `backlog` status the sentence below claims.

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
| `--trd-path <path>` | — | Project-relative TRD path; required for `--workflow-type implement-trd*` |
| `--workflow-type <name>` | — | Workflow manifest name (e.g. `fix`, `implement-trd`) |

### `foreman task list`

List tasks, optionally filtered by project and status.

```bash
foreman task list --project foreman --status open
```

| Option | Description |
|--------|-------------|
| `--project <id>` | Filter by project ID |
| `--status <status>` | Filter by status: `open`, `ready`, `in_progress`, `blocked`, `closed`, `failed` |

### `foreman task update`

Update task fields (title, description, priority, status). At least one field must be provided.

```bash
foreman task update --id foreman-iv00 --priority 1 --status closed
```

| Option | Description |
|--------|-------------|
| `--id <id>` | Task ID (required) |
| `--title <text>` | New task title |
| `--description <text>` | New task description |
| `--priority <0-4>` | Priority: `0`=critical, `1`=high, `2`=medium, `3`=low, `4`=backlog |
| `--status <status>` | New status: `open`, `ready`, `in_progress`, `closed`, `failed` |


## Migration and Coexistence

### `foreman import --to-elixir`

> **NOT IMPLEMENTED.** `foreman import` is not dispatched, and no CLI surface replaces it.

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

> **NOT IMPLEMENTED.** `foreman attach` is not dispatched, and no CLI surface replaces it.

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

> **NOT IMPLEMENTED.** `foreman worktree` is not dispatched. Worktrees are provisioned and reclaimed server-side, one per run (see AGENTS.md); there is no operator worktree verb.

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

> **NOT IMPLEMENTED.** `foreman purge` is not dispatched. Nearest real: `foreman run remove --id <run-id>`.

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

> **NOT IMPLEMENTED.** `foreman issue` is not dispatched. Near-duplicate of the section above, which this one predates or follows — it is not a strict copy: only this copy mentions `foreman issue webhook`.

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

> **Removed commands:** `foreman mail send` has been removed — use `foreman inbox send`.









