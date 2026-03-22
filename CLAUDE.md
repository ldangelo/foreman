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
npx vitest run <file>  # run a single test file

# CLI (after build or via tsx)
foreman init           # Initialize project + beads
foreman run            # Dispatch ready tasks to agents
foreman run --seed X   # Dispatch specific task
foreman status         # Show tasks + active agents
foreman dashboard      # Live dashboard UI
foreman monitor        # Check agent health
foreman sentinel       # Background health daemon
foreman reset          # Clean up failed/stuck runs
foreman retry <seed>   # Re-run a failed pipeline phase
foreman stop           # Gracefully stop all agents
foreman doctor         # Health checks (br, Pi, DB integrity)
foreman sling trd X    # TRD -> task hierarchy (seeds + beads)
foreman plan X         # PRD -> TRD pipeline
foreman merge          # Merge completed branches
foreman pr             # Create PRs for completed work
foreman attach         # Attach to a running agent session
foreman worktree       # Git worktree management
foreman inbox          # Agent mail inbox viewer

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
- `src/cli/commands/` — 19 CLI commands
- `src/orchestrator/` — dispatcher, agent-worker, roles, planner, refinery, conflict-resolver, merge-queue, sentinel
- `src/lib/` — beads-rust.ts (br wrapper), bv.ts (bv client), git.ts (worktrees), store.ts (SQLite), sqlite-mail-client.ts (embedded Agent Mail)
- `src/orchestrator/roles.ts` — agent role prompts (explorerPrompt, developerPrompt, qaPrompt, reviewerPrompt, sentinelPrompt) generated as inline TypeScript functions
- `src/orchestrator/templates.ts` — TASK.md template generated via workerAgentMd() function
- `packages/foreman-pi-extensions/` — Pi RPC spawn strategy extensions (tool-gate, budget-enforcer, audit-logger)

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
- **No nested Claude sessions**: Can't run Claude-invoked commands inside Claude Code (use `--no-llm` variants or run from terminal)
- **TASK.md not AGENTS.md**: Foreman writes per-task context to `TASK.md` in worktrees (not AGENTS.md, which is the project file)
- **CLAUDECODE env var**: Must be stripped from worker spawn env to avoid nested session errors
- **FileHandle cleanup**: Always close `fs.promises.open()` handles after spawn inherits fds (Node v25+)
- **Worktree reuse**: `createWorktree()` handles existing worktree (rebase) and existing branch (attach)
- **Auto-reset on failure**: `markStuck()` resets bead to open when pipeline fails
- **Agent Mail is SQLite-backed**: `SqliteMailClient` (src/lib/sqlite-mail-client.ts) replaced HTTP Agent Mail — no external server needed; state stored in `.foreman/mail.db`

## Debugging & Recovery

```bash
# Stuck or failed runs
foreman doctor         # Check br binary, Pi binary, DB integrity
foreman status         # See all active/failed agents
foreman reset          # Reset all failed/stuck runs to open
foreman reset --seed X # Reset a specific run
foreman retry <seed>   # Re-run a specific pipeline phase

# Agent logs (streamed during run)
ls ~/.foreman/logs/    # One .log file per runId
cat ~/.foreman/logs/<runId>.log

# Worktree cleanup
foreman worktree list   # See all active worktrees
foreman worktree clean  # Remove orphaned worktrees

# Test failures
npm test               # Run all tests
npx vitest run src/orchestrator/__tests__/dispatcher.test.ts  # Single file
npx tsc --noEmit       # Type-check without building
```

**Common failure modes:**
- Agent stuck in Developer phase → `foreman retry <seed>` or `foreman reset --seed <seed>`
- Merge conflict T3/T4 → AI resolution via Pi session; check `~/.foreman/logs/<runId>.log`
- Branch not merged after completion → `foreman merge` to trigger manually
- br state diverged from git → `br sync --flush-only && git add .beads/ && git commit -m "sync beads"`

<!-- br-agent-instructions-v1 -->

---

## Beads Workflow Integration

This project uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`) for issue tracking. Issues are stored in `.beads/` and tracked in git.

### Essential Commands

```bash
# View ready issues (open, unblocked, not deferred)
br ready

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

### Session Logging

**All agents MUST create a `SESSION_LOG.md` file in the worktree root** documenting their work. This provides an audit trail and aids debugging of individual pipeline phases.

The worker process automatically streams all activity to `~/.foreman/logs/{runId}.log`, but agents should also write a human-readable summary.

**Required format** for `SESSION_LOG.md`:

```markdown
# Session Log: <role> agent for <seedId>

## Metadata
- Start: <ISO timestamp>
- Role: <explorer|developer|qa|reviewer>
- Seed: <seedId>
- Status: <in-progress|completed|failed>

## Key Activities
- Activity 1: description and reasoning
- Activity 2: decisions made
- ...

## Artifacts Created
- EXPLORER_REPORT.md (if explorer)
- Changes to <file> (if developer)
- Test results (if QA)
- REVIEW.md (if reviewer)

## End
- Completion time: <ISO timestamp>
- Next phase: <phase name>
```

**Requirements:**
- Create SESSION_LOG.md at the **start** of your session (status: in-progress) and update it at the **end** (status: completed or failed)
- Log is **required**, not optional — write it even if your session fails early
- File lives in the **worktree root** (same level as EXPLORER_REPORT.md, TASK.md, etc.)
- Each pipeline phase writes its own SESSION_LOG.md (phases run separately)

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always sync before ending session

<!-- end-br-agent-instructions -->
