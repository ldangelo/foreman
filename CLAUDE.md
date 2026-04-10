# Foreman — Claude Code Context

## Project Overview

Foreman is a multi-project engineering control plane. Its product job is to ingest planning artifacts and task backlogs, schedule work across registered projects, and coordinate validation/promotion. Each project then executes that work inside a subordinate execution plane with isolated worktrees or workspaces, workers, and merge/refinery logic.

## Current State vs Roadmap

### Canonical product model
- **Control plane** — project registry, intake, cross-project scheduling, dashboard/status, validation, and promotion policy.
- **Execution plane** — per-project dispatcher, worker pipeline, messaging, merge/refinery, and project-local runtime state.
- **Integration branch model** — completed work should land on an integration branch, pass validation, and only then be promoted to the default branch.

### Current state in this checkout
- Task tracking is primarily `br` / `.beads/`; native task tables and project-registry work exist but are not yet the single canonical path.
- `foreman task` is not a second native-task operator model in this checkout. It currently exposes beads-first approval (`foreman task approve <bead-id>`) plus the transitional `foreman task import --from-beads` migration helper.
- Foreman-created beads now enter an approval backlog via `foreman:backlog`; use `foreman task approve <bead-id>` before expecting `foreman run` to dispatch them.


- The default execution workflow is Explorer → Developer ↔ QA → Reviewer → Finalize.
- Agent Mail is SQLite-backed in `.foreman/foreman.db`; there is no separate `mail.db`.
- VCS abstraction exists and is important, but some orchestration code still contains backend-specific logic or fallbacks. Do not assume full abstraction purity without checking the implementation.
- Mid-pipeline rebase and shared-worktree/grouped execution are documented roadmap items, not fully implemented end-to-end in this checkout.

### How to read these docs
- `CLAUDE.md` describes current implementation truth and the intended product boundary.
- PRD/TRD files describe intended or planned behavior unless the code already proves otherwise.
- When docs and code disagree, trust the code and update the docs in the same change.
## Quick Reference

```bash
# Development
npm run build          # tsc compile
npm test               # vitest run
npm run dev            # tsx watch mode
npx tsc --noEmit       # type check only
npx vitest run <file>  # run a single test file

# CLI (after build or via tsx)
foreman init           # Initialize a project and register it with the control plane
foreman run            # Current checkout: dispatch ready work in the current project
foreman run --project X # Target a registered project without cd
foreman status         # Show task and agent state
foreman status --all   # Aggregate across registered projects
foreman dashboard      # Live cross-project dashboard UI
foreman monitor        # Check agent health
foreman sentinel       # Background validation/health daemon (current checkout semantics)
foreman reset          # Clean up failed/stuck runs
foreman retry <seed>   # Re-run a failed pipeline phase
foreman task approve X # Release a backlog bead for dispatch
foreman stop           # Gracefully stop all agents
foreman doctor         # Health checks (br, Pi, DB integrity)
foreman debug <id>     # AI-powered execution analysis (Opus)
foreman sling trd X    # TRD -> task hierarchy (current checkout still seeds/beads-backed)
foreman plan X         # PRD -> TRD pipeline
foreman merge          # Reconcile completed work into the merge/integration flow
foreman pr             # Create PRs for completed work
foreman attach         # Attach to a running agent session
foreman worktree       # Git worktree management
foreman inbox          # Agent mail inbox viewer
foreman inbox --all --watch  # Live stream all mail across runs

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
Foreman control plane
  │
  ├─ Project registry + project metadata
  ├─ Intake: PRD / TRD / task backlog ingestion
  ├─ Scheduler: cross-project dispatch, fairness, capacity
  ├─ Dashboard / status / approval surfaces
  └─ Validation + promotion policy
       │
       └─ per project: execution plane
            ├─ Dispatcher / workspace setup
            ├─ Agent workers
            ├─ Workflow pipeline executor
            ├─ SQLite runtime state + agent mail
            └─ Refinery / merge queue → integration branch
```

**Key modules by boundary:**
- `src/cli/commands/` — operator-facing control-plane and execution entrypoints
- `src/lib/project-registry.ts` — current global project registry surface (still needs authority unification)
- `src/orchestrator/dispatcher.ts` — current project-local dispatch and worktree setup
- `src/orchestrator/agent-worker.ts` — detached worker process and execution orchestration
- `src/orchestrator/pipeline-executor.ts` — workflow YAML-driven execution phases
- `src/orchestrator/refinery.ts` / `src/orchestrator/auto-merge.ts` — merge queue and post-execution merge handling
- `src/lib/store.ts` — SQLite execution state in the current checkout
- `src/lib/sqlite-mail-client.ts` — Agent Mail implementation
- `src/lib/workflow-loader.ts` — YAML workflow config parser

**Execution pipeline details**
- Workflow YAML still defines execution-phase order, retries, mail hooks, and artifacts inside the per-project execution plane.
- The default execution workflow remains Explorer → Developer ↔ QA → Reviewer → Finalize.
- Those phases are implementation detail for project-local execution, not the top-level product boundary.
- Current code still has execution-plane-first drift: for example, `foreman run` remains project-scoped and auto-merge still needs explicit integration-branch cutover.

