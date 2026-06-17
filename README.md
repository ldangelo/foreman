# Foreman 👷

[![CI](https://github.com/ldangelo/foreman/actions/workflows/ci.yml/badge.svg)](https://github.com/ldangelo/foreman/actions/workflows/ci.yml)

> The foreman doesn't write the code — they manage the crew that does.

**What it does:** Foreman is a multi-agent coding orchestrator. It coordinates multiple AI coding agents to work in parallel on the same codebase using git worktrees for isolation, orchestrating a 5-phase pipeline (Explorer → Developer ↔ QA → Reviewer → Finalize) with automatic merging, inter-agent messaging, and progress tracking.

Foreman decomposes development work into parallelizable tasks, dispatches them to AI coding agents in isolated git worktrees, and automatically merges results back — all tracked through a PostgreSQL-backed daemon for multi-project aggregation.

## Why Foreman?

You already have AI coding agents. What you don't have is a way to run several of them simultaneously on the same codebase without them stepping on each other. Foreman solves this:

- **Work decomposition** — PRD → TRD → native tasks (PostgreSQL-backed via daemon, PostgreSQL for standalone)
- **Git isolation** — each agent gets its own worktree (zero conflicts during development)
- **Pipeline phases** — Explorer → Developer ↔ QA → Reviewer → Finalize
- **Pi SDK runtime** — agents run in-process via `@mariozechner/pi-coding-agent` SDK (`createAgentSession`)
- **Persistent daemon** — ForemanDaemon optionally runs in background to serve tRPC over Unix socket + HTTP, sharing a Postgres pool across all CLI invocations
- **Built-in messaging** — Agent Mail with phase lifecycle notifications and file reservations; PostgreSQL or Postgres-backed depending on daemon mode
- **Native task storage** — PostgreSQL-backed tasks for daemon and standalone workflows
- **Auto-merge** — completed branches rebase onto target and merge automatically via the refinery
- **Documentation gate** — workflows include a documentation phase that checks `CLAUDE.md`, `AGENTS.md`, `README.md`, and the Foreman User Guide before finalization
- **Progress tracking** — every task, agent, and phase tracked in PostgreSQL

> **Note:** Foreman uses PostgreSQL when the daemon is running (for multi-project aggregation) and for standalone development. Legacy beads_rust data can be imported with `foreman task import --from-beads`, but it is not a runtime task store.

## Architecture

```
Foreman CLI / Dispatcher
  │
  ├─ ForemanDaemon (optional persistent background process)
  │    ├─ tRPC router over Unix socket + HTTP
  │    │    Procedures: projects, tasks, runs, events, messages
  │    ├─ Postgres pool (PoolManager singleton) — shared across CLI invocations
  │    └─ Fastify web server (optional HTTP port)
  │
  ├─ per task: agent-worker.ts (detached child process)
  │    └─ Pi SDK (in-process)
  │       createAgentSession() → session.prompt()
  │       Tools: read, write, edit, bash, grep, find, ls, send_mail
  │
  ├─ Pipeline Executor (workflow YAML-driven)
  │    Phases defined in ~/.foreman/workflows/*.yaml
  │    Model selection, retries, mail hooks, artifacts — all YAML config
  │    Per-phase reports/traces → ~/.foreman/reports/... (outside repo commits)
  │
  ├─ TrpcClient (CLI → daemon transport)
  │    Unix socket: ~/.foreman/daemon.sock
  │    httpBatchLink → type-safe procedure calls
  │
  └─ Refinery + autoMerge
       Triggers immediately after finalize phase
       T1/T2: TypeScript auto-merge (fast path, no LLM)
       T3/T4: AI conflict resolution via Pi session
```

### Elixir Backend Migration Roles

TRD-2026-014 adds an Elixir/OTP orchestration server alongside the existing Node CLI and Node/Pi workers. The target split is:

- **Node CLI**: parses operator commands, starts or locates the Elixir server, sends authenticated JSON commands/reads, renders projection responses, and keeps deprecated aliases pointing at replacements.
- **Elixir server**: owns durable commands, append-only events, CQRS projections, run/phase actors, scheduler capacity, VCS/PR state machines, inbox/debug/attach views, recovery, doctor/metrics, and authorization audit events.
- **Node/Pi worker layer**: executes Pi SDK-backed phases, receives worker protocol starts, streams ordered events/heartbeats/logs/artifacts back to Elixir, and receives scoped project/run environment metadata.

See [Elixir Backend Architecture](./docs/guides/elixir-backend-architecture.md) for the migration architecture, deprecated command mapping, and event/projection/recovery troubleshooting model.

**ForemanDaemon lifecycle:**
- `foreman daemon start` — validates Postgres, starts Fastify + Unix socket listener
- `foreman daemon stop` — clean shutdown (release pool, close socket)
- `foreman daemon status` — PID, socket path, health endpoint
- Auto-restart on unexpected exit (detected via `foreman doctor`)

> **Note:** Foreman uses PostgreSQL via `DATABASE_URL`. The daemon owns the shared Postgres pool and exposes a tRPC layer for CLI commands, avoiding per-invocation connection overhead and enabling multi-project aggregation.

**Pipeline phases** (orchestrated by TypeScript, not AI):
1. **Explorer** (Haiku, 12 turns, read-only) — concise developer handoff → `EXPLORER_REPORT.md`
2. **Developer** (Sonnet, 50 turns default / 60 turns feature, read+write) — implementation only; QA/finalize own tests
3. **QA** (Sonnet, 30 turns, read+bash) — targeted test verification only → `QA_REPORT.md`
4. **Reviewer** (Sonnet, 20 turns, read-only) — code review → `REVIEW.md`
5. **Documentation** — update required operator/developer docs or explain why no docs changed → `DOCUMENTATION_REPORT.md`
6. **Finalize** — git add/commit/push, native task merge/close update

Dev ↔ QA retries up to 2x before proceeding to Review. Documentation runs before finalization so fixes/features do not merge without an explicit documentation decision.

## Dispatch Flow

The following diagram shows the full lifecycle of a task from `foreman run` to merged branch (daemon is optional — shown if running):

```mermaid
flowchart TD
    subgraph DAEMON["foreman daemon start"]
        DA[Initialize PoolManager → Postgres]
        DB[Start Fastify + Unix socket: ~/.foreman/daemon.sock]
        DC[Health check endpoint responds]
        DA --> DB --> DC
    end

    subgraph CLI["foreman run"]
        A[User runs foreman run] --> B[Dispatcher.dispatch]
        B --> C{daemon reachable?}
        C -- No --> DAEMON_ERR[Error: start daemon first]
        C -- Yes --> D[dependency-unblocked native ready tasks]
        D --> E{selectStrategy}
        E -- AI triage available --> F[score + sort by AI recommendation]
        E -- default --> H[sort by priority P0→P4]
        F --> I[For each task...]
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
        N --> O[daemon: store.createRun → Postgres]
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
        V --> W[daemon: store.updateRun → running]
    end

    subgraph WORKER["agent-worker process (detached)"]
        W --> X[Read + delete config.json]
        X --> Y[Open worktree log\nOpen ~/.foreman/logs/runId.log]
        Y --> Z[Init PostgresMailClient\n(daemon-backed Postgres mail)]
        Z --> AA{pipeline mode?}
        AA -- No --> AB[Single agent via Pi RPC]
        AA -- Yes --> AC[runPipeline]
    end

    subgraph PIPELINE["Pipeline phases"]
        AC --> P1A

        subgraph P1["Phase 1: Explorer (Haiku, 12 turns, read-only)"]
            P1A[Register agent-mail identity] --> P1B[Run SDK query\nexplorerPrompt]
            P1B --> P1C[Write EXPLORER_REPORT.md]
            P1C --> P1D[Write EXPLORER_TRACE.{md,json}]
            P1D --> P1E[Mail report to developer inbox]
        end

        P1A --> P1_ok{success?}
        P1_ok -- No --> STUCK[markStuck → task reset to open\nexponential backoff]
        P1_ok -- Yes --> P2A

        subgraph P2["Phase 2: Developer (Sonnet, 50 turns default / 60 turns feature, read+write)"]
            P2A[Reserve worktree files via Agent Mail] --> P2B[Run SDK query\ndeveloperPrompt + explorer context]
            P2B --> P2C[Write DEVELOPER_REPORT.md]
            P2C --> P2D[Write DEVELOPER_TRACE.{md,json}]
            P2D --> P2E[Release file reservations]
        end

        P2A --> P2_ok{success?}
        P2_ok -- No --> STUCK

        P2_ok -- Yes --> P3A

        subgraph P3["Phase 3: QA (Sonnet, 30 turns, read+bash)"]
            P3A[Run SDK query\nqaPrompt + dev report]
            P3A --> P3B[Run tests\nWrite QA_REPORT.md]
            P3B --> P3C[Write QA_TRACE.{md,json}]
            P3C --> P3D[Parse verdict: PASS / FAIL]
        end

        P3D --> P3_ok{QA verdict?}
        P3_ok -- FAIL, retries left --> RETRY[Increment devRetries\nPass QA feedback to dev]
        RETRY --> P2A
        P3_ok -- FAIL, max retries --> P4A

        P3_ok -- PASS --> P4A

        subgraph P4["Phase 4: Reviewer (Sonnet, 20 turns, read-only)"]
            P4A[Run SDK query\nreviewerPrompt]
            P4A --> P4B[Write REVIEW.md]
            P4B --> P4C[Write REVIEWER_TRACE.{md,json}]
            P4C --> P4D{CRITICAL or\nWARNING issues?}
            P4D -- Yes --> FAIL_REV[Mark pipeline FAILED_REVIEW]
        end

        P4D -- No --> P5A

        subgraph P5["Phase 5: Finalize"]
            P5A[git add, commit, push\nforeman/task-id branch]
            P5A --> P5B[native task merge/close]
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
| **Daemon check** | `foreman run` requires daemon reachable — prompts to start if not |
| **Backoff check** | Task recently failed/stuck → exponential delay before retry |
| **Dependency stacking** | Task depends on open task → worktree branches from that dependency's branch |
| **Pi vs SDK** | `pi` binary on PATH → JSONL RPC protocol; otherwise Claude SDK `query()` |
| **Pipeline vs single** | `--pipeline` flag → 4-phase orchestration; otherwise single agent |
| **Dev↔QA retry** | Max 2 retries; QA feedback injected into next developer prompt |
| **Reviewer FAIL** | CRITICAL/WARNING issues → run marked failed, task reset to open |
| **Merge tiers T1-T4** | T1/T2 = TypeScript auto-merge; T3/T4 = AI-assisted conflict resolution |

## Prerequisites

- **Node.js 20+**
- **PostgreSQL 15+** — required only when running the daemon (`foreman daemon start`); optional otherwise
  ```bash
  # macOS
  brew install postgresql@15
  # Linux
  sudo apt install postgresql-15
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

### Verification

```bash
foreman --version
foreman doctor              # Check installation and dependencies
```

## Quick Start

```bash
# 1. Initialize in your project
cd ~/your-project
foreman init --name my-project

# 2. Start the Foreman daemon (validates Postgres, starts tRPC)
foreman daemon start

# 3. Create or import tasks
foreman task create "Add user auth" --type feature --priority 1
foreman task create "Write auth tests" --type task --priority 2
# or migrate an existing beads project
foreman task import --from-beads

# 4. Dispatch agents to ready tasks
foreman run

# 5. Monitor progress
foreman status

# 6. Merge completed branches (runs automatically in foreman run loop)
foreman merge
```

> **Note:** The daemon is required for full multi-project orchestration. Without it, Foreman uses project-level PostgreSQL for single-project development.

## Messaging

Foreman includes a built-in messaging system for inter-agent communication and pipeline coordination. Messages are stored in **PostgreSQL** for standalone development or **PostgreSQL** (via ForemanDaemon) for multi-project aggregation.

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
Use `--wizard` for interactive setup that writes `.foreman/config.yaml` with VCS, workflow, and issue-tracker settings.

```bash
foreman init --name "my-project"
foreman init --wizard
```

### `foreman run`
Dispatch AI coding agents to ready tasks. Enters a watch loop that auto-merges completed branches.

```bash
foreman run                              # Dispatch to all ready tasks
foreman run --project my-project         # Dispatch without cd into a registered project
foreman run --task task-abc              # Dispatch one specific task
foreman run --max-agents 3               # Limit concurrent agents
foreman run --yes                        # Auto-confirm run prompts for non-interactive use
foreman run --model claude-opus-4-6      # Override model for all agents
foreman run --no-tests                   # Skip test suite in merge step
foreman run --dry-run                    # Preview without dispatching
```

Each agent gets:
- Its own git worktree (branch: `foreman/<task-id>`)
- A `TASK.md` with task instructions, phase prompts, and task context
- Native task status updates in PostgreSQL
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
Terminal UI kanban board for managing Foreman tasks. Five status columns with vim-style navigation. Press `y` to copy the selected task ID. The board monitors agent inbox messages and updates only task cards tied to changed runs; press `r` for a full manual reload with a `refreshing…` spinner and `refreshed <time>` confirmation.

```bash
foreman board                             # Launch interactive kanban board
foreman board --project my-project        # Board for a specific project
```

### `foreman watch`
Single-pane live dashboard: agents, board summary, inbox, and pipeline events. (`foreman dashboard` is a deprecated alias.)

```bash
foreman watch                             # Live unified dashboard
foreman watch --no-watch                  # One-shot snapshot, no polling
foreman watch --project <id>              # Filter to a specific project
foreman status --watch                    # Compact refreshing status view
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
foreman plan prd "Build a REST API"           # Server-backed PRD planning
foreman plan trd docs/PRD.md                   # Server-backed TRD planning
```

`plan prd` and `plan trd` send `plan.prd` / `plan.trd` commands to the local Elixir orchestration server and auto-start it by default.

### Migration and coexistence
Import a legacy TypeScript-era migration payload into the Elixir event store:

```bash
foreman import --to-elixir --file migration.json
foreman import --to-elixir --from-node --project foreman  # snapshot current Node/Postgres project into Elixir
```

The payload maps legacy projects, tasks, runs, workflows, inbox messages, and config into durable events/projections. While migration is incomplete, set `FOREMAN_LEGACY_COMPATIBILITY_MODE=1` and `FOREMAN_LEGACY_TS_BIN=/path/to/legacy/foreman` to delegate supported commands (`run`, `status`, `watch`, `reset`, `retry`, `stop`, `merge`, `pr`, `attach`, `inbox`, `task`, `plan`, `sling`, `doctor`) to the legacy TS CLI.

For Elixir cutover testing, set `FOREMAN_BACKEND=elixir` or `FOREMAN_MIGRATION_COMPLETE=true`. These modes disable legacy TS delegation and prevent `foreman daemon start|restart` from launching the Node scheduler, so one scheduler owns each project. Use `foreman server start` for the Elixir backend. Set `FOREMAN_BACKEND=node` only for explicit legacy operation. In Elixir cutover mode, commands that still lack Elixir parity fail before opening the legacy daemon socket with an explicit parity-gap message; `foreman board` reads and writes task state through Elixir after importing project state.

### `foreman sling trd`
Parse a TRD and create a native task hierarchy.

```bash
foreman sling trd docs/TRD.md           # Parse and create tasks
foreman sling trd docs/TRD.md --dry-run # Preview without creating
foreman sling trd docs/TRD.md --auto    # Skip confirmation
```

### `foreman daemon`
Manage the ForemanDaemon background process (Postgres-backed state).

```bash
foreman daemon start          # Start daemon in background (validates Postgres)
foreman daemon stop           # Stop running daemon
foreman daemon status         # Show PID, socket path, health
foreman daemon restart        # Stop + start
```

> Most legacy Node-backed commands (`foreman task`, `foreman status`, `foreman inbox`, etc.) require the daemon to be running. Start it once with `foreman daemon start`. During Elixir cutover (`FOREMAN_BACKEND=elixir` or `FOREMAN_MIGRATION_COMPLETE=true`), `foreman daemon start|restart` is blocked; use `foreman server start` instead.

### `foreman server`
Manage the experimental Elixir orchestration server.

```bash
foreman server doctor        # Auto-start and validate DB, projections, workers, VCS, providers, integrations
foreman server start         # Start local Elixir server
foreman server status        # Show PID/URL and health
foreman server stop          # Stop local Elixir server
```

`foreman server doctor` calls the server doctor endpoint and includes operational metrics: phase timers, retry/failure/recovery counters, worker restarts, and projection lag. If server auth is configured, set `FOREMAN_SERVER_AUTH_TOKEN` so doctor/metrics requests include the bearer token. Run debug views include anomaly detection for inconsistent event timelines. Troubleshoot Elixir-backed status issues by checking the durable event first, then projection lag/rebuild state, then recovery events (`ExternalWorkerObserved` before `WorkerReattached`, `WorkerRestarted`, or `NeedsOperator`).

Security controls for the Elixir server:
- Worker startup scopes environment to `FOREMAN_PROJECT_ID`, `FOREMAN_RUN_ID`, allowed base variables, and explicit project/run secret maps. Forbidden host secrets such as `FOREMAN_SERVER_AUTH_TOKEN`, `AWS_*`, `GITHUB_*`, `NPM_*`, `SSH_*`, and `DATABASE_*` are stripped before worker launch metadata is recorded.
- Binding the HTTP server beyond loopback requires `FOREMAN_SERVER_AUTH_TOKEN`; protected API calls must send `Authorization: Bearer <token>`.
- Destructive command-router actions such as `task.close`, `task.block`, and `task.update` append `AuthorizationChecked` and `AuditRecorded` events after the command executes.

### `foreman doctor`
Check environment health: Postgres connectivity, daemon status, br binary, Pi binary, GitHub auth.

```bash
foreman doctor
foreman doctor --fix                    # Auto-fix recoverable issues
```

### `foreman inbox`
View inter-agent messages from pipeline runs. Routes through ForemanDaemon.

```bash
foreman inbox                            # Latest run's messages
foreman inbox --task task-abc           # Messages for a specific task
foreman inbox --all                     # All runs
foreman inbox --all --watch             # Live stream across all runs
foreman inbox send --from qa --to developer --subject fix-needed  # Send a message (--run-id or FOREMAN_RUN_ID)
```

### `foreman worktree`
Manage git worktrees created for active tasks. Agent worktrees live under `~/.foreman/worktrees/<projectId>/...`; refinery merge integration worktrees live under `~/.foreman/integration/<projectId>/<targetBranch>` and are reset before each merge attempt.

```bash
foreman worktree list                    # List active worktrees
foreman worktree clean                   # Remove orphaned worktrees
foreman worktree clean --all             # Remove all including active ones
```

### `foreman sentinel`
QA sentinel for continuous testing on the main branch. Sentinel run history is stored in `sentinel_runs`, with start/pass/fail events recorded for observability.

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

## GitHub Integration

Foreman integrates with GitHub for bi-directional issue tracking, webhook-driven automation, pull request workflows, and release automation.

### Features

- **Bi-directional issue sync** — Push and pull GitHub issues as Foreman tasks via `foreman issue sync`
- **Real-time webhooks** — Issue and pull request events stream to ForemanDaemon via `POST /webhook`
- **Auto-import rules** — Issues with `foreman` or `foreman:dispatch` label can be imported directly into Foreman
- **Priority mapping** — `foreman:priority:0-4` labels map GitHub issues onto Foreman task priorities
- **PR visibility** — Pull request events and merge outcomes are recorded alongside task and run state
- **Release automation** — Conventional commits and GitHub Actions drive release tagging and binary publishing

### Label Conventions

GitHub labels drive Foreman behavior:

| Label | Effect |
|---|---|
| `foreman` | Mark issue for Foreman-aware handling and import |
| `foreman:dispatch` | Import as `ready` status — immediately dispatchable |
| `foreman:skip` | Skip webhook auto-import |
| `foreman:priority:0` | P0 — critical (priority 0) |
| `foreman:priority:1` | P1 — high priority |
| `foreman:priority:2` | P2 — medium (default) |
| `foreman:priority:3` | P3 — low priority |
| `foreman:priority:4` | P4 — backlog |
| `github:{name}` | Mirrored from GitHub; `{name}` is the original GitHub label |

### CLI Commands

```bash
# View and manage GitHub configuration
foreman issue configure                          # Configure repo sync + credentials
foreman issue labels <repo>                     # List available labels
foreman issue milestones <repo>                 # List milestones

# Sync issues
foreman issue import <repo>                     # Import all open issues
foreman issue import <repo> --milestone "v1.0" # Filter by milestone
foreman issue import <repo> --labels "bug,enhancement"
foreman issue import <repo> --dry-run           # Preview without creating
foreman issue sync <repo>                       # Bi-directional sync
foreman issue sync <repo> --create              # Create missing issues on GitHub

# Webhook management
foreman issue webhook --enable <repo>           # Enable webhook + generate secret
foreman issue webhook --disable <repo>          # Disable webhook
foreman issue webhook --status <repo>           # Show webhook status

# Status and linking
foreman issue status <repo>                     # Show linked issue status
foreman issue link <repo>#<number>              # Link task to GitHub issue
foreman issue view <repo>#<number>              # View single issue details
```

### Webhooks

Foreman includes a built-in webhook handler (`src/daemon/webhook-handler.ts`) that receives GitHub events and routes them through ForemanDaemon.

Webhooks use **HMAC-SHA256** signature verification. The daemon rejects payloads with invalid signatures:

```bash
export FOREMAN_WEBHOOK_SECRET=<your-secret>     # Set in daemon environment
```

The webhook secret is auto-generated when enabling via `foreman issue webhook --enable` and stored in the `github_repos` table.

#### Webhook event handling

| Event | Action |
|---|---|
| `issues.opened` | Create Foreman task from issue (body → description, labels → task labels) |
| `issues.closed` | Close Foreman task; record sync event |
| `issues.reopened` | Reopen Foreman task |
| `issues.labeled` | Add `github:{label}` to task labels |
| `issues.unlabeled` | Remove `github:{label}` from task labels |
| `pull_request.closed` + merged | Record merge metadata against the task/run |
| `push` | Record sync activity and support active branch/worktree reconciliation |

### Pull Requests and Branches

Foreman worktrees and GitHub issues are linked through Foreman-managed task and run metadata.

- Pull request activity is tracked per run, not just by branch name
- Merged PR state must match the current branch head before a task is treated as merged
- Historical PRs for older branch heads should not be treated as proof that the current run landed

Commit messages can append `Fixes #{issue_number}` so merging a PR closes the linked GitHub issue when appropriate.

### GitHub Actions and Releases

Foreman can trigger and be triggered by GitHub Actions workflows:

```yaml
# .github/workflows/foreman-trigger.yml
name: Trigger Foreman Task

on:
  pull_request:
    types: [opened, synchronize]

jobs:
  foreman-task:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Create Foreman task from PR
        run: |
          foreman task create "Review PR: ${{ github.event.pull_request.title }}" \
            --type task \
            --priority 1 \
            --labels "pr-review,github-automation"
```

Foreman can also post pipeline status back to GitHub checks:

```bash
export GITHUB_TOKEN=ghp_...        # GitHub personal access token
export GITHUB_REPOSITORY=owner/repo

# Foreman can post:
# - checkrun status for pipeline phases
# - final commit status after merge
```

For release tagging and version bumps, use conventional commits and the release workflows described in [Semantic Versioning & Conventional Commits](#semantic-versioning--conventional-commits).

## Task Tracking

Foreman supports one runtime task store: **native tasks** backed by PostgreSQL (via the daemon or direct standalone access).

### Native tasks

Tasks are created, tracked, and closed entirely within Foreman through tRPC procedures (when daemon is running) or directly via PostgreSQL.

```bash
# Native task lifecycle
foreman task create "Implement feature X" --type feature --priority 1
foreman task list
foreman task approve task-123
foreman task update task-123 --status in-progress
foreman task update task-123 --status review     # branch/PR is awaiting review or merge
foreman task close task-123
foreman task dep add task-tests task-feature   # tests depend on feature
foreman task dep list task-123                 # show dependencies
```

All task operations route through `TrpcClient` → daemon's Postgres store when daemon is running; otherwise they use direct PostgreSQL access via ForemanStore. Native status `review` means the pipeline has finished and the branch/PR is waiting for review or merge; phase status `reviewer` is reserved for an actively running reviewer agent.

For projects with existing [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`) data, import it once into native tasks:

```bash
foreman task import --from-beads
```

`FOREMAN_TASK_STORE=native` is accepted for backward compatibility but has no operational effect — the native Postgres task store is always used.

Priority scale: 0 (critical) → 1 (high) → 2 (medium) → 3 (low) → 4 (backlog).

## Configuration

### Workflow YAML

Foreman pipelines are configured via workflow YAML files. See the **[Workflow YAML Reference](docs/workflow-yaml-reference.md)** for complete documentation with examples for Node.js, .NET, Go, Python, and Rust.

Workflows define:
- **Setup steps** — dependency installation, build commands (stack-agnostic)
- **Setup cache** — symlink dependency directories from a shared cache
- **Phase sequence** — which agents run in what order
- **Model selection** — per-phase models with priority-based overrides
- **Retry loops** — QA/Reviewer/PR-review failure → Developer retry with feedback
- **PR gates** — create-pr, pr-wait, prepare-pr-review, pr-review, and merge phases for review-aware workflows; PR readiness must remain stable briefly and merge re-waits on late pending checks
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
    maxTurns: 50
  - name: qa
    prompt: qa.md
    verdict: true
    retryWith: developer
    retryOnFail: 2
```

Direct task execution is available for recovery/debug flows and bypasses scheduler state gates while preserving run/worktree locks:

```bash
foreman run task <task-id> <workflow-path> --project <name> --no-watch
```

**Key behaviors:**

- **Bypasses state gating** — runs regardless of task status (ready, backlog, closed, failed, etc.)
- **Preserves safety mechanisms** — worktree and run locking still apply
- **Explicit workflow** — specify the workflow as a positional argument (e.g., `task`, `quick`, `~/.foreman/workflows/custom.yaml`)

**When to use:**
- Re-running a completed/closed task with a different workflow
- Testing a new workflow configuration on an existing task
- Debugging with specific phases or models
- Recovery scenarios where normal dispatch isn't available

**Example:**

```bash
# Run a closed task with the task workflow
foreman run task foreman-12345 task --project my-project --no-watch

# Run with a custom workflow path
foreman run task foreman-12345 ~/.foreman/workflows/debug.yaml --target-branch main

# Dry run to preview
foreman run task foreman-12345 task --dry-run
```

The bundled `epic` workflow uses the same post-finalize PR gates as task/feature workflows (`create-pr → pr-wait → prepare-pr-review → pr-review → merge`) so epic PRs wait for CI/review instead of being created by finalize fallback logic.

### Environment variables

```bash
export ANTHROPIC_API_KEY=sk-ant-...          # Required (or use `pi /login` for OAuth)
export FOREMAN_MAX_AGENTS=5                  # Max concurrent agents (default: 5)
export FOREMAN_MAX_PIPELINE_WALL_CLOCK_MS=0  # Per-run wall-clock budget; 0 disables
export FOREMAN_MAX_PIPELINE_COST_USD=0       # Per-run cost budget; 0 disables
export FOREMAN_MAX_PIPELINE_TOOL_CALLS=0     # Per-run tool-call budget; 0 disables
export FOREMAN_MAX_PIPELINE_REVIEW_LOOPS=0   # Per-run retry/review loop budget; 0 disables
```

### Storage locations

| Path | Contents |
|---|---|
| `.foreman/` | Project-level config, workflow assets, and runtime metadata |
| `.beads/` | Legacy beads_rust task data for one-time import (JSONL, git-tracked) |
| `~/.foreman/daemon.sock` | ForemanDaemon Unix socket (tRPC over HTTP) — optional |
| `~/.foreman/daemon.pid` | Daemon process ID — optional |
| `~/.foreman/logs/` | Per-run agent logs + daemon stdout/stderr |
| `DATABASE_URL` | PostgreSQL connection string — only required when running daemon |

**Storage model:** Foreman stores application state in PostgreSQL through the daemon/tRPC layer or direct standalone access. Native PostgreSQL tasks are the only supported runtime task store; beads_rust data is import-only legacy input.

## Project Structure

```
foreman/
├── src/
│   ├── cli/                        # CLI entry point + commands
│   │   └── commands/
│   │       ├── run.ts              # Main dispatch + merge loop
│   │       ├── status.ts           # Status display
│   │       ├── merge.ts            # Manual merge trigger
│   │       ├── daemon.ts           # Daemon lifecycle management
│   │       └── doctor.ts           # Health checks
│   ├── daemon/                     # ForemanDaemon (optional background process)
│   │   ├── index.ts                # Entry point: PoolManager, Fastify, socket
│   │   ├── router.ts               # tRPC procedures (projects, tasks, runs, mail)
│   │   └── webhook-handler.ts      # GitHub webhook receiver
│   ├── orchestrator/               # Core orchestration engine
│   │   ├── dispatcher.ts           # Task → agent spawning strategies
│   │   ├── pi-rpc-spawn-strategy.ts  # Pi RPC spawn (primary)
│   │   ├── agent-worker.ts         # Claude SDK pipeline (fallback)
│   │   ├── refinery.ts             # Merge + test + cleanup
│   │   ├── conflict-resolver.ts     # T1-T4 conflict resolution
│   │   ├── roles.ts                # Phase prompts + tool configs
│   │   └── sentinel.ts             # Background health monitor
│   └── lib/
│       ├── daemon-manager.ts       # Daemon PID/socket lifecycle
│       ├── trpc-client.ts           # Unix socket → daemon tRPC transport
│       ├── db/
│       │   ├── pool-manager.ts     # Postgres pool singleton (daemon only)
│       │   └── postgres-adapter.ts # Postgres DB operations (daemon only)
│       ├── store.ts                # Project-level PostgreSQL store (default)
│       ├── postgres-store.ts       # Postgres-backed store (daemon mode)
│       ├── beads-rust.ts           # Compatibility br CLI wrapper
│       └── git.ts                  # Git worktree management
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

> **Note:** Standalone binaries bundle the daemon. Make sure PostgreSQL is available on the target system.

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
  darwin-x64/
    foreman-darwin-x64        # macOS Intel
  linux-x64/
    foreman-linux-x64         # Linux x86-64
  linux-arm64/
    foreman-linux-arm64       # Linux ARM64 (e.g. AWS Graviton)
  win-x64/
    foreman-win-x64.exe       # Windows x64
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
