# CLI Reference

Complete reference for all `foreman` commands, options, and usage examples.

Project-aware operator commands (`run`, `status`, `reset`, and `retry`) accept `--project <name-or-path>`. Registered names resolve through `~/.foreman/projects.json`; absolute paths are accepted directly for one-off targeting.

## Global Usage

```bash
foreman [command] [options]
foreman --help              # Show all commands
foreman <command> --help    # Show command-specific help
```

---

## Project Setup

### `foreman init`

Initialize Foreman in a project. Creates `.foreman/` directory, installs default workflow configs, prompts, and registers the project in the SQLite store.

```bash
foreman init                      # Initialize with auto-detected name
foreman init -n my-project        # Initialize with explicit name
foreman init --force              # Overwrite existing prompt files
```

| Option | Description |
|--------|-------------|
| `-n, --name <name>` | Project name (default: directory name) |
| `--force` | Overwrite existing prompt and workflow files |

---

## Dispatching Work

### `foreman run`

Dispatch ready beads to AI agents. Runs in a continuous loop by default — dispatches beads, monitors agents, and auto-merges completed work.

```bash
foreman run                       # Dispatch all ready beads (up to max-agents)
foreman run --project my-project   # Dispatch against a registered project without cd
foreman run --bead bd-abc1        # Dispatch a specific bead
foreman run --dry-run             # Preview what would be dispatched
foreman run --max-agents 3        # Limit concurrent agents to 3
foreman run --resume              # Resume stuck/rate-limited runs
foreman run --resume-failed       # Also resume permanently failed runs
foreman run --no-watch            # Dispatch once and exit (don't monitor)
foreman run --no-pipeline         # Single agent mode (no explorer/qa/reviewer)
foreman run --skip-explore        # Skip the explorer phase
foreman run --skip-review         # Skip the reviewer phase
foreman run --model anthropic/claude-opus-4-6  # Force a specific model
```

| Option | Default | Description |
|--------|---------|-------------|
| `--bead <id>` | — | Dispatch only this specific bead (must be approved and ready) |
| `--max-agents <n>` | `5` | Maximum concurrent agents |
| `--model <model>` | — | Force a specific model for all phases |
| `--dry-run` | — | Show what would be dispatched without doing it |
| `--no-watch` | — | Exit immediately after dispatching |
| `--resume` | — | Resume stuck/rate-limited runs from previous dispatch |
| `--resume-failed` | — | Also resume failed runs (not just stuck) |
| `--no-pipeline` | — | Skip the pipeline — run as single worker agent |
| `--skip-explore` | — | Skip the explorer phase |
| `--skip-review` | — | Skip the reviewer phase |
| `--no-auto-dispatch` | — | Disable auto-dispatch when capacity is available |
| `--telemetry` | — | Enable OpenTelemetry tracing (requires OTEL_* env vars) |
| `--project <name-or-path>` | — | Target a registered project name or absolute project path |

> **Approval gate:** Beads with the `foreman:backlog` label are skipped by the dispatcher. Use `foreman task approve <bead-id>` before dispatching.

---

## Monitoring

### `foreman status`

Show project status: beads-first queue counts, active agents, cost breakdown, and machine-readable queue state.

```bash
foreman status                       # Snapshot of current project state
foreman status --project my-project  # Status for a registered project without cd
foreman status -w                    # Live refresh every 10 seconds
foreman status -w 5                  # Live refresh every 5 seconds
foreman status --live                # Full dashboard TUI
foreman status --json                # Single-project machine-readable output
foreman status --all                 # Aggregate human-readable status across projects
foreman status --all --json          # Aggregate machine-readable status across projects
```

