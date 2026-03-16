# Seeds → beads_rust (br) Migration Guide

This document summarises the changes made in the `seeds-to-br-bv-migration` TRD. It covers
what changed, why, and how to update any existing integrations.

## Summary

Foreman has migrated from the `seeds` (`sd`) CLI to [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`) for task tracking, with optional [beads_viewer](https://github.com/Dicklesworthstone/beads_viewer) (`bv`) for graph-aware triage.

| Before | After |
|--------|-------|
| `sd` CLI (`~/.bun/bin/sd`) | `br` CLI (`~/.local/bin/br`) |
| `.seeds/issues.jsonl` | `.beads/beads.jsonl` |
| `SeedsClient` | `BeadsRustClient` |
| `FOREMAN_TASK_BACKEND=sd\|br` | Hardcoded `br` — no env var |
| `pagerank.ts` | Deleted (replaced by `bv --robot-insights`) |

## Why

- `br` provides a richer query model (dependency graph, PageRank, betweenness) via `bv`
- `bv --robot-triage` gives deterministic, precomputed execution ordering
- The dual-backend feature flag added complexity with no active `sd` users
- `pagerank.ts` duplicated functionality that `bv` does better

## Command Mapping

| seeds (`sd`) | beads_rust (`br`) |
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
- sd update {{SEED_ID}} --claim
+ br update {{SEED_ID}} --status in_progress

- sd close {{SEED_ID}} --reason "Completed"
+ br close {{SEED_ID}} --reason "Completed via pipeline"

- sd update {{SEED_ID}} --notes "Blocked: ..."
+ br update {{SEED_ID}} --description "Blocked: ..."
```

## Feature Flag Removed

`FOREMAN_TASK_BACKEND` was removed entirely (TRD-024). The backend is always `br`.

Before removing any `if (backend === 'sd')` guards from your own code, search for:

```bash
grep -r "FOREMAN_TASK_BACKEND\|getTaskBackend\|SeedsClient\|execSd\|~/.bun/bin/sd" src/
```

All of these should return zero results in the migrated codebase.

## Storage Layout Change

| | seeds | beads_rust |
|-|-------|-----------|
| DB file | `.seeds/issues.jsonl` | `.beads/beads.jsonl` |
| Export command | (auto-committed) | `br sync --flush-only` |
| Git tracking | Yes | Yes (`.beads/` directory) |

Run `foreman migrate-seeds` to convert an existing `.seeds/` directory to `.beads/`.

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
| `src/lib/seeds.ts` deprecated aliases | `BeadsClient`, `Bead`, `BeadDetail`, `BeadGraph`, `execBd` removed |

`src/lib/seeds.ts` still exists for the `SeedsClient` class (used by `migrate-seeds` command)
but it is no longer the active task client.
