# Overstory vs Foreman — Feature Comparison

## Overview

**Overstory** (`ov` CLI, `@os-eco/overstory-cli`) is a multi-agent orchestration tool by the same author as seeds. It spawns worker agents in isolated git worktrees via tmux, coordinates them through a SQLite mail system, and merges results with tiered conflict resolution. It supports 8 runtimes (Claude, Pi, Gemini, Copilot, Codex, Cursor, Sapling, OpenCode) and is part of the os-eco ecosystem (overstory, seeds, mulch, canopy, sapling).

**Foreman** is our AI-powered engineering orchestrator that decomposes work into tasks, dispatches them to Claude agents in isolated git worktrees, and merges results back. Built with TypeScript, Claude Agent SDK, and seeds (sd) for task tracking.

## Feature Gap Analysis

| Feature | Overstory | Foreman | Gap |
|---|---|---|---|
| **Agent isolation** | Git worktrees + tmux | Git worktrees + detached processes | Minor |
| **Pipeline phases** | Role-based (9 roles) | TypeScript-orchestrated (4 phases) | Different approach, foreman's is fine |
| **Task tracking** | Seeds/beads (pluggable) | Seeds (migrated) | Parity |
| **Inter-agent messaging** | SQLite mail system | Report files only | **Gap** |
| **Merge system** | FIFO queue + 4-tier conflict resolution | Basic merge + theirs strategy | **Gap** |
| **Health monitoring** | 3-tier watchdog + `ov doctor` | Basic monitor + stuck detection | **Gap** |
| **Observability** | dashboard, inspect, trace, replay, feed, logs, costs | status + monitor only | **Major gap** |
| **Multi-runtime support** | 8 runtimes (Claude, Pi, Gemini, etc.) | Claude SDK only | **Gap** |
| **Gateway/provider routing** | Per-agent model routing | Basic model selection | **Gap** |
| **Expertise management** | Mulch integration | None | **Gap** |
| **Tool enforcement** | Runtime-specific guards | None (relies on prompts) | **Gap** |
| **Checkpoint/restore** | Save/restore for crash recovery | Auto-reset to open only | **Gap** |
| **Task groups** | Batch coordination with auto-close | None | **Gap** |

## Overstory Feature Details

### Agent Hierarchy
```
Orchestrator (multi-repo coordinator of coordinators)
  --> Coordinator (persistent orchestrator at project root)
        --> Supervisor / Lead (team lead, depth 1)
              --> Workers: Scout, Builder, Reviewer, Merger (depth 2)
```

### 9 Agent Roles with Access Controls
- **Orchestrator**: Multi-repo coordinator (read-only)
- **Coordinator**: Persistent orchestrator, task decomposition (read-only)
- **Supervisor** [DEPRECATED]: Per-project team lead (read-only)
- **Scout**: Read-only exploration/research
- **Builder**: Implementation (read-write)
- **Reviewer**: Validation/code review (read-only)
- **Lead**: Team coordination, can spawn sub-workers (read-write)
- **Merger**: Branch merge specialist (read-write)
- **Monitor**: Tier 2 continuous fleet patrol (read-only)

### Inter-Agent Messaging
- SQLite mail system (WAL mode, ~1-5ms per query)
- 8 typed protocol message types: `worker_done`, `merge_ready`, `dispatch`, `escalation`, etc.
- Broadcast messaging with group addresses (`@all`, `@builders`, etc.)
- Thread support, priority levels (low/normal/high/urgent), nudge mechanism

### Merge System
- FIFO merge queue (SQLite-backed)
- 4-tier conflict resolution: textual auto-merge -> AI resolver -> structured human review -> manual fallback

### Observability (9 commands)
- `ov status` — fleet overview
- `ov dashboard` — live TUI dashboard
- `ov inspect` — deep per-agent inspection with `--follow`
- `ov trace` — agent/task timeline
- `ov errors` — aggregated error view
- `ov replay` — interleaved chronological replay
- `ov feed` — real-time event stream
- `ov logs` — NDJSON log query across agents
- `ov costs` — token/cost analysis with per-agent, per-capability, per-run breakdowns

### Health Monitoring (Tiered Watchdog)
- **Tier 0**: Mechanical daemon (tmux/pid liveness checks)
- **Tier 1**: AI-assisted failure triage
- **Tier 2**: Monitor agent for continuous fleet patrol
- `ov doctor` — 11 health check categories with `--fix` auto-repair

### Tool Enforcement
- Runtime-specific guards mechanically block file modifications for non-implementation agents
- Claude Code uses `settings.local.json` hooks
- Dangerous git operations blocked for all agents

### os-eco Ecosystem
| Tool | CLI | Purpose |
|------|-----|---------|
| **Mulch** | `ml` | Structured expertise management (JSONL) |
| **Seeds** | `sd` | Git-native issue tracking (JSONL) |
| **Canopy** | `cn` | Version-controlled prompt management |
| **Sapling** | `sp` | Headless coding agent (pluggable LLM) |
| **Overstory** | `ov` | Multi-agent orchestration |

## Seed Tasks Created

### P1 — High Impact
| ID | Feature | Rationale |
|---|---|---|
| `foreman-8efb` | Doctor command with auto-fix | Already hit stale worktrees, orphaned branches, env var leaks — automates cleanup |
| `foreman-56aa` | Tool enforcement guards | Explorer/reviewer rely on prompts to stay read-only — mechanical enforcement prevents violations |

### P2 — Medium Priority
| ID | Feature | Rationale |
|---|---|---|
| `foreman-cc6f` | Observability dashboard TUI | Biggest feature gap — overstory has 9 observability commands, foreman has 2 |
| `foreman-3527` | Inter-agent messaging (SQLite mail) | Report files are one-way; messaging enables real-time coordination and escalation |
| `foreman-ef3d` | 4-tier merge conflict resolution | Current merge is basic; AI-powered conflict resolution would catch more issues |
| `foreman-dc29` | Checkpoint save/restore | Pipeline failures lose all progress; checkpoints enable smart resume |
| `foreman-071f` | Per-phase cost breakdowns | Know which phases burn budget — haiku explorer vs sonnet developer |

### P3 — Future
| ID | Feature | Rationale |
|---|---|---|
| `foreman-9b4d` | Multi-runtime support | Pluggable runtimes (Pi, Gemini) for vendor diversification |
| `foreman-b98a` | Task groups for batch coordination | Auto-close epics when children complete |
| `foreman-3cf3` | Gateway provider routing | Custom API endpoints, per-phase routing |