| Option | Default | Description |
|--------|---------|-------------|
| `-w, --watch [seconds]` | `10` | Auto-refresh interval |
| `--live` | — | Enable full dashboard TUI (Ink-based) |
| `--json` | — | Output as JSON; single-project output includes `tasks.queue`, aggregated output includes `projects[]`, `skippedProjects`, `queueWarnings`, and `summary` |
| `--project <name-or-path>` | — | Show status for a registered project name or absolute project path |
| `--all` | — | Aggregate status across all registered projects |

**JSON highlights:**

- `foreman status --json` returns scalar task counts plus `tasks.queue.backlog`, `tasks.queue.blocked`, and `tasks.queue.warnings`.
- `foreman status --all --json` returns one entry per successfully reported registered project under `projects[]`, each with the same beads-first queue detail.
- Aggregated JSON also includes `skippedProjects` for registered projects that could not be reported and `queueWarnings` for warning-bearing reported projects, both with project attribution.
- `summary.projects` reports `{ totalRegistered, reported, skipped }` so automation can detect partial visibility without diffing arrays.
- When `--json` is combined with human-only refresh flags such as `--watch` or `--live`, status returns a single JSON snapshot and includes a top-level `warnings` array describing the ignored flags.

**Human-readable aggregated status:**

- `foreman status --all` prints the same aggregate counts plus concise `Skipped Projects:` and `Queue Warnings:` sections when those conditions exist.

**Example output:**

```
Project Status

Tasks
  Total:       65
  Ready:       3
  Backlog:     2
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

### `foreman dashboard`

Live observability dashboard with real-time TUI. Shows all projects, agents, recent events, per-project task queues, and the approval backlog panel.

```bash
foreman dashboard                 # Full dashboard
foreman dashboard --simple        # Compact single-project view
foreman dashboard --no-watch      # Single snapshot
foreman dashboard --interval 5000 # Poll every 5 seconds
```

| Option | Default | Description |
|--------|---------|-------------|
| `--interval <ms>` | `3000` | Polling interval in milliseconds |
| `--project <id>` | — | Filter to a specific registered project in the dashboard view |
| `--no-watch` | — | Single snapshot, then exit |
| `--events <n>` | `8` | Recent events to show per project |
| `--simple` | — | Compact single-project view |

### `foreman sentinel`

Continuous QA testing agent that monitors a branch for test failures and auto-creates beads to fix them.

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
| `--failure-threshold <n>` | `2` | Consecutive failures before filing a bug bead |
| `--dry-run` | — | Simulate without running tests or creating beads |

**`sentinel start` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--branch <branch>` | `main` | Branch to monitor |
| `--interval <minutes>` | `30` | Check interval |
| `--test-command <cmd>` | `npm test` | Test command |
| `--failure-threshold <n>` | `2` | Consecutive failures before bug |
| `--dry-run` | — | Simulate |

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

## Debugging & Recovery

### `foreman debug`

AI-powered execution analysis. Gathers all artifacts (logs, mail, reports, run progress) for a bead and sends them to an AI model for deep-dive diagnostics.

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

### `foreman doctor`

Health checks for Foreman installation. Validates br binary, Pi SDK, DB integrity, prompt files, and workflow configs.

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

### `foreman reset`

Reset failed or stuck runs. Cleans up worktrees, deletes branches, and resets bead status to open.

```bash
foreman reset                     # Reset all failed/stuck runs
foreman reset --project my-project # Reset runs in a registered project without cd
foreman reset --bead bd-abc1      # Reset a specific bead
foreman reset --all               # Reset ALL active runs (nuclear option)
foreman reset --detect-stuck      # Find and reset stuck agents
foreman reset --dry-run           # Preview what would be reset
```

| Option | Default | Description |
|--------|---------|-------------|
| `--bead <id>` | — | Reset a specific bead's runs |
| `--all` | — | Reset ALL active runs |
| `--detect-stuck` | — | Run stuck detection first |
| `--timeout <minutes>` | `15` | Stuck detection timeout |
| `--dry-run` | — | Preview changes |
| `--project <name-or-path>` | — | Target a registered project name or absolute project path |

