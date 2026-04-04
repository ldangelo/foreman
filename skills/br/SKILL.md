---
name: br
description: "beads_rust (br) issue tracker CLI. Use when: (1) managing issues/beads, (2) tracking tasks, (3) querying the issue database, (4) working with dependencies, (5) any beads_rust command appears in prompts or context. Make sure to use this skill whenever the user mentions beads, issue tracking, task management, dependencies, or needs to create/list/update/close issues — even if they don't explicitly say 'br'."
---

# br — Beads Rust Issue Tracker

`br` is an agent-first issue tracker that combines SQLite for querying with JSONL for an audit trail. It manages issues (called "beads") with full dependency tracking, epics, labels, and a rich query system.

## When to Use

- Creating, listing, updating, or closing issues/beads
- Querying the issue database (ready tasks, blocked tasks, etc.)
- Managing dependencies between issues
- Working with epics and sprint planning
- Any task involving beads_rust issue tracking

## Prerequisites

- **br binary**: `brew install beads` or download from releases
- **SQLite**: Built into macOS/Linux
- **Initialized workspace**: `br init` in your project directory

## Quick Reference

| Command | Purpose |
|---------|---------|
| `br create` | Create a new issue |
| `br list` | List issues with filters |
| `br ready` | List unblocked, ready-to-work issues |
| `br blocked` | List blocked issues |
| `br show` | Show issue details |
| `br update` | Update an issue |
| `br close` | Close an issue |
| `br dep` | Manage dependencies |
| `br epic` | Epic management |
| `br graph` | Visualize dependency graph |

## Essential Commands

### Initialize Workspace

```bash
br init
```

Creates `.beads/` directory with SQLite database and JSONL audit log.

### Create Issues

```bash
# Basic issue
br create "Implement user authentication"

# With type and priority
br create "Fix login bug" -t bug -p P0

# With description
br create "Add dark mode" -d "Implement system-wide dark mode toggle"

# With labels
br create "Refactor API" -l refactor -l api

# With parent (creates child issue)
br create "Write tests" --parent bd-001

# With dependencies
br create "Deploy to prod" --deps task:bd-001,task:bd-002

# Bulk import from markdown file
br create -f tasks.md

# Silent output (just print ID)
br create "Quick task" --silent
```

### List and Query Issues

```bash
# List all open issues (default)
br list

# List with filters
br list -s in_progress           # By status
br list -t bug                  # By type
br list -p P0                   # By priority (0-4)
br list -l frontend             # By label (AND)
br list --label-any bug,urgent  # By label (OR)

# Complex filters
br list --assignee alice        # By assignee
br list --unassigned            # Unassigned only
br list --priority-min 0 --priority-max 1  # P0-P1
br list --title-contains auth   # Title search
br list --desc-contains token   # Description search

# Include closed issues
br list -a

# Limit and sort
br list --limit 10 --sort priority --reverse

# Format options
br list --format json          # JSON output
br list --format csv --fields id,title,status  # CSV with fields
br list --long                  # Long output format
```

### Ready Issues (Agent Workflow)

```bash
# List tasks ready to work on
br ready

# Increase limit
br ready --limit 50

# Filter by assignee
br ready --assignee alice
br ready --unassigned

# Sort options
br ready --sort priority        # P0 first
br ready --sort oldest          # FIFO

# JSON output for scripting
br ready --json
br ready --robot                # Same as --json
```

### Blocked Issues

```bash
# List blocked issues
br blocked

# With full blocker details
br blocked --detailed

# Filter by type or priority
br blocked -t bug
br blocked -p P1
```

### Show Issue Details

```bash
# Show issue
br show bd-001

# Show multiple issues
br show bd-001 bd-002 bd-003

# JSON output
br show bd-001 --json

# Compact output
br show bd-001 --compact
```

### Update Issues

```bash
# Update status
br update bd-001 -s in_progress

# Update multiple fields
br update bd-001 -t bug -p P1 --description "New description"

# Claim task (sets assignee + status atomically)
br update bd-001 --claim

# Assign/reassign
br update bd-001 --assignee alice
br update bd-001 --assignee ""    # Clear assignee

# Labels
br update bd-001 --add-label frontend
br update bd-001 --remove-label draft
br update bd-001 --set-labels frontend,api,urgent

# Set due date
br update bd-001 --due tomorrow
br update bd-001 --due "2024-12-25"
br update bd-001 --due ""         # Clear due date

# Estimate (minutes)
br update bd-001 --estimate 120

# Reparent
br update bd-001 --parent bd-000

# Force update (even if blocked)
br update bd-001 -s in_progress --force
```