## VCS Backend Abstraction (PRD-2026-004)

Foreman has a `VcsBackend` abstraction so orchestration code can target Git and Jujutsu through one interface where possible. Two built-in implementations ship with Foreman:

- **`GitBackend`** (`src/lib/vcs/git-backend.ts`) — wraps standard git CLI commands
- **`JujutsuBackend`** (`src/lib/vcs/jujutsu-backend.ts`) — wraps jj CLI; requires **colocated mode** (`.jj/` + `.git/` both present)

Important: this abstraction is not yet complete in practice. Some orchestration paths still use raw git-specific logic or fall back to `GitBackend` when plumbing is incomplete or a backend instance is not propagated correctly. Treat the abstraction as the intended contract, not as a proof that every current path is backend-pure.

### Key modules

- `src/lib/vcs/interface.ts` — `VcsBackend` interface (25+ methods)
- `src/lib/vcs/types.ts` — Shared types (`Workspace`, `MergeResult`, `FinalizeCommands`, etc.)
- `src/lib/vcs/index.ts` — Re-exports + `VcsBackendFactory` (auto-detection + creation)
- `src/lib/project-config.ts` — `ProjectConfig` loader for `.foreman/config.yaml`

### Configuration precedence

```
Workflow YAML vcs.backend   (highest priority)
    ↓
.foreman/config.yaml vcs.backend
    ↓
Auto-detection (.jj/ → jujutsu, .git/ → git)   (lowest priority)
```

Example `.foreman/config.yaml`:

```yaml
vcs:
  backend: jujutsu        # 'git' | 'jujutsu' | 'auto' (default: 'auto')
  jujutsu:
    minVersion: "0.21.0"  # validated by 'foreman doctor'
```

### Documentation

- [VcsBackend Interface Reference](docs/guides/vcs-backend-interface.md) — Method reference, custom backend guide
- [VCS Configuration Guide](docs/guides/vcs-configuration.md) — Config examples, precedence, troubleshooting
- [Jujutsu Considerations](docs/guides/jujutsu-considerations.md) — Colocated mode, bookmarks, finalize diffs, migration

## Development Rules

- **TypeScript strict mode** — no `any` escape hatches
- **ESM only** — all imports use `.js` extensions
- **TDD** — RED-GREEN-REFACTOR cycle
- **Test coverage** — unit >= 80%, integration >= 70%
- **Vitest** for testing, co-located in `__tests__/` subdirs
- **No secrets in code** — use env vars
- **Input validation at boundaries only**

## Workflow YAML Configuration

Workflows live in `src/defaults/workflows/` (bundled) and `.foreman/workflows/` (project-local overrides).

```yaml
# Example: src/defaults/workflows/default.yaml
name: default
phases:
  - name: explorer
    prompt: explorer.md
    models:
      default: haiku
      P0: opus
    maxTurns: 30
    artifact: EXPLORER_REPORT.md
    skipIfArtifact: EXPLORER_REPORT.md
    mail:
      onStart: true
      onComplete: true
      forwardArtifactTo: developer

  - name: qa
    prompt: qa.md
    models:
      default: sonnet
      P0: opus
    artifact: QA_REPORT.md
    verdict: true            # parse PASS/FAIL from artifact
    retryWith: developer     # on FAIL, loop back to developer
    retryOnFail: 2           # max retry count
    mail:
      onFail: developer      # send feedback to developer on FAIL
```

**Model shorthands:** `haiku` → `anthropic/claude-haiku-4-5`, `sonnet` → `anthropic/claude-sonnet-4-6`, `opus` → `anthropic/claude-opus-4-6`. Full model IDs also accepted (e.g. `openai/gpt-4o`).

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
- **Worktree reuse**: workspace creation handles existing worktrees/branches; some older comments still say `createWorktree()`, but current dispatcher paths should prefer backend workspace APIs.
- **Auto-reset on failure**: `markStuck()` resets bead to open when pipeline fails (rate limits); marks failed for permanent errors.
- **Agent Mail is SQLite-backed**: Messages stored in `.foreman/foreman.db` (shared across all workers), not a separate mail.db.
- **SESSION_LOG.md excluded from commits**: Causes merge conflicts when multiple pipelines run concurrently; finalize prompt runs `git reset HEAD SESSION_LOG.md` after `git add -A`.
- **Finalize rebases before push**: this is current shipped behavior. Mid-pipeline rebase is roadmap work, not something operators should assume is live without verifying the checkout.

## Debugging & Recovery

