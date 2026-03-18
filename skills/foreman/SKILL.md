---
name: foreman
description: "Multi-agent coding orchestrator. Use when: (1) user wants to plan and build features from a description, (2) user wants to run multiple AI coding agents on a codebase, (3) user asks about Foreman project status or agent progress, (4) user says 'foreman plan/sling/run/status/merge/monitor/dashboard'."
metadata:
  openclaw:
    emoji: "👷"
    requires:
      anyBins: ["bd", "claude"]
---

# Foreman — Multi-Agent Coding Orchestrator

Foreman decomposes development work into parallelizable tasks (via Beads), dispatches them to AI coding agents (Claude Code, Pi, Codex), manages git isolation per agent, and merges results back — all monitored through a real-time web dashboard.

## When to Use

- User asks to build/implement something from a product description, PRD, or TRD
- User wants to run multiple AI agents on a codebase in parallel
- User asks about agent progress, stuck agents, or project status
- User says anything like "foreman plan/sling/run/status/merge"

## Prerequisites

- **Beads CLI** (`bd`): `brew install beads`
- **Dolt**: `brew install dolt` (required by Beads)
- **Claude Code**: For Ensemble pipeline and agent spawning
- **Node.js 20+**
- **Foreman project**: `~/Development/Fortium/foreman`

## CLI Location

All commands run via:
```bash
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts <command>
```

## Pipeline Overview

```
foreman plan        →  Ensemble pipeline  →  Product description → PRD → TRD
foreman sling trd   →  Structured parser  →  TRD → Seeds + Beads task hierarchy
foreman run         →  Agent dispatcher   →  Spawn agents on ready tasks
foreman monitor     →  Progress checker   →  Detect stuck/completed agents
foreman merge       →  Refinery           →  Merge completed branches + test
foreman status      →  Summary view       →  Task counts + agent status
foreman dashboard   →  Web UI             →  Real-time monitoring on :3850
```

## Command Reference

### 1. Initialize a Project

```bash
cd <project-dir>
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts init --name "my-project"
```

Runs `bd init` and registers the project in `~/.foreman/foreman.db`.

### 2. Plan (Ensemble PRD → TRD Pipeline)

```bash
# From a product description
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts plan "Build a user authentication system with OAuth2 support"

# From a description file
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts plan docs/product-description.md

# Skip to TRD from existing PRD
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts plan --from-prd docs/PRD.md "unused"

# PRD only (no TRD)
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts plan --prd-only "Build a REST API"

# Preview the pipeline steps
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts plan --dry-run "Build something"
```

Creates an **epic bead** with 4 child beads (sequential dependencies). Each step dispatches
through the dispatcher with full tracking in SQLite:
1. `/ensemble:create-prd` — Analyze description, define requirements
2. `/ensemble:refine-prd` — Strengthen acceptance criteria, edge cases
3. `/ensemble:create-trd` — Technical architecture, task breakdown, sprint planning
4. `/ensemble:refine-trd` — Validate decisions, refine estimates

The dispatch loop automatically waits for each step to complete before unblocking the next.
All steps visible in the dashboard alongside coding agents.

### 3. Sling TRD (TRD → Seeds + Beads)

```bash
# Sling a structured TRD into seeds + beads
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts sling trd docs/TRD.md

# Preview without creating tasks
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts sling trd docs/TRD.md --dry-run

# Skip confirmation
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts sling trd docs/TRD.md --auto
```

Parses a structured TRD (with table sections, explicit metadata) and dual-writes to both
seeds (`sd`) and beads_rust (`br`) with explicit dependencies.

### 4. Run (Dispatch Agents)

```bash
# Dispatch agents to all ready tasks
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts run

# Limit concurrent agents
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts run --max-agents 3

# Force a specific runtime
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts run --runtime pi

# Preview without dispatching
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts run --dry-run
```

For each ready bead:
1. Creates a git worktree at `.foreman-worktrees/<bead-id>`
2. Generates an AGENTS.md with task instructions
3. Records the run in SQLite
4. **TODO**: Spawns via OpenClaw `sessions_spawn`

**Manual dispatch via OpenClaw** (until spawn is wired up):
```
For each ready task from bd ready --json:
  sessions_spawn(
    runtime: "acp",
    task: "Read AGENTS.md and implement the task. Use br to track progress. When done: br close <bead-id> && git add . && git commit && git push",
    cwd: "<worktree-path>",
    mode: "run"
  )
```

### 5. Monitor

```bash
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts monitor
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts monitor --recover  # auto-recover stuck agents
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts monitor --timeout 20  # stuck after 20 min
```

### 6. Merge

```bash
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts merge
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts merge --target-branch develop
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts merge --no-tests
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts merge --test-command "npm run test:ci"
```

### 7. Dashboard

```bash
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts dashboard
# Opens http://localhost:3850
```

## Runtime Selection Guide

| Runtime | Best For | Model |
|---------|----------|-------|
| **pi** | Tests, docs, small fixes, simple CRUD, config | Fast, cheap |
| **claude-code** | Complex features, refactoring, architecture, multi-file | Thorough |
| **codex** | When OpenAI models preferred | Alternative |

The dispatcher auto-selects based on task keywords:
- `test`, `doc`, `fix`, `config` → pi
- `refactor`, `architect`, `design`, `complex` → claude-code
- Override with `--runtime` flag

## Integration with Jarvis

When orchestrating from the main OpenClaw session:

```
1. User: "Build the auth module from this description"
2. Jarvis: Run foreman plan with the description → generates PRD → TRD
3. Jarvis: Run foreman sling trd on the TRD → creates seeds + beads
4. Jarvis: Run foreman run (or manually spawn via sessions_spawn)
5. Jarvis: Periodically run foreman monitor to check progress
6. Jarvis: When tasks complete, run foreman merge
7. Jarvis: Report results to user
```

## Important Notes

- Always run `foreman init` in the target project first
- Max 5 concurrent agents by default (configurable)
- Each agent gets its own git worktree — no conflicts
- Agents must `bd close` their bead when done
- TRDs from Ensemble contain structured task breakdowns ready for `foreman sling trd`
- The dashboard at `:3850` shows all projects and agents in real-time