### Close Issues

```bash
# Close with reason
br close bd-001 -r "Completed implementation"

# Close multiple
br close bd-001 bd-002 bd-003 -r "Fixed in same PR"

# Force close (even if blocked)
br close bd-001 --force

# Suggest next (show newly unblocked issues)
br close bd-001 --suggest-next

# Silent output
br close bd-001 -r "Done" --robot
```

## Dependency Management

```bash
# Add dependency (bd-001 depends on bd-000)
br dep add bd-001 bd-000

# Remove dependency
br dep remove bd-001 bd-000
br dep rm bd-001 bd-000

# List dependencies of an issue
br dep list bd-001

# Show dependency tree
br dep tree bd-001

# Detect cycles
br dep cycles
```

## Epic Management

```bash
# Show all epics with progress
br epic status

# Close epics with all children done
br epic close-eligible
```

## Visualization

```bash
# Show dependency graph for issue
br graph bd-001

# Show all issues' dependency graphs
br graph --all

# Compact (one line per issue)
br graph bd-001 --compact

# JSON output
br graph bd-001 --json
```

## Search

```bash
# Full-text search
br search "authentication"

# With filters
br search "login" -s open -t bug

# By description content
br search "JWT" --desc-contains token

# Include closed
br search "deprecated" -a
```

## Labels

```bash
# Add/remove labels
br label add bd-001 frontend api
br label remove bd-001 draft

# List labels on an issue
br label list bd-001

# List all labels with counts
br label list-all

# Rename label across all issues
br label rename old-name new-name
```

## Project Statistics

```bash
# Show stats
br stats
br status        # Alias

# Count issues
br count -s open
br count -t bug
br count -l frontend

# Group by
br count --group-by type
```

## Diagnostics and Repair

```bash
# Run diagnostics
br doctor

# Auto-repair (rebuild DB from JSONL)
br doctor --repair
```

## Common Agent Workflow Patterns

### Claim and work on a task

```bash
# 1. Find a ready task
br ready

# 2. Claim it
br update bd-001 --claim

# 3. Do the work...

# 4. Close it
br close bd-001 -r "Implemented feature X"
```

### Create a sprint/feature with dependencies

```bash
# Create epic
br create "User Authentication Epic" -t epic -p P0

# Create child tasks with sequential dependencies
br create "Design auth flow" --parent epic-001
FIRST=$(br create "Implement backend" --parent epic-001 --silent)
SECOND=$(br create "Implement frontend" --parent epic-001 --deps task:$FIRST --silent)
br create "Write tests" --parent epic-001 --deps task:$SECOND
```

### Check what to work on

```bash
# What's ready?
br ready --unassigned

# What's blocked?
br blocked --detailed

# What's in progress?
br list -s in_progress
```

### Sync and export

```bash
# Export to JSONL
br sync --export

# Import from JSONL
br sync --import backup.jsonl

# Check JSONL sync
br sync --status
```

## Output Formats

| Format | Use Case |
|--------|----------|
| `text` | Human-readable (default) |
| `json` | Scripting, APIs |
| `csv` | Spreadsheets, data processing |
| `toon` | Token-optimized for AI agents |

```bash
# CSV with specific fields
br list --format csv --fields id,title,status,assignee

# TOON for AI consumption (smaller output)
br show bd-001 --format toon
```

## Global Options

```bash
--db <path>        # Specific database (auto-discovers if omitted)
--actor <name>     # Actor name for audit trail
--json             # JSON output
--no-db            # JSONL-only mode (no DB)
--no-color         # Disable colors
-v, -vv            # Verbose mode
-q                 # Quiet mode (errors only)
```

## Notes

- **br uses `--json` flag** (not subcommand) for JSON output on most commands
- **TOON format** is a compact binary-like format optimized for AI agent token budgets
- **Atomic operations**: `--claim` combines assignee + status in one update
- **JSONL audit log** in `.beads/*.jsonl` provides full change history
- **Auto-discovery**: `br` finds `.beads/*.db` automatically in current directory and parents