### `foreman retry`

Reset a bead and optionally re-dispatch it immediately.

```bash
foreman retry bd-abc1             # Reset bead to open
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
foreman stop bd-abc1              # Stop a specific bead's agent
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

Merge completed agent work into the target branch via the refinery.

```bash
foreman merge                     # Process merge queue
foreman merge --bead bd-abc1      # Merge a specific bead
foreman merge --list              # List beads ready to merge
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
| `--bead <id>` | — | Merge a single bead |
| `--list` | — | List beads ready to merge |
| `--dry-run` | — | Preview merge operations |
| `--resolve <runId>` | — | Resolve a merge conflict |
| `--strategy <strategy>` | — | Conflict resolution: `theirs` or `abort` |
| `--auto-retry` | — | Auto-retry with exponential backoff |
| `--stats [period]` | — | Show merge cost stats (`daily`, `weekly`, `monthly`, `all`) |
| `--json` | — | Output as JSON |

### `foreman pr`

Create GitHub pull requests for completed work.

```bash
foreman pr                        # Create PRs for all completed beads
foreman pr --draft                # Create as draft PRs
foreman pr --base-branch dev      # PR against dev instead of main
```

| Option | Default | Description |
|--------|---------|-------------|
| `--base-branch <branch>` | `main` | Base branch for PRs |
| `--draft` | — | Create draft PRs |

---

## Agent Mail

### `foreman inbox`

View the Agent Mail inbox — messages sent between pipeline phases and the foreman orchestrator.

```bash
foreman inbox                     # Show latest run's messages
foreman inbox --bead bd-abc1      # Messages for a specific bead
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
| `--bead <id>` | — | Resolve run by bead ID |
| `--all` | — | Show/watch messages across all runs |
| `--watch` | — | Poll every 2 seconds for new messages |
| `--unread` | — | Show only unread messages |
| `--limit <n>` | `50` | Maximum messages to show |
| `--ack` | — | Mark shown messages as read |

### `foreman mail send`

Send an Agent Mail message (used within pipeline runs for inter-agent communication).

```bash
foreman mail send \
  --run-id "abc123" \
  --from "developer" \
  --to "foreman" \
  --subject "phase-complete" \
  --body '{"phase":"developer","status":"complete"}'
```

| Option | Default | Description |
|--------|---------|-------------|
| `--run-id <id>` | `$FOREMAN_RUN_ID` | Run ID (falls back to env var) |
| `--from <agent>` | `$FOREMAN_AGENT_ROLE` | Sender role |
| `--to <agent>` | *required* | Recipient role |
| `--subject <subject>` | *required* | Message subject |
| `--body <json>` | `'{}'` | Message body (JSON string) |

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
```

| Option | Default | Description |
|--------|---------|-------------|
| `--prd-only` | — | Stop after PRD generation |
| `--from-prd <path>` | — | Start from an existing PRD file |
| `--output-dir <dir>` | `./docs` | Output directory for PRD/TRD |
| `--runtime <runtime>` | `claude-code` | AI runtime (`claude-code` or `codex`) |
| `--dry-run` | — | Show steps without executing |

### `foreman sling trd`

Convert a Technical Requirements Document into a bead task hierarchy with dependencies.

```bash
foreman sling trd docs/TRD.md    # Create beads from TRD
foreman sling trd docs/TRD.md --dry-run  # Preview
foreman sling trd docs/TRD.md --json     # Output parsed structure
foreman sling trd docs/TRD.md --auto     # Skip confirmation prompts
foreman sling trd docs/TRD.md --skip-completed   # Skip [x] items
foreman sling trd docs/TRD.md --close-completed  # Create and close [x] items
foreman sling trd docs/TRD.md --br-only  # Write to beads_rust only
```

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview without creating beads |
| `--auto` | Skip confirmation prompts |
| `--json` | Output parsed structure as JSON |
| `--br-only` | Write to beads_rust only (skip bv) |
| `--skip-completed` | Skip `[x]` completed tasks |
| `--close-completed` | Create and immediately close `[x]` tasks |
| `--no-parallel` | Disable parallel sprint detection |
| `--force` | Recreate tasks even if they exist |
| `--no-risks` | Skip risk register items |
| `--no-quality` | Skip quality requirements |

