> ⚠️ Historical Context
> This document describes Foreman's beads-first architecture, which has been
> superseded by native task management (TRD-2026-006). Some instructions,
> configurations, or comparisons in this document may no longer reflect
> current behavior.
> This migration guide is preserved for historical reference. See TRD-2026-006
> for current task management architecture.

# Tasks → beads_rust (br) Migration Guide

This document summarises the changes made in the `tasks-to-br-bv-migration` TRD. It covers
what changed, why, and how to update any existing integrations.

## Summary

Foreman has migrated from the `tasks` (`sd`) CLI to [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`) for task tracking, with optional [beads_viewer](https://github.com/Dicklesworthstone/beads_viewer) (`bv`) for graph-aware triage.

| Before | After |
|--------|-------|
| `sd` CLI (`~/.bun/bin/sd`) | `br` CLI (`~/.local/bin/br`) |
| `.tasks/issues.jsonl` | `.beads/beads.jsonl` |
| `TasksClient` | `BeadsRustClient` |
| `FOREMAN_TASK_BACKEND=sd\|br` | Hardcoded `br` — no env var |
| `pagerank.ts` | Deleted (replaced by `bv --robot-insights`) |

## Why

- `br` provides a richer query model (dependency graph, PageRank, betweenness) via `bv`
- `bv --robot-triage` gives deterministic, precomputed execution ordering
- The dual-backend feature flag added complexity with no active `sd` users
- `pagerank.ts` duplicated functionality that `bv` does better

## Command Mapping

| tasks (`sd`) | beads_rust (`br`) |
|--------------|-------------------|
| `sd ready` | `br ready` |
| `sd list --json` | `br list --status=open` |
| `sd show <id>` | `br show <id>` |
| `sd create --title X --type task --priority P2` | `br create --title X --type task --priority 2` |
| `sd update <id> --claim` | `br update <id> --status=in_progress` |
| `sd update <id> --status closed` | `br close <id>` |
| `sd update <id> --notes "..."` | `br update <id> --description "..."` |
| `sd close <id>` | `br close <id>` |
| `sd close <id> --force` | `br close <id> --reason="..."` |
| `sd dep add <child> <parent>` | `br dep add <child> <parent>` |

## Worker Agent Template

`templates/worker-agent.md` was updated:

```diff
- sd update {{TASK_ID}} --claim
+ br update {{TASK_ID}} --status in_progress

- sd close {{TASK_ID}} --reason "Completed"
+ br close {{TASK_ID}} --reason "Completed via pipeline"

- sd update {{TASK_ID}} --notes "Blocked: ..."
+ br update {{TASK_ID}} --description "Blocked: ..."
```

## Feature Flag Removed

`FOREMAN_TASK_BACKEND` was removed entirely (TRD-024). The backend is always `br`.

Before removing any `if (backend === 'sd')` guards from your own code, search for:

```bash
grep -r "FOREMAN_TASK_BACKEND\|getTaskBackend\|TasksClient\|execSd\|~/.bun/bin/sd" src/
```

All of these should return zero results in the migrated codebase.

## Storage Layout Change

| | tasks | beads_rust |
|-|-------|-----------|
| DB file | `.tasks/issues.jsonl` | `.beads/beads.jsonl` |
| Export command | (auto-committed) | `br sync --flush-only` |
| Git tracking | Yes | Yes (`.beads/` directory) |

Run `foreman migrate-tasks` to convert an existing `.tasks/` directory to `.beads/`.

## Graph-Aware Triage with bv

Install [beads_viewer](https://github.com/Dicklesworthstone/beads_viewer) to unlock
graph-aware execution planning:

```bash
bv --robot-triage --format toon   # Full triage with ranked recommendations
bv --robot-next --format toon     # Single top-priority task
bv --robot-plan                   # Parallel execution tracks
```

`bv` reads `.beads/beads.jsonl` directly — no extra configuration needed.

## Removed Modules

| Module | Reason |
|--------|--------|
| `src/orchestrator/pagerank.ts` | Replaced by `bv --robot-insights` |
| `src/lib/tasks.ts` deprecated aliases | `BeadsClient`, `Bead`, `BeadDetail`, `BeadGraph`, `execBd` removed |

`src/lib/tasks.ts` still exists for the `TasksClient` class (used by `migrate-tasks` command)
but it is no longer the active task client.
