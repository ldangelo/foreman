# Foreman — Claude Code Context

## Project Overview

Foreman is an AI-powered engineering orchestrator that decomposes work into tasks, dispatches them to Claude agents in isolated git worktrees, and merges results back. Built with TypeScript, Claude Agent SDK, and seeds (sd) for task tracking.

## Quick Reference

```bash
# Development
npm run build          # tsc compile
npm test               # vitest run
npm run dev            # tsx watch mode
npx tsc --noEmit       # type check only

# CLI (after build or via tsx)
foreman init           # Initialize project + seeds
foreman run            # Dispatch ready tasks to agents
foreman run --seed X   # Dispatch specific task
foreman status         # Show tasks + active agents
foreman monitor        # Check agent health
foreman reset          # Clean up failed/stuck runs
foreman decompose X    # TRD -> task hierarchy
foreman plan X         # PRD -> TRD pipeline
foreman merge          # Merge completed branches
foreman pr             # Create PRs for completed work

# Seeds (sd) task tracking
sd ready               # Unblocked tasks
sd list --json         # All tasks
sd show <id>           # Task detail
sd create --title "X" --type task --priority P2
sd update <id> --claim # Atomic claim
sd close <id>          # Complete
```

## Architecture

```
CLI (commander) -> Dispatcher -> Agent Workers (detached processes)
                      |              |
                   SQLite         Claude SDK query()
                   (state)        (per-phase sessions)
                      |
                   Seeds (sd)     Pipeline phases:
                   (task graph)   Explorer -> Developer <-> QA -> Reviewer -> Finalize
```

**Key modules:**
- `src/cli/commands/` — 10 CLI commands
- `src/orchestrator/` — dispatcher, agent-worker, roles, planner, refinery
- `src/lib/` — seeds.ts (seeds wrapper), git.ts (worktrees), store.ts (SQLite)
- `templates/` — worker-agent.md, refinery-agent.md

**Agent pipeline** (orchestrated by TypeScript, not AI):
1. **Explorer** (Haiku, 30 turns) — read-only codebase analysis -> EXPLORER_REPORT.md
2. **Developer** (Sonnet, 80 turns) — implementation + tests
3. **QA** (Sonnet, 30 turns) — test verification -> QA_REPORT.md
4. **Reviewer** (Sonnet, 20 turns) — code review -> REVIEW.md
5. **Finalize** — git add/commit/push, sd close

Dev <-> QA retries up to 2x before proceeding to Review. Reviewer FAILs on CRITICAL/WARNING issues.

## Development Rules

- **TypeScript strict mode** — no `any` escape hatches
- **ESM only** — all imports use `.js` extensions
- **TDD** — RED-GREEN-REFACTOR cycle
- **Test coverage** — unit >= 80%, integration >= 70%
- **Vitest** for testing, co-located in `__tests__/` subdirs
- **No secrets in code** — use env vars
- **Input validation at boundaries only**

## Seeds (sd) Conventions

- Installed at `~/.bun/bin/sd` (from `@os-eco/seeds-cli`)
- Storage: `.seeds/issues.jsonl` (git-tracked)
- Types: `bug | feature | task | epic | chore | decision`
- Priorities: `P0` (critical) through `P4` (backlog) — never use words like "high"/"medium"
- `--parent` creates organizational deps only (does NOT block `sd ready`)
- `blocks` dep type is what actually blocks readiness
- Don't add explicit container deps (sprint->story, story->task) — creates deadlocks
- Use `kind:` labels for semantic types: `kind:sprint`, `kind:story`, `kind:spike`, `kind:test`
- `sd close --force` needed to close issues with blocking deps
- `sd list --limit 0` to get all issues (default limit is 50)

## Critical Constraints

- **Non-interactive shell commands**: Always use `cp -f`, `mv -f`, `rm -f` (agents hang on `-i` prompts)
- **No nested Claude sessions**: Can't run `foreman decompose --llm` inside Claude Code
- **TASK.md not AGENTS.md**: Foreman writes per-task context to `TASK.md` in worktrees (not AGENTS.md, which is the project file)
- **CLAUDECODE env var**: Must be stripped from worker spawn env to avoid nested session errors
- **FileHandle cleanup**: Always close `fs.promises.open()` handles after spawn inherits fds (Node v25+)
- **Worktree reuse**: `createWorktree()` handles existing worktree (rebase) and existing branch (attach)
- **Auto-reset on failure**: `markStuck()` resets seed to open when pipeline fails
