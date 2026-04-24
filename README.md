# Foreman 👷

[![CI](https://github.com/ldangelo/foreman/actions/workflows/ci.yml/badge.svg)](https://github.com/ldangelo/foreman/actions/workflows/ci.yml)

> The foreman doesn't write the code — they manage the crew that does.

Multi-agent coding orchestrator. Decomposes development work into parallelizable tasks, dispatches them to AI coding agents in isolated git worktrees, and automatically merges results back — all driven by a real-time pipeline and inter-agent messaging.

## Why Foreman?

You already have AI coding agents. What you don't have is a way to run several of them simultaneously on the same codebase without them stepping on each other. Foreman solves this:

- **Work decomposition** — PRD → TRD → native tasks (with beads compatibility fallback)
- **Git isolation** — each agent gets its own worktree (zero conflicts during development)
- **Pipeline phases** — Explorer → Developer ↔ QA → Reviewer → Finalize
- **Pi SDK runtime** — agents run in-process via `@mariozechner/pi-coding-agent` SDK (`createAgentSession`)
- **Built-in messaging** — SQLite-backed inter-agent messaging with native `send_mail` tool, phase lifecycle notifications, and file reservations
- **Auto-merge** — completed branches rebase onto target and merge automatically via the refinery
- **Progress tracking** — every task, agent, and phase tracked in SQLite, with beads fallback where needed

## Architecture

```
Foreman CLI / Dispatcher
  │
  ├─ per task: agent-worker.ts (detached process)
  │    └─ Pi SDK (in-process)
  │       createAgentSession() → session.prompt()
  │       Tools: read, write, edit, bash, grep, find, ls, send_mail
  │
  ├─ Pipeline Executor (workflow YAML-driven)
  │    Phases defined in ~/.foreman/workflows/*.yaml
  │    Model selection, retries, mail hooks, artifacts — all YAML config
  │    Per-phase trace artifacts → docs/reports/{seedId}/{PHASE}_TRACE.{md,json}
  │
  ├─ Messaging (SQLite, .foreman/foreman.db — no external server)
  │    send_mail tool: agents call directly as a native Pi SDK tool
  │    Lifecycle: phase-started, phase-complete, agent-error
  │    Coordination: branch-ready, merge-complete, task-closed
  │    File reservations: prevent concurrent worktree conflicts
  │
  └─ Refinery + autoMerge
       Triggers immediately after finalize phase
       T1/T2: TypeScript auto-merge (fast path, no LLM)
       T3/T4: AI conflict resolution via Pi session
```

**Pipeline phases** (orchestrated by TypeScript, not AI):
1. **Explorer** (Haiku, 30 turns, read-only) — codebase analysis → `EXPLORER_REPORT.md`
2. **Developer** (Sonnet, 80 turns, read+write) — implementation + tests
3. **QA** (Sonnet, 30 turns, read+bash) — test verification → `QA_REPORT.md`
4. **Reviewer** (Sonnet, 20 turns, read-only) — code review → `REVIEW.md`
5. **Finalize** — git add/commit/push, native task merge/close update (or beads fallback)

Dev ↔ QA retries up to 2x before proceeding to Review.

## Dispatch Flow

The following diagram shows the full lifecycle of a task from `foreman run` to merged branch:

```mermaid
flowchart TD
    subgraph CLI["foreman run"]
        A[User runs foreman run] --> B[Dispatcher.dispatch]
        B --> C{Check agent slots\navailable?}
        C -- No slots --> DONE[Return: skipped]
        C -- Slots open --> D[native ready tasks or br fallback]
        D --> E{selectStrategy}
        E -- bv available --> F[bv.robotTriage → score + sort by AI recommendation]
        E -- br available --> G[br ready → sort by priority P0→P4]
        E -- native only --> H[native ready → sort by priority]
        F --> I[For each task...]
        G --> I
        H --> I
        I --> J{Skip checks}
        J -- already active --> SKIP[Skip: already running]
        J -- completed, unmerged --> SKIP2[Skip: awaiting merge]
        J -- in backoff from stuck --> SKIP3[Skip: exponential backoff]
        J -- over max agents limit --> SKIP4[Skip: agent limit]
        J -- passes all checks --> K[Fetch full task detail\ntitle, description, labels]
    end

    subgraph SETUP["Per-task setup"]
        K --> L[resolveBaseBranch\nstack on dependency branch?]
        L --> M[createWorktree\ngit worktree add foreman/task-id]
        M --> N[Write TASK.md\ninto worktree]
        N --> O[store.createRun → SQLite]
        O --> P[update task status → in_progress]
        P --> Q[spawnAgent]
    end

    subgraph SPAWN["Agent spawn"]
        Q --> R{Pi binary\non PATH?}
        R -- Yes --> S[PiRpcSpawnStrategy\npi --mode rpc JSONL]
        R -- No --> T[Claude SDK\nquery fallback]
        S --> U[Write config.json\nto temp file]
        T --> U
        U --> V[spawn agent-worker.ts\nas detached child process]
        V --> W[store.updateRun → running]
    end

    subgraph WORKER["agent-worker process (detached)"]
        W --> X[Read + delete config.json]
        X --> Y[Open SQLite store\nOpen ~/.foreman/logs/runId.log]
        Y --> Z[Init SqliteMailClient\n.foreman/foreman.db]
        Z --> AA{pipeline mode?}
        AA -- No --> AB[Single agent via Pi RPC]
        AA -- Yes --> AC[runPipeline]
    end

    subgraph PIPELINE["Pipeline phases"]
        AC --> P1

        subgraph P1["Phase 1: Explorer (Haiku, 30 turns, read-only)"]
            P1A[Register agent-mail identity] --> P1B[Run SDK query\nexplorerPrompt]
            P1B --> P1C[Write EXPLORER_REPORT.md]
            P1C --> P1D[Write EXPLORER_TRACE.{md,json}]
            P1D --> P1E[Mail report to developer inbox]
        end

        P1 --> P1_ok{success?}
        P1_ok -- No --> STUCK[markStuck → task reset to open\nexponential backoff]
        P1_ok -- Yes --> P2

        subgraph P2["Phase 2: Developer (Sonnet, 80 turns, read+write)"]
            P2A[Reserve worktree files via Agent Mail] --> P2B[Run SDK query\ndeveloperPrompt + explorer context]
            P2B --> P2C[Write DEVELOPER_REPORT.md]
            P2C --> P2D[Write DEVELOPER_TRACE.{md,json}]
            P2D --> P2E[Release file reservations]
        end

        P2 --> P2_ok{success?}
        P2_ok -- No --> STUCK

        P2_ok -- Yes --> P3

        subgraph P3["Phase 3: QA (Sonnet, 30 turns, read+bash)"]
            P3A[Run SDK query\nqaPrompt + dev report]
            P3A --> P3B[Run tests\nWrite QA_REPORT.md]
            P3B --> P3C[Write QA_TRACE.{md,json}]
            P3C --> P3D[Parse verdict: PASS / FAIL]
        end

        P3 --> P3_ok{QA verdict?}
        P3_ok -- FAIL, retries left --> RETRY[Increment devRetries\nPass QA feedback to dev]
        RETRY --> P2
        P3_ok -- FAIL, max retries --> P4

        P3_ok -- PASS --> P4

        subgraph P4["Phase 4: Reviewer (Sonnet, 20 turns, read-only)"]
            P4A[Run SDK query\nreviewerPrompt]
            P4A --> P4B[Write REVIEW.md]
            P4B --> P4C[Write REVIEWER_TRACE.{md,json}]
            P4C --> P4D{CRITICAL or\nWARNING issues?}
            P4D -- Yes --> FAIL_REV[Mark pipeline FAILED_REVIEW]
        end

        P4D -- No --> P5

        subgraph P5["Phase 5: Finalize"]
            P5A[git add, commit, push\nforeman/task-id branch]
            P5A --> P5B[native task merge/close or br fallback]
            P5B --> P5C[Enqueue to MergeQueue\nmail branch-ready to merge-agent]
        end
    end

    subgraph MERGE["Merge queue"]
        P5C --> MQ1[MergeQueue picks up branch]
        MQ1 --> MQ2{Conflict tier?}
        MQ2 -- T1/T2: no conflicts --> MQ3[Auto-rebase + merge to main]
        MQ2 -- T3/T4: conflicts --> MQ4[AI conflict resolution via Pi session]
        MQ4 --> MQ3
        MQ3 --> MQ5[mail merge-complete to foreman]
        MQ5 --> MQ6[store.updateRun → merged]
    end
```

**Key decision points:**

| Decision | Outcome |
|---|---|
| **Backoff check** | Task recently failed/stuck → exponential delay before retry |
| **Dependency stacking** | Task depends on open task → worktree branches from that dependency's branch |
| **Pi vs SDK** | `pi` binary on PATH → JSONL RPC protocol; otherwise Claude SDK `query()` |
| **Pipeline vs single** | `--pipeline` flag → 4-phase orchestration; otherwise single agent |
| **Dev↔QA retry** | Max 2 retries; QA feedback injected into next developer prompt |
| **Reviewer FAIL** | CRITICAL/WARNING issues → run marked failed, task reset to open |
| **Merge tiers T1-T4** | T1/T2 = TypeScript auto-merge; T3/T4 = AI-assisted conflict resolution |

## Prerequisites

- **Node.js 20+**
- **[beads_rust](https://github.com/Dicklesworthstone/beads_rust)** (`br`) — compatibility fallback for legacy task flows
  ```bash
  cargo install beads_rust
  # or: download binary to ~/.local/bin/br
  ```
- **[Pi](https://pi.dev)** _(installed as npm dependency)_ — agent runtime via `@mariozechner/pi-coding-agent` SDK. No separate binary needed.
- **Anthropic API key** — `export ANTHROPIC_API_KEY=sk-ant-...` or log in via Pi: `pi /login`

## Installation

### Homebrew (macOS / Linux — recommended)

```bash
brew tap oftheangels/tap
brew install foreman
```

### npm

```bash
npm install -g @oftheangels/foreman
```

### curl (macOS / Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/ldangelo/foreman/main/install.sh | sh
```

## Development with Devbox + Docker

Foreman does not currently ship a checked-in containerized dev environment by default, but this repository now includes:

- `devbox.json` — reproducible local shell with Node 20, Postgres client tools, git, and helper scripts
- `compose.yaml` — local Postgres container for daemon + migration development

### Prerequisites

- [Devbox](https://www.jetify.com/devbox/)
- A Docker runtime on your machine (Docker Desktop, Colima, or OrbStack)

### Quickstart

```bash
devbox shell
devbox run install
devbox run db:up
devbox run db:migrate
```

The default local database URL inside the devbox shell is:

```bash
postgresql://postgres:postgres@127.0.0.1:5432/foreman
```

### Common Devbox commands

```bash
devbox run db:up            # start local Postgres
devbox run db:down          # stop local Postgres
devbox run db:reset         # recreate the Postgres volume and rerun migrations
devbox run db:logs          # follow Postgres logs
devbox run db:psql          # connect with psql
devbox run db:migrate       # run node-pg-migrate up
devbox run db:migrate:create -- add-runs-table
devbox run daemon:start     # build, migrate, and start the daemon
devbox run test             # run the full test suite
```

If you prefer not to use Docker for Postgres, override `DATABASE_URL` in your shell or `.env` and run the normal npm migration scripts directly.

### PowerShell (Windows)

```powershell
irm https://raw.githubusercontent.com/ldangelo/foreman/main/install.ps1 | iex
```

### Verify installation

```bash
foreman --version
foreman doctor              # Check dependencies (br, API key, etc.)
```

> **Migration note:** `br` is still recommended during the transition period for compatibility/fallback flows. Native-task projects can use most Foreman paths without it, but keeping `br` installed avoids surprises on legacy paths.

## Quick Start

```bash
# 1. Initialize in your project
cd ~/your-project
foreman init --name my-project

# 2. Create or import tasks
foreman task create "Add user auth" --type feature --priority 1
foreman task create "Write auth tests" --type task --priority 2
# or migrate an existing beads project
foreman task import --from-beads

# 3. Dispatch agents to ready tasks
foreman run

# 4. Monitor progress
foreman status

# 5. Merge completed branches (runs automatically in foreman run loop)
foreman merge
```

## Messaging

Foreman includes a built-in messaging system for inter-agent communication and pipeline coordination. Messages are stored in SQLite (`.foreman/foreman.db`) — no external server, no HTTP, no additional dependencies.

### How agents send messages

Agents use the native **`send_mail`** tool, registered as a Pi SDK ToolDefinition. This is a structured tool call — agents don't run bash commands or invoke skills to send messages.

```
Tool: send_mail
Parameters:
  to: "foreman"
  subject: "agent-error"
  body: '{"phase":"developer","error":"type check failed"}'
```

The pipeline executor also sends lifecycle messages automatically (phase-started, phase-complete) based on the [workflow YAML mail hooks](docs/workflow-yaml-reference.md).

### Message types

| Subject | From → To | When |
|---|---|---|
| `worktree-created` | foreman → foreman | Worktree initialized for a task |
| `task-claimed` | foreman → foreman | Task dispatched to an agent |
| `phase-started` | executor → foreman | Phase begins (YAML: `mail.onStart`) |
| `phase-complete` | executor → foreman | Phase succeeds (YAML: `mail.onComplete`) |
| `agent-error` | agent → foreman | Agent encounters an error |
| `branch-ready` | foreman → refinery | Finalize complete, ready to merge |
| `merge-complete` | refinery → foreman | Branch merged to target |
| `merge-failed` | refinery → foreman | Merge failed (conflicts, tests) |
| `task-closed` | refinery → foreman | Task closed after successful merge |

### Viewing messages

```bash
foreman inbox                     # Latest run's messages
foreman inbox --task task-abc      # Messages for a specific task
foreman inbox --all --watch       # Live stream across all runs
foreman debug <task-id>            # AI analysis including full mail timeline + trace artifacts
```

### File reservations

Phases that modify files can reserve the worktree directory to prevent concurrent access:

```yaml
# In workflow YAML
files:
  reserve: true
  leaseSecs: 600
```

## Pi SDK Integration

Foreman uses the [Pi SDK](https://pi.dev) (`@mariozechner/pi-coding-agent`) to run AI agents in-process. Each pipeline phase creates a fresh `AgentSession` with phase-specific tools and model configuration.

### How agents run

```typescript
const { session } = await createAgentSession({
  cwd: worktreePath,
  model: getModel("anthropic", "claude-sonnet-4-6"),
  tools: [createReadTool(cwd), createBashTool(cwd), ...],
  customTools: [createSendMailTool(mailClient, agentRole)],
  sessionManager: SessionManager.inMemory(),
});
await session.prompt(phasePrompt);
```

### Custom tools

The `send_mail` tool is registered as a custom `ToolDefinition` on every agent session:

| Tool | Description |
|------|-------------|
| `send_mail` | Send messages to other agents or foreman. Used for error reporting. |

Standard Pi tools are also available per phase (configured in [workflow YAML](docs/workflow-yaml-reference.md)):
- `read`, `write`, `edit` — file operations
- `bash` — shell command execution
- `grep`, `find`, `ls` — search and navigation

### Phase model configuration

Models are configured per-phase in the workflow YAML with priority-based overrides. See [Workflow YAML Reference](docs/workflow-yaml-reference.md) for full details.

| Phase | Default Model | P0 Override | Max Turns |
|---|---|---|---|
| Explorer | haiku | sonnet | 30 |
| Developer | sonnet | opus | 80 |
| QA | sonnet | opus | 30 |
| Reviewer | sonnet | opus | 20 |
| Finalize | haiku | — | 20 |

### Per-phase trace artifacts

Each phase emits detailed observability traces to the worktree:

```
{worktree}/
└── docs/
    └── reports/
        └── {seedId}/
            ├── EXPLORER_TRACE.md   # Markdown trace + JSON
            ├── DEVELOPER_TRACE.md
            ├── QA_TRACE.md
            ├── REVIEWER_TRACE.md
            └── FINALIZE_TRACE.md
```

Each trace file contains:
- **Metadata**: run ID, model, workflow, timestamps, success status
- **Prompt**: the full prompt sent to the agent
- **Resolved command**: (for command-style phases) the actual shell command
- **Final output**: the agent's final message
- **Tool calls**: every tool invocation with timing, arguments, and results
- **Warnings**: any issues detected during phase execution

Use `foreman debug <task-id> --raw` to inspect all trace artifacts for a task.

## Commands

For the complete CLI reference with all options and examples, see **[CLI Reference](docs/cli-reference.md)**.

For common problems and solutions, see **[Troubleshooting Guide](docs/troubleshooting.md)**.

### `foreman init`
Initialize Foreman in a project directory. Registers the project and sets up `.foreman/`.

```bash
foreman init --name "my-project"
```

### `foreman run`
Dispatch AI coding agents to ready tasks. Enters a watch loop that auto-merges completed branches.

```bash
foreman run                              # Dispatch to all ready tasks
foreman run --project my-project         # Dispatch without cd into a registered project
foreman run --task task-abc              # Dispatch one specific task
foreman run --max-agents 3               # Limit concurrent agents
foreman run --model claude-opus-4-6      # Override model for all agents
foreman run --no-tests                   # Skip test suite in merge step
foreman run --dry-run                    # Preview without dispatching
```

Each agent gets:
- Its own git worktree (branch: `foreman/<task-id>`)
- A `TASK.md` with task instructions, phase prompts, and task context
- Native task status updates (or `br` fallback for legacy projects)
- Phase-specific tool restrictions (via Pi extension or SDK `disallowedTools`)

### `foreman status`
Show current task and agent status, or aggregate across projects from the dashboard/status surfaces.

```bash
foreman status
foreman status --project my-project      # Inspect a registered project without cd
foreman status --watch                   # Live-updating display
foreman status --live                    # Full dashboard TUI with event stream
```

### `foreman board`
Terminal UI kanban board for managing Foreman tasks. Six status columns with vim-style navigation.

```bash
foreman board                             # Launch interactive kanban board
foreman board --project my-project        # Board for a specific project
```

### `foreman dashboard`
Multi-project dashboard with run progress, metrics, and human-attention tasks.

```bash
foreman dashboard                         # Multi-project overview
foreman dashboard --simple                # Compact single-project view with task counts
foreman dashboard --project my-project    # Single project deep dive
```

Project-aware operator commands (`run`, `status`, `reset`, and `retry`) accept `--project <name-or-path>`. Registered names resolve through `~/.foreman/projects.json`; absolute paths still work for direct one-off targeting.

### `foreman merge`
Merge completed work branches back to main. Runs automatically in the `foreman run` loop.

```bash
foreman merge                           # Merge all completed
foreman merge --target-branch develop    # Merge to develop
foreman merge --no-tests                 # Skip test suite
foreman merge --test-command "npm test"  # Custom test command
```

Auto-merge tiers (T1–T4):
- **T1**: Fast-forward or trivial rebase — no conflicts
- **T2**: Auto-resolve report-file conflicts (`.beads/` compatibility data, `EXPLORER_REPORT.md`, etc.)
- **T3**: AI-assisted conflict resolution via Pi session
- **T4**: Create PR for human review (true code conflicts)

### `foreman plan`
Run the PRD → TRD pipeline using Ensemble slash commands.

```bash
foreman plan "Build a user auth system with OAuth2"
foreman plan docs/description.md              # From file
foreman plan --from-prd docs/PRD.md "unused"  # Skip to TRD
foreman plan --prd-only "Build a REST API"    # Stop after PRD
```

### `foreman sling trd`
Parse a TRD and create a native task hierarchy (or compatibility beads when explicitly requested).

```bash
foreman sling trd docs/TRD.md           # Parse and create tasks
foreman sling trd docs/TRD.md --dry-run # Preview without creating
foreman sling trd docs/TRD.md --auto    # Skip confirmation
```

### `foreman doctor`
Check environment health: br binary, Pi binary, Agent Mail server, SQLite integrity.

```bash
foreman doctor
foreman doctor --fix                    # Auto-fix recoverable issues
```

### `foreman inbox`
View inter-agent messages from pipeline runs.

```bash
foreman inbox                            # Latest run's messages
foreman inbox --task task-abc           # Messages for a specific task
foreman inbox --all                     # All runs
foreman inbox --all --watch             # Live stream across all runs
```

### `foreman worktree`
Manage git worktrees created for active tasks.

```bash
foreman worktree list                    # List active worktrees
foreman worktree clean                   # Remove orphaned worktrees
foreman worktree clean --all             # Remove all including active ones
```

### `foreman sentinel`
QA sentinel for continuous testing on the main branch.

```bash
foreman sentinel run-once               # Run tests once and exit
foreman sentinel start                   # Background daemon mode
foreman sentinel stop                    # Stop background sentinel
foreman sentinel status                  # Show sentinel status
```

### `foreman reset`
Reset failed/stuck runs: kill agents, remove worktrees, reset tasks to a dispatchable state.

```bash
foreman reset                           # Reset failed/stuck runs
foreman reset --project my-project      # Reset runs in a registered project without cd
foreman reset --all                     # Reset ALL active runs
foreman reset --detect-stuck            # Detect stuck runs first, then reset
foreman reset --detect-stuck --timeout 20  # Stuck after 20 minutes
```

### `foreman retry`
Retry a task in place, optionally dispatching it again immediately.

```bash
foreman retry task-abc                  # Reset one task to ready
foreman retry task-abc --dispatch       # Reset and dispatch immediately
foreman retry task-abc --dry-run        # Preview the retry flow
```

### `foreman pr`
Create pull requests for completed branches that couldn't be auto-merged.

```bash
foreman pr
```

### `foreman debug`
AI-powered execution analysis using Opus to investigate pipeline runs.

```bash
foreman debug task-abc                  # Full Opus analysis of a run
foreman debug task-abc --raw            # Raw artifacts without AI analysis
foreman debug task-abc --model sonnet   # Cheaper model for analysis
```

### `foreman attach`
Attach to a running agent session for live interaction.

```bash
foreman attach <run-id>                 # Attach to a running session
foreman attach --list                   # List available sessions
foreman attach --follow <id>            # Follow log output
foreman attach --kill <id>              # Kill a running agent
```

## Task Tracking

Foreman uses **native tasks** stored in the SQLite store (`.foreman/foreman.db`). Tasks are created, tracked, and closed entirely within Foreman.

```bash
# Native task lifecycle
foreman task create "Implement feature X" --type feature --priority 1
foreman task list
foreman task approve task-123
foreman task update task-123 --status in-progress
foreman task close task-123
foreman task dep add task-tests task-feature   # tests depend on feature
foreman task dep list task-123                 # show dependencies
```

For projects using [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`) for backward compatibility:

```bash
# View ready tasks (legacy/fallback path)
br ready

# Create tasks directly in beads
br create --title "Implement feature X" --type feature --priority 1
br create --title "Fix bug Y" --type bug --priority 0

# Work lifecycle
br update task-abc --status=in_progress
br close task-abc --reason="Completed"

# Dependencies
br dep add task-tests task-feature    # tests depend on feature

# Sync with git
br sync --flush-only               # Export DB to JSONL before committing
```

Set `FOREMAN_TASK_STORE=native|beads|auto` to force or inspect task-store selection behavior.

Priority scale: 0 (critical) → 1 (high) → 2 (medium) → 3 (low) → 4 (backlog).

## Configuration

### Workflow YAML

Foreman pipelines are configured via workflow YAML files. See the **[Workflow YAML Reference](docs/workflow-yaml-reference.md)** for complete documentation with examples for Node.js, .NET, Go, Python, and Rust.

Workflows define:
- **Setup steps** — dependency installation, build commands (stack-agnostic)
- **Setup cache** — symlink dependency directories from a shared cache
- **Phase sequence** — which agents run in what order
- **Model selection** — per-phase models with priority-based overrides
- **Retry loops** — QA/Reviewer failure → Developer retry with feedback
- **Mail hooks** — lifecycle notifications and artifact forwarding

```yaml
# ~/.foreman/workflows/default.yaml (global override)
name: default
setup:
  - command: npm install --prefer-offline --no-audit
    failFatal: true
setupCache:
  key: package-lock.json
  path: node_modules
phases:
  - name: developer
    prompt: developer.md
    models:
      default: sonnet
      P0: opus
    maxTurns: 80
  - name: qa
    prompt: qa.md
    verdict: true
    retryWith: developer
    retryOnFail: 2
```

### Environment variables

```bash
export ANTHROPIC_API_KEY=sk-ant-...          # Required (or use `pi /login` for OAuth)
export FOREMAN_MAX_AGENTS=5                  # Max concurrent agents (default: 5)
```

### Storage locations

| Path | Contents |
|---|---|
| `.beads/` | legacy/compatibility beads_rust task database (JSONL, git-tracked) |
| `.foreman/foreman.db` | SQLite: runs, merge_queue, projects |
| `.foreman-worktrees/` | Git worktrees for active agents |
| `~/.foreman/logs/` | Per-run agent logs |

## Project Structure

```
foreman/
├── src/
│   ├── cli/                        # CLI entry point + commands
│   │   └── commands/
│   │       ├── run.ts              # Main dispatch + merge loop
│   │       ├── status.ts           # Status display
│   │       ├── merge.ts            # Manual merge trigger
│   │       └── doctor.ts           # Health checks
│   ├── orchestrator/               # Core orchestration engine
│   │   ├── dispatcher.ts           # Task → agent spawning strategies
│   │   ├── pi-rpc-spawn-strategy.ts  # Pi RPC spawn (primary)
│   │   ├── agent-worker.ts         # Claude SDK pipeline (fallback)
│   │   ├── agent-mail-client.ts    # Agent Mail HTTP wrapper
│   │   ├── refinery.ts             # Merge + test + cleanup
│   │   ├── conflict-resolver.ts    # T1-T4 conflict resolution
│   │   ├── roles.ts                # Phase prompts + tool configs
│   │   └── sentinel.ts             # Background health monitor
│   └── lib/
│       ├── beads-rust.ts           # compatibility br CLI wrapper
│       ├── git.ts                  # Git worktree management
│       └── store.ts                # SQLite state store
├── packages/
│   └── foreman-pi-extensions/      # Pi extension package
│       ├── src/tool-gate.ts        # Block disallowed tools per phase
│       ├── src/budget-enforcer.ts  # Turn + token limits
│       └── src/audit-logger.ts     # Audit trail → Agent Mail
└── docs/
    ├── TRD/                        # Technical Requirements Documents
    └── PRD/                        # Product Requirements Documents
```

## Standalone Binaries

Foreman can be distributed as a standalone executable for all 5 platforms — no Node.js required. Binaries are compiled via [pkg](https://github.com/yao-pkg/pkg) which embeds the CJS bundle + Node.js runtime.

> **Note:** `better_sqlite3.node` (native addon) is a _side-car_ file that must stay in the same directory as the binary. It cannot be embedded inside the executable.

### Quick Build

```bash
# Full pipeline: tsc → CJS bundle → compile all 5 platforms
npm run build:binaries

# Dry-run (prints commands, does not compile)
npm run build:binaries:dry-run

# Single target (e.g. darwin-arm64)
npm run build && npm run bundle:cjs
tsx scripts/compile-binary.ts --target darwin-arm64
```

### Output Structure

```
dist/binaries/
  darwin-arm64/
    foreman-darwin-arm64      # macOS Apple Silicon
    better_sqlite3.node       # side-car native addon
  darwin-x64/
    foreman-darwin-x64        # macOS Intel
    better_sqlite3.node
  linux-x64/
    foreman-linux-x64         # Linux x86-64
    better_sqlite3.node
  linux-arm64/
    foreman-linux-arm64       # Linux ARM64 (e.g. AWS Graviton)
    better_sqlite3.node
  win-x64/
    foreman-win-x64.exe       # Windows x64
    better_sqlite3.node
```

### Cross-Platform Compilation

`better_sqlite3.node` differs per platform. The prebuilt binaries for all 5 targets are committed to `scripts/prebuilds/`. To refresh them from the better-sqlite3 GitHub Releases:

```bash
npm run prebuilds:download          # Download for all targets
npm run prebuilds:download:force    # Re-download even if present
npm run prebuilds:status            # Check what's available
```

### Semantic Versioning & Conventional Commits

Foreman uses **[release-please](https://github.com/googleapis/release-please)** for automated semantic versioning driven by [Conventional Commits](https://www.conventionalcommits.org/).

#### How it works

1. Merge a PR to `main` whose commits (or PR title) follow the conventional-commit format.
2. The `.github/workflows/release.yml` workflow runs `release-please`, which:
   - Inspects commits since the last release tag.
   - Opens (or updates) a **Release PR** with a bumped `package.json` version and an updated `CHANGELOG.md`.
3. Merge the Release PR → release-please creates the GitHub Release + tag.
4. The `release-binaries.yml` workflow fires on the new tag and publishes platform binaries.

#### Commit prefix → version bump

| Prefix | Bump |
|--------|------|
| `fix:` | patch (0.1.0 → 0.1.1) |
| `feat:` | minor (0.1.0 → 0.2.0) |
| `feat!:` or `BREAKING CHANGE:` footer | major (0.1.0 → 1.0.0) |

#### Examples

```
feat: add --dry-run flag to foreman run
fix: handle missing EXPLORER_REPORT.md gracefully
feat!: rename foreman monitor to foreman sentinel

BREAKING CHANGE: The monitor subcommand has been renamed to sentinel.
```

#### Configuration files

- `release-please-config.json` — release-please package config
- `.release-please-manifest.json` — current version manifest (updated by release-please)
- `CHANGELOG.md` — auto-generated; do not edit manually

### CI / Automated Releases

The `.github/workflows/release-binaries.yml` workflow:
- Triggers on `v*.*.*` tag push (created automatically by release-please)
- Compiles all 5 platform binaries on Ubuntu (cross-compilation via prebuilds)
- Smoke-tests the linux-x64 binary
- Packages each platform as `.tar.gz` (zip for Windows)
- Creates a GitHub Release with all assets attached

To trigger a release manually (bypassing release-please):

```bash
git tag v1.0.0
git push origin v1.0.0
```

Or trigger manually from the Actions tab with optional dry-run mode.

### Advanced Installation Options

For additional install options (specific versions, custom directories, manual binary download), see the [CLI Reference](docs/cli-reference.md) and [Troubleshooting Guide](docs/troubleshooting.md).

## Development

If you want to contribute or build from source:

```bash
# Clone and build
git clone https://github.com/ldangelo/foreman
cd foreman
npm install && npm run build

# Link for local development
npm link

# Development commands
npm run build          # TypeScript compile (atomic — safe while foreman is running)
npm test               # run the full PR-required Vitest lanes
npm run dev            # tsx watch mode
npx tsc --noEmit       # Type check only
npm run bundle         # esbuild single-file bundle
```

**Rules:**
- TypeScript strict mode — no `any` escape hatches
- ESM only — all imports use `.js` extensions
- TDD — RED-GREEN-REFACTOR cycle
- Test coverage — unit ≥ 80%, integration ≥ 70%
- `br sync --flush-only` before every git commit

## License

MIT

---

Built by [Leo D'Angelo](https://www.linkedin.com/in/leo-d-angelo-5a0a83) at [Fortium Partners](https://fortiumpartners.com).
