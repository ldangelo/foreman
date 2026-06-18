# Foreman — Claude Code Context

## Project Overview

Foreman is an AI-powered engineering orchestrator that decomposes work into tasks, dispatches them to AI agents in isolated git worktrees, and merges results back. Built with TypeScript, [Pi SDK](https://pi.dev) (`@mariozechner/pi-coding-agent`) for in-process agent sessions, and [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`) for task tracking.

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
foreman run --bead X   # Dispatch specific task
foreman status         # Show tasks + active agents
foreman watch          # Live dashboard TUI ('dashboard' is a deprecated alias)
foreman sentinel       # Background health daemon
foreman reset          # Clean up failed/stuck runs
foreman reset --detect-stuck  # Detect + reset stuck runs (replaces 'foreman monitor')
foreman reset --task X --preserve-worktree  # Reset state but keep repair worktree/branch
foreman retry <seed>   # Re-run a failed pipeline phase
foreman stop           # Gracefully stop all agents
foreman doctor         # Health checks (br, Pi, DB integrity)
foreman debug <id>     # AI-powered execution analysis (Opus)
foreman sling trd X    # TRD -> task hierarchy (seeds + beads)
foreman plan X         # PRD -> TRD pipeline
foreman plan prd|trd X # Server-backed PRD/TRD planning
foreman import --to-elixir --file migration.json  # Import legacy state into Elixir events
foreman server doctor # Elixir default backend; scheduler ticks every 5s, reconciles terminal worker logs, and launches workers; validates DB/projection/worker/VCS/provider/integration health + metrics
# Workflow runtime: Explorer/QA phase overwatch tracks tools, validates reports, steers runaway phases, and treats maxTurns as emergency fuse
foreman merge          # Merge completed branches
foreman pr             # Create PRs for completed work
foreman attach         # Attach to a running agent session
foreman worktree       # Git worktree management
foreman task create --from-text "X"  # Natural-language task creation (replaces 'foreman bead')
foreman purge logs     # Remove old agent logs (~/.foreman/logs/)
foreman purge runs     # Remove stale failed run records
foreman inbox          # Agent mail + selected-run lifecycle events
foreman inbox send     # Send an Agent Mail message (replaces 'foreman mail send')
foreman inbox --all --watch  # Live stream all mail across runs
foreman mcp --transport stdio # MCP tools via Elixir backend; use --transport http for remote clients
# In Pi: /foreman-smoke, /foreman-tasks, /foreman-task <id>, /foreman-approve, /foreman-runs, /foreman-logs [run-id], /foreman-inbox, /foreman-events, /foreman-scheduler, /foreman-tick

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
                   PostgreSQL         Pi SDK (in-process)
                   (state)        createAgentSession()
                      |              |
                   br (beads_rust)   Pipeline Executor
                   (task graph)      (workflow YAML-driven)
                                     |
                                  Refinery + autoMerge
                                  (merge queue → dev branch)
```

TRD-2026-014 Elixir migration split:

```
Node CLI -> authenticated JSON -> Elixir/OTP server -> worker HTTP protocol -> Node/Pi worker
   |                              |                                  |
   |                              |                                  └─ Pi SDK phases, ordered events/heartbeats/logs/artifacts
   |                              └─ commands, events, projections, run/phase actors, recovery, VCS/PR, doctor/metrics, audits
   └─ command parsing, auto-start, projection rendering, legacy alias/deprecation warnings
```

See `docs/guides/elixir-backend-architecture.md` for the operator architecture, deprecated command mapping, and event/projection/recovery troubleshooting model.

**Key modules:**

- `src/cli/commands/` — 26 CLI commands (including `debug` for AI-powered analysis)
- `src/orchestrator/pipeline-executor.ts` — generic workflow YAML-driven phase executor
- `src/orchestrator/pi-sdk-runner.ts` — Pi SDK wrapper (`createAgentSession` + `session.prompt()`)
- `src/orchestrator/pi-sdk-tools.ts` — custom tools for agents (native `send_mail` tool)
- `src/orchestrator/agent-worker.ts` — detached worker process, pipeline orchestration
- `src/orchestrator/dispatcher.ts` — task dispatch, worktree creation, model selection
- `src/orchestrator/refinery.ts` — merge queue processing, conflict resolution
- `src/orchestrator/auto-merge.ts` — immediate post-pipeline merge trigger
- `src/lib/store.ts` — PostgreSQL state (runs, progress, messages)
- `src/lib/postgres-mail-client.ts` — Agent Mail (Postgres-backed)
- `src/lib/workflow-loader.ts` — YAML workflow config parser
- `src/orchestrator/roles.ts` — prompt generation (`buildPhasePrompt()` + per-phase functions)

**Workflow YAML-driven pipeline** (see [Workflow YAML Reference](docs/workflow-yaml-reference.md)):

- Phase sequence, models, retries, mail hooks, artifacts all defined in YAML
- No hardcoded phase names in the executor — new phases need only YAML + prompt file
- Per-phase model selection with priority-based overrides (P0→opus, default→sonnet, etc.)
- Retry loops: QA⇄Developer and Reviewer⇄Developer with feedback mail
- `send_mail` registered as a native Pi SDK tool — agents call it directly, no bash commands

**Default pipeline phases:**

1. **Explorer** (Haiku) — concise read-only developer handoff → EXPLORER_REPORT.md
2. **Developer** (Sonnet) — implementation only; QA/finalize own tests → DEVELOPER_REPORT.md
3. **QA** (Sonnet) — targeted test verification only → QA_REPORT.md (verdict: PASS/FAIL)
4. **Reviewer** (Sonnet) — code review → REVIEW.md (verdict: PASS/FAIL)
5. **Finalize** (Haiku) — rebase, validate, commit, push → FINALIZE_VALIDATION.md (+ FINALIZE_REPORT.md)

After finalize: autoMerge triggers immediately → refinery merges to dev → bead closed.

## VCS Backend Abstraction (PRD-2026-004)

Foreman abstracts all VCS operations behind a `VcsBackend` interface so that orchestration code is decoupled from the concrete VCS tool. Two built-in implementations ship with Foreman:

- **`GitBackend`** (`src/lib/vcs/git-backend.ts`) — wraps standard git CLI commands
- **`JujutsuBackend`** (`src/lib/vcs/jujutsu-backend.ts`) — wraps jj CLI; requires **colocated mode** (`.jj/` + `.git/` both present)

**All orchestration code uses VcsBackend — no direct git/jj calls outside the backend implementations.**

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
- **TDD** use test driven development for all modifications, when adding features create a test first, prove it fails and then make the tests work, afterwards refine/simplify the tests and code for maintainability.
- **TDD** use test driven development for all modifications, when fixing bugs write a test first that exposes the bug, prove it fails and then make the tests work, afterwards refine/simplify the tests and code for maintainability.
- **Documentation gate** — every fix/feature must consider updates to `CLAUDE.md`, `AGENTS.md`, `README.md`, the Foreman User Guide (`docs/user-guide.md`), and the CLI Reference (`docs/cli-reference.md`) before finalization. Update only docs affected by real behavior, workflow, command, setup, troubleshooting, or operator-expectation changes.

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
    maxTurns: 20
    artifact: "{task.projectReportsDir}/EXPLORER_REPORT.md"
    skipIfArtifact: "{task.projectReportsDir}/EXPLORER_REPORT.md"
    mail:
      onStart: true
      onComplete: true
      forwardArtifactTo: developer

  - name: qa
    prompt: qa.md
    models:
      default: sonnet
      P0: opus
    artifact: "{task.projectReportsDir}/QA_REPORT.md"
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
- **Worktree reuse**: `createWorktree()` handles existing worktree (rebase) and existing branch (attach)
- **Auto-reset on failure**: `markStuck()` resets bead to open when pipeline fails (rate limits); marks failed for permanent errors
- **Agent Mail is PostgreSQL-backed**: Messages stored in Postgres (shared across all workers), not a separate mail database
- **Workspace artifacts excluded from commits**: Finalize unstages `node_modules` (including setup-cache symlinks), `SESSION_LOG.md`, `RUN_LOG.md`, root report files, `docs/reports/**`, and `.beads/issues.jsonl` after `git add -A` to prevent polluted PRs and shared-state churn
- **Finalize always rebases**: `git fetch origin && git rebase origin/dev` before pushing, so refinery can fast-forward merge
- **PR readiness is stabilized**: `pr-wait` requires a short stable ready window, and merge re-waits if GitHub surfaces late pending checks after `pr-wait`

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
foreman purge logs     # Remove old log files (retention policy)
foreman purge runs     # Remove stale failed run records

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
- agent-worker crash on startup/finalize → check `~/.foreman/logs/<runId>.err`; fatal handlers print stack traces when available
- QA says `report missing test command evidence` → ensure `QA_REPORT.md` has `Command run:` and `Test suite: X passed, Y failed`
- provider `529` / `overloaded_error` → bundled prompt phases enter cooldown retry instead of burning normal retry loops

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
