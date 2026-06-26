---
name: foreman
description: "Multi-agent coding orchestrator. Use when: (1) user wants to plan and build features from a description, (2) user wants Elixir-scheduled AI coding agents on a codebase, (3) user asks about Foreman project status or agent progress, (4) user says 'foreman plan/task/server/runs/watch/status/retry/recover'. Legacy sling/run/merge need FOREMAN_BACKEND=node."
metadata:
  openclaw:
    emoji: "👷"
    requires:
      anyBins: ["claude"]
---

# Foreman — Multi-Agent Coding Orchestrator

Foreman decomposes development work into parallelizable Elixir-backed tasks, dispatches them to AI coding agents (Claude Code, Pi, Codex), manages git isolation per agent, and records run/status/inbox projections for real-time CLI/MCP monitoring.

## When to Use

- User asks to build/implement something from a product description, PRD, or TRD
- User wants to run multiple AI agents on a codebase in parallel
- User asks about agent progress, stuck agents, or project status
- User says anything like "foreman plan/task/server/runs/watch/status/retry/recover"

## Prerequisites

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
foreman plan prd/trd → Elixir planning       → PRD/TRD artifacts
foreman task create  → Elixir task mgmt      → Create/update/list tasks
foreman server start → Elixir scheduler      → Dispatch ready tasks
foreman runs/watch   → Elixir projections    → Run/activity monitoring
foreman retry/recover→ Elixir recovery       → Rerun/recover failed work
foreman status       → Summary view          → Task counts + agent status
FOREMAN_BACKEND=node foreman run/merge/sling → Legacy Node-only paths
```

## Command Reference

### 1. Initialize a Project

```bash
cd <project-dir>
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts init --name "my-project"
```

Registers the project in the default Elixir project registry/projections.

### 2. Plan (Elixir-backed PRD/TRD)

```bash
# Generate planning artifacts through Elixir-backed planning commands
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts plan prd "Build a user authentication system with OAuth2 support"
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts plan trd docs/PRD.md
```

Default Elixir mode records planning/task state through Elixir events/projections. Legacy `foreman plan <description>` / `foreman sling trd` / `foreman run` dispatcher flows require `FOREMAN_BACKEND=node`.

### 3. Create/approve tasks

```bash
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task create \
  --title "Implement user authentication" \
  --description "Add OAuth2 login flow with Google and GitHub" \
  --type task \
  --priority 2
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task approve <task-id>
```

### 4. Dispatch (Elixir scheduler)

```bash
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts server start
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts runs
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts watch
```

For each claimed task, the Elixir scheduler creates a run projection, launches the Node/Pi worker bridge, and records worker lifecycle events.

### 5. Monitor

### 6. Inbox

```bash
# View messages for latest run
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts inbox

# Filter by agent role
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts inbox --agent explorer

# Filter by run ID
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts inbox --run <run-id>

# Filter by task ID
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts inbox --task foreman-001

# Watch mode (live updates)
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts inbox --watch

# Show only unread messages
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts inbox --unread

# Watch all runs across the project
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts inbox --all --watch

# Mark messages as read
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts inbox --ack
```

The inbox shows inter-agent messages within pipeline runs — communications between explorer, developer, reviewer, and foreman agents.

### 7. Mail (Send Inter-Agent Messages)

```bash
# Send a message between agents within a run
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts mail send \
  --run-id <run-id> \
  --from explorer \
  --to developer \
  --subject phase-complete \
  --body '{"phase":"exploration"}'
```

Agent roles: `explorer`, `developer`, `reviewer`, `qa`, `foreman`

Subjects: `phase-started`, `phase-complete`, `agent-error`, `blocker-detected`, `handoff`

**Tip**: Set `FOREMAN_RUN_ID` env var to avoid passing `--run-id` on every call.

### 8. Merge / PR handling

Default Elixir workflows handle PR/merge state through workflow phases and events. The manual Refinery merge command is legacy-only:

```bash
FOREMAN_BACKEND=node npx tsx ~/Development/Fortium/foreman/src/cli/index.ts merge
```

### 9. Task Management

Foreman ships an Elixir event/projection-backed task store.

#### Create a task

```bash
# Create a task in backlog status
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task create \
  --title "Implement user authentication" \
  --description "Add OAuth2 login flow with Google and GitHub" \
  --type task \
  --priority 2

# Shortcuts for priority
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task create --title "Quick fix" --priority 1
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task create --title "Critical issue" --priority 0
```

Valid types: `task`, `bug`, `feature`, `epic`, `chore`, `docs`, `question`
Valid priorities: `0` (critical), `1` (high), `2` (medium), `3` (low), `4` (backlog)

#### List tasks

```bash
# List active tasks (excludes closed/merged by default)
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task list

# Include closed tasks
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task list --all

# Filter by status or type
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task list --status ready
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task list --type bug
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task list --status backlog --type feature
```

#### Show, approve, update, close

```bash
# View task details
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task show <task-id>

# Approve a backlog task → makes it ready for dispatch
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task approve <task-id>

# Update fields
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task update <task-id> \
  --title "New title" \
  --priority high \
  --status in-progress

# Force a backward status transition (e.g. merged → backlog)
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task update <task-id> --status backlog --force

# Close a task (marks as merged)
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task close <task-id>
```

#### Manage dependencies

```bash
# Task A blocks Task B
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task dep add <task-a> <task-b> --type blocks

# Parent-child relationship
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task dep add <epic-id> <child-id> --type parent-child

# List dependencies for a task
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task dep list <task-id>

# Remove a dependency
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task dep remove <task-a> <task-b>
```

#### Import from beads_rust

```bash
# Dry-run: preview first 5 mappings without writing
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task import --from-beads --dry-run

# Perform the import
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts task import --from-beads
```

Import reads `.beads/beads.jsonl` and maps bead status to native status:

- `open` → `backlog`
- `in_progress` → `ready`
- `closed` → `merged`

Tasks with `external_id` already matching a bead ID are skipped as duplicates.

#### Native tasks vs beads_rust

| Aspect | Native tasks (`foreman task`) | Beads (`br`/`bd`) |
|--------|------------------------------|-------------------|
| Storage | Elixir events/projections | `.beads/beads.jsonl` |
| Dispatch | ✅ Used by Elixir scheduler (`foreman server start`) | ❌ |
| Dashboard | ✅ Shown in board/status/runs/watch | ❌ |
| CLI | `foreman task *` | `br`/`bd` |
| Portability | Single DB per machine | Git-tracked JSONL |

Both stores can coexist. Use `foreman task import --from-beads` to migrate bead tasks to the Elixir task store for dispatch.

### 10. Monitoring

```bash
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts runs
npx tsx ~/Development/Fortium/foreman/src/cli/index.ts watch
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
2. Jarvis: Run foreman plan prd/trd with the description → generates PRD/TRD
3. Jarvis: Create/approve Elixir tasks with foreman task/project commands
4. Jarvis: Ensure foreman server start; Elixir scheduler dispatches ready tasks
5. Jarvis: Periodically run foreman runs/watch/status to check progress
6. Jarvis: Use foreman retry/recover for failed/stuck work
7. Jarvis: Report results to user
```

## Important Notes

- Always run `foreman init` in the target project first
- Max 5 concurrent agents by default (configurable)
- Each agent gets its own git worktree — no conflicts
- Agents report completion through Elixir run/task events
- TRDs from planning should become Elixir tasks via `foreman task`/planning flows; legacy `foreman sling trd` requires `FOREMAN_BACKEND=node`
- `foreman runs`, `foreman watch`, and `foreman status --live` show projects and agents in real time