### `foreman bead`

Create beads from natural language descriptions using AI parsing. Newly created beads start in the approval backlog — use `foreman task approve <bead-id>` before `foreman run` can dispatch them.

```bash
foreman bead "Fix the login timeout bug"
foreman bead "Add dark mode support" --type feature --priority P1
foreman bead docs/issue.md        # From a file
foreman bead "..." --parent bd-abc1  # Set parent bead
foreman bead "..." --dry-run      # Preview
foreman bead "..." --no-llm       # Skip AI parsing (manual fields required)
```

| Option | Default | Description |
|--------|---------|-------------|
| `--type <type>` | auto-detected | Force type: `task`, `bug`, `feature`, `epic`, `chore`, `decision` |
| `--priority <priority>` | auto-detected | Force priority: `P0`–`P4` |
| `--parent <id>` | — | Parent bead ID |
| `--dry-run` | — | Preview without creating |
| `--no-llm` | — | Skip LLM parsing |
| `--model <model>` | — | Claude model for AI parsing |

> **Approval required:** Beads created via `foreman bead` start with the `foreman:backlog` label and must be approved with `foreman task approve <bead-id>` before `foreman run` can dispatch them.

---

## Task Management

### `foreman task`

Beads-first task helpers. The primary operator path for day-to-day task tracking remains `br` / `.beads/` via beads_rust. `foreman task` exposes helper commands for the approval flow and transitional native-task import.

### `foreman task approve`

Approve a backlog bead so `foreman run` can dispatch it. Beads created via `foreman bead`, `foreman sling trd`, or direct `br create` start with the `foreman:backlog` label and are skipped by the dispatcher until approved.

```bash
foreman task approve bd-abc1              # Approve a bead for dispatch
foreman task approve bd-abc1 --project my-project  # Approve against a registered project
foreman task approve bd-abc1 --no-recursive  # Approve only this bead, not its children
```

| Option | Default | Description |
|--------|---------|-------------|
| `--project <name>` | current directory | Registered project name |
| `--project-path <absolute-path>` | — | Absolute project path |
| `--no-recursive` | — | Do not approve child beads recursively |

### `foreman task import`

Transitional migration helper that imports `.beads/` data into the native-task SQLite prototype store. This exists only to support older experiments migrating from beads-first to native-task tables. **Do not use for new projects.**

```bash
foreman task import --from-beads           # Import beads into native-task store
foreman task import --from-beads --dry-run  # Preview without writing
```

| Option | Description |
|--------|-------------|
| `--from-beads` | Import from `.beads/issues.jsonl` or `.beads/beads.jsonl` |
| `--dry-run` | Preview without writing tasks |
| `--project <name>` | Registered project name |
| `--project-path <absolute-path>` | Absolute project path |

---

## Agent Sessions

### `foreman attach`

Attach to a running or completed agent session to inspect its state.

```bash
foreman attach                    # Attach to latest session
foreman attach bd-abc1            # Attach to specific bead
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

### `foreman purge-zombie-runs`

Remove failed run records for beads that are already closed or no longer exist. Reduces database clutter.

```bash
foreman purge-zombie-runs         # Clean up zombie records
foreman purge-zombie-runs --dry-run  # Preview
```

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview without making changes |

### `foreman monitor` (deprecated)

Use `foreman reset --detect-stuck` instead.

```bash
foreman monitor --recover         # Auto-recover stuck agents
foreman monitor --timeout 30      # Set stuck timeout to 30 minutes
```
