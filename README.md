# Foreman 👷

> The foreman doesn't write the code — they manage the crew that does.

Multi-agent coding orchestrator built on [OpenClaw](https://github.com/openclaw/openclaw) + [Beads](https://github.com/steveyegge/beads). Decomposes development work into parallelizable tasks, dispatches them to AI coding agents, manages git isolation per agent, and merges results back — all monitored through a real-time web dashboard.

## Why Foreman?

You already have AI coding agents (Claude Code, Pi, Codex). What you don't have is a way to run 5-10 of them simultaneously on the same codebase without them stepping on each other. Foreman solves this:

- **Work decomposition** — PRD → TRD → beads (structured, dependency-aware tasks)
- **Git isolation** — each agent gets its own worktree (zero conflicts)
- **Model selection** — Opus for complex refactors, Sonnet for features, Haiku for config tweaks
- **Progress tracking** — every task, agent, and cost tracked in SQLite + Beads
- **Merge management** — automated merge, test, and cleanup when agents finish
- **Real-time dashboard** — see all projects and agents at a glance
- **OpenTelemetry** — native OTEL tracing for LangSmith, Grafana, Datadog, etc.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Foreman Dashboard                   │
│               (localhost:3850 — web UI)               │
│  Projects Overview │ Project Detail │ Metrics         │
└────────────────────┬────────────────────────────────┘
                     │ REST API / WebSocket
┌────────────────────┴────────────────────────────────┐
│              Foreman Orchestrator                     │
│                                                      │
│  Plan         Decompose      Dispatch      Refinery  │
│  (Ensemble    (TRD → Beads   (Beads →      (Merge +  │
│   PRD→TRD)    hierarchy)     Agents)       Test)     │
└────────────────────┬────────────────────────────────┘
        ┌────────────┼────────────┐
   ┌────┴────┐ ┌────┴────┐ ┌────┴────┐
   │ Opus    │ │ Sonnet  │ │ Haiku   │
   │(complex)│ │(default)│ │ (light) │
   │worktree/│ │worktree/│ │worktree/│
   │bd-a1b2  │ │bd-c3d4  │ │bd-e5f6  │
   └─────────┘ └─────────┘ └─────────┘
         ↓ OpenTelemetry (optional)
   ┌─────────────────────────────┐
   │ LangSmith / Grafana / etc. │
   └─────────────────────────────┘
```

## Prerequisites

- [Beads CLI](https://github.com/steveyegge/beads): `brew install beads`
- [Dolt](https://github.com/dolthub/dolt): `brew install dolt`
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code): `brew install claude-code`
- Node.js 20+

## Quick Start

```bash
# Clone
git clone <your-repo-url> ~/Development/Fortium/foreman
cd ~/Development/Fortium/foreman
npm install

# Initialize in your project
cd ~/your-project
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts init --name my-project
```

## Pipeline

The full Foreman pipeline:

```
foreman plan "Build auth system"     # Ensemble: description → PRD → TRD
foreman sling trd docs/TRD.md       # TRD → beads task hierarchy
foreman run                          # Dispatch agents to ready tasks
foreman monitor                      # Check progress, recover stuck agents
foreman merge                        # Merge completed branches + run tests
foreman dashboard                    # Real-time web UI on :3850
```

## Commands

### `foreman init`
Initialize Foreman in a project. Runs `bd init` and registers in the store.

```bash
foreman init --name "my-project"
```

### `foreman plan`
Run the Ensemble PRD → TRD pipeline. Each step is tracked as a bead with sequential dependencies.

```bash
foreman plan "Build a user auth system with OAuth2"
foreman plan docs/description.md              # From file
foreman plan --from-prd docs/PRD.md "unused"  # Skip to TRD
foreman plan --prd-only "Build a REST API"    # Stop after PRD
foreman plan --dry-run "Preview the pipeline"
```

Pipeline steps:
1. `/ensemble:create-prd` — Product analysis, requirements definition
2. `/ensemble:refine-prd` — Strengthen acceptance criteria, edge cases
3. `/ensemble:create-trd` — Technical architecture, task breakdown
4. `/ensemble:refine-trd` — Validate decisions, refine estimates

### `foreman sling trd`
Sling a structured TRD into a dual-tracked task hierarchy (seeds + beads).

```bash
foreman sling trd docs/TRD.md           # Parse and create tasks
foreman sling trd docs/TRD.md --dry-run # Preview without creating
foreman sling trd docs/TRD.md --auto    # Skip confirmation
```

### `foreman run`
Dispatch AI coding agents to ready tasks.

```bash
foreman run                              # Dispatch to all ready tasks
foreman run --max-agents 3               # Limit concurrent agents
foreman run --model claude-opus-4-6      # Force all agents to use Opus
foreman run --dry-run                    # Preview without dispatching
foreman run --no-watch                   # Exit immediately after dispatch
foreman run --telemetry                  # Enable OpenTelemetry tracing
foreman run --ralph                      # Ralph Wiggum loop (serial task processing)
```

Each agent gets:
- Its own git worktree (branch: `foreman/<bead-id>`)
- An AGENTS.md with task instructions
- Beads CLI for status updates
- Shared `.beads/` database (symlinked from main repo)

After dispatching, Foreman enters **watch mode** — polling agent status every 5 seconds with a live-updating display. Ctrl+C detaches without killing agents. Use `--no-watch` to skip.

### `foreman monitor`
Check agent progress and detect stuck agents.

```bash
foreman monitor                 # Show status
foreman monitor --recover       # Auto-recover stuck agents
foreman monitor --timeout 20    # Stuck after 20 minutes
```

### `foreman merge`
Merge completed work branches back to main.

```bash
foreman merge                           # Merge all completed
foreman merge --target-branch develop    # Merge to develop
foreman merge --no-tests                 # Skip test suite
foreman merge --test-command "npm test"  # Custom test command
```

### `foreman status`
Show project status: tasks, agents, costs.

```bash
foreman status
```

### `foreman dashboard`
Launch the real-time web dashboard.

```bash
foreman dashboard              # Opens http://localhost:3850
foreman dashboard --no-open    # Don't auto-open browser
```

Three views:
- **Projects Overview** — all projects with progress bars, agent counts, costs
- **Project Detail** — task graph, agent activity, merge queue, event log
- **Metrics** — cost breakdown by runtime, task stats, token trends

## Model Selection

All agents run via Claude Code. The model is automatically selected based on task complexity:

| Model | Best For | Auto-selected when title/description contains |
|-------|----------|-----------------------------------------------|
| **claude-opus-4-6** | Complex refactoring, architecture, migrations | `refactor`, `architect`, `design`, `complex`, `migrate`, `overhaul` |
| **claude-sonnet-4-6** | Default for features, tests, fixes, implementation | Everything else |
| **claude-haiku-4-5** | Config tweaks, typos, version bumps, README updates | `typo`, `rename`, `config`, `bump version`, `update readme` |

Override for all agents with `--model`:
```bash
foreman run --model claude-opus-4-6    # Force Opus for everything
```

## Observability (OpenTelemetry)

Foreman leverages Claude Code's native OpenTelemetry support to export per-agent traces, token usage, and cost data to any OTEL-compatible backend.

### Setup

1. Configure your OTEL collector endpoint:

```bash
# LangSmith
export OTEL_EXPORTER_OTLP_ENDPOINT=https://api.smith.langchain.com/otel
export OTEL_EXPORTER_OTLP_HEADERS="x-api-key=your-langsmith-key"
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf

# Or Grafana Cloud, Datadog, SigNoz, etc.
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
```

2. Run with telemetry enabled:

```bash
foreman run --telemetry
```

### What gets exported

Each spawned agent emits:

**Events** (via OTEL logs):
- `claude_code.api_request` — every LLM call (model, cost, duration, tokens)
- `claude_code.tool_result` — tool executions (name, success, duration)
- `claude_code.user_prompt` — prompt submissions

**Metrics**:
- `claude_code.cost.usage` — session cost in USD
- `claude_code.token.usage` — tokens by type (input, output, cache)
- `claude_code.active_time.total` — active session time

**Resource attributes** (for filtering/grouping):
- `foreman.bead_id` — the task being worked on
- `foreman.run_id` — the foreman run ID
- `foreman.model` — the Claude model used

## Configuration

Global config at `~/.foreman/`:
- `foreman.db` — SQLite state store (projects, runs, costs, events)

Per-project:
- `.beads/` — Beads workspace (Dolt-backed task tracking)
- `.foreman-worktrees/` — Git worktrees for active agents

## Project Structure

```
foreman/
├── src/
│   ├── cli/                    # CLI entry point + 8 commands
│   │   ├── index.ts
│   │   └── commands/
│   ├── orchestrator/           # Core orchestration engine
│   │   ├── dispatcher.ts      # Task → agent spawning
│   │   ├── monitor.ts         # Progress tracking + recovery
│   │   ├── refinery.ts        # Merge + test + cleanup
│   │   ├── trd-parser.ts      # Structured TRD table parser
│   │   ├── sling-executor.ts  # TRD plan → seeds + beads dual-write
│   │   └── templates.ts       # Agent instruction generation
│   ├── dashboard/              # Web UI
│   │   ├── server.ts          # Hono REST API + static serving
│   │   ├── ws.ts              # WebSocket event broadcasting
│   │   └── public/index.html  # Single-file dashboard (dark theme)
│   └── lib/                    # Shared libraries
│       ├── beads.ts           # Beads CLI wrapper
│       ├── git.ts             # Git worktree management
│       └── store.ts           # SQLite state store
├── skills/foreman/SKILL.md     # OpenClaw skill definition
├── templates/                  # Agent instruction templates
│   ├── worker-agent.md
│   └── refinery-agent.md
└── docs/
    ├── PRD.md                 # Full product requirements
    └── sample-prd.md          # Example PRD for testing
```

## Integration

### With OpenClaw
Foreman includes an OpenClaw skill at `skills/foreman/SKILL.md`. Install it to let your OpenClaw agent (Jarvis) orchestrate Foreman naturally:

> "Build the auth module from this PRD"  
> "How are the Foreman agents doing?"  
> "Merge the completed work"

### With Ensemble
The `plan` command integrates directly with [Ensemble](https://github.com/Fortium/ensemble) slash commands for structured PRD → TRD generation.

## License

MIT

---

Built by [Leo D'Angelo](https://www.linkedin.com/in/leo-d-angelo-5a0a83) at [Fortium Partners](https://fortiumpartners.com).