```bash
# AI-powered execution analysis
foreman debug <bead-id>         # Full Opus analysis of pipeline run
foreman debug <bead-id> --raw   # Dump all artifacts without AI
foreman debug <bead-id> --model anthropic/claude-sonnet-4-6  # Cheaper model

# Stuck or failed runs
foreman doctor         # Check br binary, Pi binary, DB integrity
foreman status         # See all active/failed agents
foreman reset          # Reset all failed/stuck runs to open
foreman reset --bead X # Reset a specific run
foreman retry <seed>   # Re-run a specific pipeline phase

# Agent logs (streamed during run)
ls ~/.foreman/logs/    # One .log file per runId
cat ~/.foreman/logs/<runId>.log

# Mail inspection
foreman inbox --all --watch  # Live stream all mail across all runs
foreman inbox --bead X       # Mail for a specific bead

# Worktree cleanup
foreman worktree list   # See all active worktrees
foreman worktree clean  # Remove orphaned worktrees

# Test failures
npm test               # Run all tests
npx vitest run src/orchestrator/__tests__/dispatcher.test.ts  # Single file
npx tsc --noEmit       # Type-check without building
```

**Common failure modes:**
- Agent stuck in Developer phase → `foreman retry <seed>` or `foreman reset --bead <bead>`
- Branch not merged after completion → `foreman merge` to trigger manually
- autoMerge returns failed=1 → check run status is "completed" before merge queue entry
- Merge conflict on SESSION_LOG.md → already fixed (excluded from commits)
- br state diverged from git → `br sync --flush-only && git add .beads/ && git commit -m "sync beads"`
- agent-worker crash on startup → check `~/.foreman/logs/<runId>.err` for syntax/import errors

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

Saving a session log is **required** — not optional. At the end of every agent session, write a `SESSION_LOG.md` in the worktree root documenting what was done.

Agent worker logs are automatically written to `~/.foreman/logs/<runId>.log` and streamed in real time. The SESSION_LOG.md is a higher-level human-readable record.

**SESSION_LOG.md format:**

```markdown
## Metadata
- Date: <ISO date>
- Phase: <explorer | developer | qa | reviewer | finalize>
- Seed: <seed-id>
- Run ID: <run-id>

## Key Activities
- <brief description of each major action taken>

## Artifacts Created
- <list of files created or modified>

## Notes
- <any observations, blockers, or context for the next agent>
```

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always sync before ending session

<!-- end-br-agent-instructions -->

<!-- mulch:start -->
## Project Expertise (Mulch)
<!-- mulch-onboard-v:1 -->

This project uses [Mulch](https://github.com/jayminwest/mulch) for structured expertise management.

**At the start of every session**, run:
```bash
mulch prime
```

This injects project-specific conventions, patterns, decisions, and other learnings into your context.
Use `mulch prime --files src/foo.ts` to load only records relevant to specific files.

**Before completing your task**, review your work for insights worth preserving — conventions discovered,
patterns applied, failures encountered, or decisions made — and record them:
```bash
mulch record <domain> --type <convention|pattern|failure|decision|reference|guide> --description "..."
```

Link evidence when available: `--evidence-commit <sha>`, `--evidence-bead <id>`

Run `mulch status` to check domain health and entry counts.
Run `mulch --help` for full usage.
Mulch write commands use file locking and atomic writes — multiple agents can safely record to the same domain concurrently.

### Before You Finish

1. Discover what to record:
   ```bash
   mulch learn
   ```
2. Store insights from this work session:
   ```bash
   mulch record <domain> --type <convention|pattern|failure|decision|reference|guide> --description "..."
   ```
3. Validate and commit:
   ```bash
   mulch sync
   ```
<!-- mulch:end -->

<!-- seeds:start -->
## Issue Tracking (Seeds)
<!-- seeds-onboard-v:1 -->

This project uses [Seeds](https://github.com/jayminwest/seeds) for git-native issue tracking.

**At the start of every session**, run:
```
sd prime
```

This injects session context: rules, command reference, and workflows.

**Quick reference:**
- `sd ready` — Find unblocked work
- `sd create --title "..." --type task --priority 2` — Create issue
- `sd update <id> --status in_progress` — Claim work
- `sd close <id>` — Complete work
- `sd dep add <id> <depends-on>` — Add dependency between issues
- `sd sync` — Sync with git (run before pushing)

### Before You Finish
1. Close completed issues: `sd close <id>`
2. File issues for remaining work: `sd create --title "..."`
3. Sync and push: `sd sync && git push`
<!-- seeds:end -->

<!-- canopy:start -->
## Prompt Management (Canopy)
<!-- canopy-onboard-v:1 -->

This project uses [Canopy](https://github.com/jayminwest/canopy) for git-native prompt management.

**At the start of every session**, run:
```
cn prime
```

This injects prompt workflow context: commands, conventions, and common workflows.

**Quick reference:**
- `cn list` — List all prompts
- `cn render <name>` — View rendered prompt (resolves inheritance)
- `cn emit --all` — Render prompts to files
- `cn update <name>` — Update a prompt (creates new version)
- `cn sync` — Stage and commit .canopy/ changes

**Do not manually edit emitted files.** Use `cn update` to modify prompts, then `cn emit` to regenerate.
<!-- canopy:end -->
