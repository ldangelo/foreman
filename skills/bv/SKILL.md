---
name: bv
description: "Beads Viewer (bv) — TUI viewer and AI agent interface for beads issue tracker. Use when: (1) user wants project triage, (2) generating work plans, (3) getting recommendations on what to work on next, (4) analyzing graph metrics (PageRank, betweenness), (5) finding blocked or high-impact issues, (6) any mention of 'triage', 'robot', 'ai agent workflow', or 'beads analysis'. Make sure to use this skill whenever the user mentions beads viewing, project analysis, work prioritization, or needs AI-ready structured output from the issue tracker."
---

# bv — Beads Viewer

`bv` is a TUI viewer and AI agent interface for the beads issue tracker. It provides graph-based analysis, intelligent triage, capacity simulation, and structured JSON output optimized for AI agents.

## When to Use

- **AI agent workflows**: Get structured recommendations for what to work on
- **Project triage**: Understand what's actionable, blocked, or critical
- **Graph analysis**: PageRank, betweenness centrality, dependency analysis
- **Capacity planning**: Simulate team velocity and completion forecasts
- **TUI exploration**: Browse issues visually in the terminal

## Prerequisites

- **bv binary**: Part of beads install (`brew install beads`)
- **Initialized beads workspace**: `br init` in project directory

## Quick Reference

| Command | Purpose |
|---------|---------|
| `bv --robot-triage` | Full project triage (AI agents) |
| `bv --robot-next` | Single top recommendation |
| `bv --robot-plan` | Dependency-respecting execution plan |
| `bv --robot-insights` | Graph metrics (PageRank, etc.) |
| `bv` | Launch TUI viewer |

## AI Agent Commands

These commands output structured JSON for AI agents.

### THE Mega-Commands

```bash
# Full triage — everything needed in one call
bv --robot-triage

# Minimal: just the top recommendation
bv --robot-next

# Execution plan with parallel tracks
bv --robot-plan
```

### Triage Variants

```bash
# Group by independent execution tracks (for multi-agent)
bv --robot-triage-by-track

# Group by label (for area-focused agents)
bv --robot-triage-by-label
```

### Insights and Metrics

```bash
# Deep graph analysis
bv --robot-insights
# Returns:
# - pagerank: Blocking power scores
# - betweenness: Bottleneck status
# - hits: Hubs and authorities
# - cycles: Circular dependencies

# Alert analysis
bv --robot-alerts
# Returns stale issues, blocking cascades, priority mismatches

# Priority recommendations
bv --robot-priority
# Compares impact scores to current priorities
```

### Planning and Forecasting

```bash
# Execution plan with dependency respect
bv --robot-plan
# Returns tracks (parallel work streams), items, unblocks

# Capacity simulation
bv --robot-capacity
bv --robot-capacity --agents 5              # 5 parallel agents
bv --robot-capacity --capacity-label api     # Filter by label

# ETA forecasting
bv --robot-forecast all
bv --robot-forecast bd-001
```

### Search and Discovery

```bash
# Semantic search (vector-based)
bv --search "authentication flow"
bv --search "performance optimization" --search-limit 20

# Hybrid search with presets
bv --search "memory leak" --search-mode hybrid --search-preset bug-hunting

# Related beads
bv --robot-related bd-001
bv --robot-related bd-001 --related-min-relevance 70

# Orphan commits (unlinked work)
bv --robot-orphans
```

### File and Code Analysis

```bash
# Beads that touched a file
bv --robot-file-beads src/auth/login.ts
bv --robot-file-beads src/api/handler.ts --file-beads-limit 10

# File hotspots (most-changed files)
bv --robot-file-hotspots

# Co-changing files
bv --robot-file-relations src/auth/login.ts

# Impact analysis
bv --robot-impact src/core/engine.ts
```

### Dependency Analysis

```bash
# Blocker chain for an issue
bv --robot-blocker-chain bd-001

# Causal chain
bv --robot-causality bd-001

# Impact network
bv --robot-impact-network
bv --robot-impact-network bd-001 --network-depth 2

# Suggestions (duplicates, dependencies, cycles)
bv --robot-suggest
bv --robot-suggest --suggest-type cycle
```

### History and Tracking

```bash
# Bead-to-commit correlations
bv --robot-history
bv --robot-history --bead-history bd-001
bv --robot-history --history-since '30 days ago'

# Diff since
bv --diff-since main --robot-diff
bv --diff-since '2024-01-01' --robot-diff

# Sprint information
bv --robot-sprint-list
bv --robot-sprint-show sprint-001

# Burndown data
bv --robot-burndown current
bv --robot-burndown sprint-001
```

## TUI Viewer

```bash
# Launch interactive TUI
bv

# With specific database
bv --db .beads/foreman.db

# As-of historical state
bv --as-of main
bv --as-of '2024-01-01'
```

