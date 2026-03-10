# Foreman

Multi-agent coding orchestrator built on OpenClaw + Beads.

> The foreman doesn't write the code — they manage the crew that does.

## Quick Start

```bash
foreman init                    # Initialize in a project
foreman plan <prd.md>           # Decompose PRD → beads
foreman run                     # Dispatch agents to ready tasks
foreman status                  # Show progress
foreman merge                   # Trigger merge for completed work
foreman dashboard               # Launch monitoring UI
```

## Architecture

- **Orchestration:** OpenClaw (sessions_spawn, ACP harness)
- **Work Tracking:** Beads (git-backed, dependency-aware)
- **Git Isolation:** Worktrees per agent
- **Dashboard:** Real-time web UI (Svelte + Node)
- **State:** SQLite (~/.foreman/foreman.db)

## Documentation

See the [PRD](docs/PRD.md) for full specification.

