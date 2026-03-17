# Foreman — Claude Code Context

## Project Overview

Foreman is an AI-powered engineering orchestrator that decomposes work into tasks, dispatches them to Claude agents in isolated git worktrees, and merges results back. Built with TypeScript, Claude Agent SDK, and [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`) for task tracking.

## Quick Reference

```bash
# Development
npm run build          # tsc compile
npm test               # vitest run
npm run dev            # tsx watch mode
npx tsc --noEmit       # type check only

# CLI (after build or via tsx)
foreman init           # Initialize project + beads
foreman run            # Dispatch ready tasks to agents
foreman run --seed X   # Dispatch specific task
foreman status         # Show tasks + active agents
foreman monitor        # Check agent health
foreman reset          # Clean up failed/stuck runs
foreman decompose X    # TRD -> task hierarchy
foreman plan X         # PRD -> TRD pipeline
foreman merge          # Merge completed branches
foreman pr             # Create PRs for completed work

# br (beads_rust) task tracking
br ready               # Unblocked tasks
br list --status=open  # All tasks
br show <id>           # Task detail
br create --title "X" --type task --priority 2
br update <id> --status=in_progress
br close <id>          # Complete
```

## Architecture

```
CLI (commander) -> Dispatcher -> Agent Workers (detached processes)
                      |              |
                   SQLite         Claude SDK query()
                   (state)        (per-phase sessions)
                      |
                   br (beads_rust)   Pipeline phases:
                   (task graph)      Explorer -> Developer <-> QA -> Reviewer -> Finalize
```

**Key modules:**
- `src/cli/commands/` — 10 CLI commands
- `src/orchestrator/` — dispatcher, agent-worker, roles, planner, refinery
- `src/lib/` — beads-rust.ts (br wrapper), bv.ts (bv client), git.ts (worktrees), store.ts (SQLite)
- `templates/` — worker-agent.md, refinery-agent.md

**Agent pipeline** (orchestrated by TypeScript, not AI):
1. **Explorer** (Haiku, 30 turns) — read-only codebase analysis -> EXPLORER_REPORT.md
2. **Developer** (Sonnet, 80 turns) — implementation + tests
3. **QA** (Sonnet, 30 turns) — test verification -> QA_REPORT.md
4. **Reviewer** (Sonnet, 20 turns) — code review -> REVIEW.md
5. **Finalize** — git add/commit/push, br close

Dev <-> QA retries up to 2x before proceeding to Review. Reviewer FAILs on CRITICAL/WARNING issues.

## Development Rules

- **TypeScript strict mode** — no `any` escape hatches
- **ESM only** — all imports use `.js` extensions
- **TDD** — RED-GREEN-REFACTOR cycle
- **Test coverage** — unit >= 80%, integration >= 70%
- **Vitest** for testing, co-located in `__tests__/` subdirs
- **No secrets in code** — use env vars
- **Input validation at boundaries only**

## br (beads_rust) Conventions

- Installed at `~/.local/bin/br`
- Storage: `.beads/beads.jsonl` (git-tracked)
- Types: `bug | feature | task | epic | chore | docs | question`
- Priorities: `0` (critical) through `4` (backlog) — never use words like "high"/"medium"
- `br dep add <issue> <depends-on>` to declare blocking dependencies
- `br ready` shows issues with no open blockers
- `br close <id1> <id2>` to close multiple issues at once
- `br sync --flush-only` to export DB to JSONL before committing

## Critical Constraints

- **Non-interactive shell commands**: Always use `cp -f`, `mv -f`, `rm -f` (agents hang on `-i` prompts)
- **No nested Claude sessions**: Can't run `foreman decompose --llm` inside Claude Code
- **TASK.md not AGENTS.md**: Foreman writes per-task context to `TASK.md` in worktrees (not AGENTS.md, which is the project file)
- **CLAUDECODE env var**: Must be stripped from worker spawn env to avoid nested session errors
- **FileHandle cleanup**: Always close `fs.promises.open()` handles after spawn inherits fds (Node v25+)
- **Worktree reuse**: `createWorktree()` handles existing worktree (rebase) and existing branch (attach)
- **Auto-reset on failure**: `markStuck()` resets bead to open when pipeline fails

<!-- br-agent-instructions-v1 -->

---

## Beads Workflow Integration

This project uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`/`bd`) for issue tracking. Issues are stored in `.beads/` and tracked in git.

### Essential Commands

```bash
# View ready issues (open, unblocked, not deferred)
br ready              # or: bd ready

# List and search
br list --status=open # All open issues
br show <id>          # Full issue details with dependencies
br search "keyword"   # Full-text search

# Create and update
br create --title="..." --description="..." --type=task --priority=2
br update <id> --status=in_progress
br close <id> --reason="Completed"
br close <id1> <id2>  # Close multiple issues at once

# Sync with git
br sync --flush-only  # Export DB to JSONL
br sync --status      # Check sync status
```

### Workflow Pattern

1. **Start**: Run `br ready` to find actionable work
2. **Claim**: Use `br update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id>`
5. **Sync**: Always run `br sync --flush-only` at session end

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only open, unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers 0-4, not words)
- **Types**: task, bug, feature, epic, chore, docs, question
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status              # Check what changed
git add <files>         # Stage code changes
br sync --flush-only    # Export beads changes to JSONL
git commit -m "..."     # Commit everything
git push                # Push to remote
```

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always sync before ending session

<!-- end-br-agent-instructions -->