## Export and Reporting

```bash
# Export to Markdown
bv --export-md report.md
bv --export-md report.md --pages-include-closed

# Export graph
bv --export-graph graph.html      # Interactive HTML
bv --export-graph graph.png       # Static PNG
bv --export-graph graph.mmd      # Mermaid

# Export pages (static site)
bv --export-pages ./bv-pages

# Agent brief bundle
bv --agent-brief ./agent-bundle
```

## Drift Detection

```bash
# Save baseline
bv --save-baseline "Initial state"
bv --save-baseline "After refactoring" --description "Post-refactor metrics"

# Check drift (exit codes: 0=OK, 1=critical, 2=warning)
bv --check-drift

# Get drift report
bv --robot-drift

# View baseline info
bv --baseline-info
```

## Feedback and Tuning

```bash
# Record feedback (tunes recommendations)
bv --feedback-accept bd-001    # This was a good recommendation
bv --feedback-ignore bd-001    # Not relevant to this bead

# View feedback status
bv --feedback-show

# Reset to defaults
bv --feedback-reset
```

## Script Generation

```bash
# Emit shell script for top recommendations
bv --emit-script
bv --emit-script --script-limit 10

# Different shell formats
bv --emit-script --script-format bash
bv --emit-script --script-format zsh
```

## Recipes

Named recipes apply predefined configurations:

```bash
# Available recipes
bv --robot-recipes

# Apply recipe
bv -r triage           # Quick triage focus
bv -r actionable      # Actionable items only
bv -r high-impact      # Highest impact first
```

## Output Formats

```bash
# JSON (default for robot commands)
bv --robot-triage --format json

# TOON (token-optimized, ~30-50% smaller)
bv --robot-triage --format toon

# Graph formats
bv --robot-graph --graph-format json
bv --robot-graph --graph-format dot
bv --robot-graph --graph-format mermaid
```

## Filtering and Scoping

```bash
# By assignee
bv --robot-triage --robot-by-assignee alice

# By label
bv --robot-triage --robot-by-label frontend
bv --robot-insights --label api

# By repository
bv --robot-triage --repo api

# Time-based
bv --robot-history --history-since '7 days ago'
bv --diff-since '2024-01-01'
```

## Agent Brief Export

Generate a complete agent briefing bundle:

```bash
bv --agent-brief ./brief
# Creates:
# - triage.json      # Robot-triage output
# - insights.json     # Robot-insights output
# - brief.md          # Human-readable summary
# - helpers.md        # Useful commands
```

## Common Agent Workflows

### Full triage for a new task

```bash
# 1. Get comprehensive analysis
bv --robot-triage --format json

# 2. If you need specifics
bv --robot-next                          # What's next?
bv --robot-plan                         # Full plan with dependencies
bv --robot-suggest                      # Watch for problems
```

### Investigate a specific bead

```bash
# 1. Get details
bv --robot-related bd-001               # What's related?
bv --robot-blocker-chain bd-001         # What's blocking it?

# 2. Check history
bv --robot-causality bd-001             # Causal chain
bv --robot-history --bead-history bd-001 # Git history

# 3. Get forecast
bv --robot-forecast bd-001              # ETA
```

### Plan a sprint

```bash
# 1. Get triage by track (for parallelization)
bv --robot-triage-by-track

# 2. Check capacity
bv --robot-capacity --agents 5 --forecast-sprint sprint-042

# 3. Export plan
bv --robot-plan --label sprint-042 --emit-script > sprint-tasks.sh
```

### Debug a regression

```bash
# 1. Find related beads
bv --robot-file-beads src/buggy-file.ts

# 2. Check for orphans
bv --robot-orphans

# 3. Check insights for cycles
bv --robot-insights | jq '.cycles'
```

## Schema and Documentation

```bash
# Get schema definitions
bv --robot-schema                       # All schemas
bv --robot-schema --schema-command robot-triage

# Get AI agent help
bv --robot-help

# Get full docs
bv --robot-docs all
```

## Global Options

```bash
--db <path>                # Specific beads database
--format json|toon         # Output format
--label <label>            # Scope to label's subgraph
--graph-root <id>          # Subgraph root
--graph-depth <n>          # Max depth (0=unlimited)
--no-cache                 # Bypass disk cache
-v, -vv                    # Verbose
```

## Notes

- **Robot commands** return JSON optimized for AI consumption
- **TOON format** is ~30-50% smaller than JSON (token savings)
- **Triage is the entry point** — `bv --robot-triage` gives everything in one call
- **Capacity simulation** uses estimate data from beads to project completion
- **Drift detection** compares current state against saved baseline
- **Vector search** builds index on first run; subsequent searches are fast
