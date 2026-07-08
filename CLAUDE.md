# Foreman — Claude Code Context

## Project Overview

Foreman is an AI-powered engineering orchestrator that decomposes work into tasks, dispatches them to AI agents in isolated git worktrees, and merges results back. Built with TypeScript, [Pi SDK](https://pi.dev) (`@mariozechner/pi-coding-agent`) for in-process agent sessions, with the Elixir backend for task tracking.

## Quick Reference

```bash
# Development
npm run build          # tsc compile
npm test               # vitest run
npm run test:coverage:transition  # Elixir-transition coverage gate
npm run dev            # tsx watch mode
npx tsc --noEmit       # type check only
npx vitest run <file>  # run a single test file

# CLI (after build or via tsx)
foreman init           # Initialize project and register it with the Elixir backend
foreman run            # Tick Elixir scheduler for ready-task dispatch
foreman status         # Show tasks + active agents
foreman watch          # Live dashboard TUI ('dashboard' is a deprecated alias)
foreman sentinel       # Background health daemon
foreman retry <task>   # Re-run a failed pipeline phase
foreman reset <task>   # Close open/draft PRs, fail stale active runs, clean worktree/branch artifacts, and re-dispatch
foreman doctor         # Health checks + safe stale run/worktree cleanup with --fix
foreman debug <id>     # AI-powered execution analysis (Opus)
foreman sling trd X    # TRD -> task hierarchy
foreman plan X         # PRD -> TRD pipeline
foreman plan prd|trd X # Server-backed PRD/TRD planning
foreman import --to-elixir --file migration.json  # Import legacy state into Elixir events
foreman server doctor # Elixir default backend; scheduler ticks every 5s and launches workers; validates DB/projection/worker/VCS/provider/integration health + metrics
foreman merge          # Merge completed branches
foreman pr             # Create PRs for completed work
foreman attach         # Attach to a running agent session
foreman worktree       # Git worktree management
foreman purge logs     # Remove old agent logs (~/.foreman/logs/)
foreman purge runs     # Remove stale failed run records
foreman inbox          # Agent mail + selected-run lifecycle events
foreman inbox --task X --events  # Grouped workflow→phase→message/tool timeline
foreman inbox send     # Send an Agent Mail message (replaces 'foreman mail send')
foreman inbox --all --watch  # Live stream all mail across runs
foreman mcp --transport stdio # MCP tools via Elixir backend plus local reset cleanup; use --transport http for remote clients
# In Pi: /foreman-smoke, /foreman-tasks, /foreman-task <id>, /foreman-approve, /foreman-runs, /foreman-inbox, /foreman-events, /foreman-scheduler, /foreman-tick

# Elixir task tracking
native task store ready               # Unblocked tasks
native task store list --status=open  # All tasks
native task store show <id>           # Task detail
native task store create --title "X" --type task --priority 2
native task store update <id> --status=in_progress
native task store close <id>          # Complete
```

## Architecture

```
CLI (commander) -> Dispatcher -> Agent Workers (detached processes)
                      |              |
                   PostgreSQL         Pi SDK (in-process)
                   (state)        createAgentSession()
                      |              |
                   Elixir task store   Pipeline Executor
                   (task graph)      (workflow YAML-driven)
                                     |
                                  Refinery + autoMerge
                                  (merge queue → dev branch)
```

TRD-2026-014 Elixir migration split:

**Event-sourced orchestration invariant:** domain events are the source of truth and operational trigger. Projections are read models only. In Postgres event-store mode, project/task/run/inbox projections persist in Postgres read-model tables; in term mode they remain in memory and rebuild from the term log. Scheduler/run loop, inbox/watch surfaces, and recovery flows must consume or reconcile from events, then read projections to decide action; do not rely on projection polling as the primary signal. Node/Pi workers emit authoritative terminal run/task events plus Pi SDK tool-call/assistant-message trace events; raw logs are compatibility/debug projections and must not contain unique operational truth. Launchers only record process-exit facts and must not infer success/failure from stdout.

```
Node CLI -> authenticated JSON -> Elixir/OTP server -> worker HTTP protocol -> Node/Pi worker
   |                              |                                  |
   |                              |                                  └─ Pi SDK phases, ordered events/heartbeats/logs/artifacts + Elixir overwatch policy/nudges
   |                              └─ commands, events, projections, run/phase actors, recovery, VCS/PR, doctor/metrics, audits
   └─ command parsing, auto-start, projection rendering, legacy alias/deprecation warnings
```

See `docs/guides/elixir-backend-architecture.md` for the operator architecture, deprecated command mapping, and event/projection/recovery troubleshooting model.

**Key modules:**

- `src/cli/commands/` — 26 CLI commands (including `debug` for AI-powered analysis)
- `src/orchestrator/pipeline-executor.ts` — generic workflow YAML-driven phase executor
- `src/orchestrator/pi-sdk-runner.ts` — Pi SDK wrapper (`createAgentSession` + `session.prompt()`)
- `src/orchestrator/pi-sdk-tools.ts` — custom tools for agents (`send_mail`, `mail_send`, `mail_read`, `phase_handoff`, `artifact_write`, `validation_result`, `task_block`, `progress_update`, `safe_command_run`)
- `src/orchestrator/agent-worker.ts` — detached worker process, pipeline orchestration
- `src/orchestrator/dispatcher.ts` — task dispatch, worktree creation, model selection
- `src/orchestrator/refinery.ts` — merge queue processing, conflict resolution
- `src/orchestrator/auto-merge.ts` — immediate post-pipeline merge trigger
- `src/lib/store.ts` — local state for unregistered/offline paths (runs, progress, messages)
- `src/lib/postgres-mail-client.ts` — legacy-named Agent Mail shim; no direct database access
- `src/lib/workflow-loader.ts` — YAML workflow config parser
- `src/orchestrator/roles.ts` — prompt generation (`buildPhasePrompt()` + per-phase functions)

**Workflow YAML-driven pipeline** (see [Workflow YAML Reference](docs/workflow-yaml-reference.md)):

- Phase sequence, models, retries, mail hooks, artifacts all defined in YAML
- No hardcoded phase names in the executor — new phases need only YAML + prompt file
- Per-phase model selection with priority-based overrides (P0→opus, default→sonnet, etc.)
- Retry loops: verdict failures route to focused repair phases when configured (`repair.md` in bundled `task`/`docs` workflows) so agents fix only reported QA/review/finalize assertions; specialized retry targets still handle CI, CodeRabbit, and merge-conflict failures.
- Mutating phases with `checkpointPr: true` commit/push successful dirty work and maintain a draft PR before the final `create-pr` gate marks it ready.
- `send_mail` registered as a native Pi SDK tool — agents call it directly, no bash commands

**Default pipeline phases:**

1. **Explorer** (Haiku) — concise read-only developer handoff → EXPLORER_REPORT.md
2. **Developer** (Sonnet) — implementation only; QA/finalize own tests → DEVELOPER_REPORT.md
3. **QA** (Sonnet) — targeted test verification only → QA_REPORT.md (verdict: PASS/FAIL)
4. **Reviewer** (Sonnet) — code review → REVIEW.md (verdict: PASS/FAIL)
5. **Finalize** (Haiku) — rebase, validate, commit, push → FINALIZE_VALIDATION.md (+ FINALIZE_REPORT.md)

After finalize: worker enqueues/reports merge readiness via Elixir-backed paths; merge/refinery processing owns the drain/merge lifecycle.

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

Workflows live in `src/defaults/workflows/` (bundled) and `.foreman/workflows/` (project-local overrides). A workflow may declare top-level `task_type: <type>`; each task type must be declared by at most one workflow. PR/merge behavior is phase-driven: mutating phases may set `checkpointPr: true` to create/update a draft PR early, while final gating stays in explicit `create-pr`, `pr-wait`, and `merge` phases; top-level `merge:` and `pr:` workflow tags are invalid. The bundled workflows use lightweight `Grep`, `Glob`, and targeted `Read` discovery; they do not build or update a graph index. After editing bundled source workflows or prompts, run `foreman init --force`; dispatch (`foreman run`, `foreman run --watch`, and direct worker startup) aborts if installed prompts/workflows are stale so agents cannot run with outdated runtime instructions.

```yaml
# Example: src/defaults/workflows/default.yaml
name: default
phases:
  - name: explorer
    prompt: explorer.md
    models:
      default: haiku
      P0: opus
    maxTurns: 12
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

## Critical Constraints

- **Non-interactive shell commands**: Always use `cp -f`, `mv -f`, `rm -f` (agents hang on `-i` prompts)
- **No nested Claude sessions**: Can't run Claude-invoked commands inside Claude Code (use `--no-llm` variants or run from terminal)
- **TASK.md not AGENTS.md**: Foreman writes per-task context to `TASK.md` in worktrees (not AGENTS.md, which is the project file)
- **CLAUDECODE env var**: Must be stripped from worker spawn env to avoid nested session errors
- **FileHandle cleanup**: Always close `fs.promises.open()` handles after spawn inherits fds (Node v25+)
- **Worktree reuse**: `createWorktree()` handles existing worktree (rebase) and existing branch (attach)
- **Auto-reset on failure**: `markStuck()` resets task to open when pipeline fails (rate limits); marks failed for permanent errors
- **Node workers do not connect to the database**: Elixir owns database access. Node/Pi workers and CLI clients use Elixir HTTP commands/projections for task/run/mail state; do not pass `DATABASE_URL` into workers or add Postgres-backed worker fallbacks.
- **Workspace artifacts excluded from commits**: Finalize unstages `node_modules` (including setup-cache symlinks), `SESSION_LOG.md`, `RUN_LOG.md`, root report files, `docs/reports/**`, after `git add -A` to prevent polluted PRs and shared-state churn
- **Finalize always rebases**: `git fetch origin && git rebase origin/dev` before pushing, so refinery can fast-forward merge
- **PR readiness is stabilized**: `pr-wait` requires a short stable ready window, and merge re-waits if GitHub surfaces late pending checks after `pr-wait`

## Debugging & Recovery

```bash
# AI-powered execution analysis
foreman debug <task-id>         # Full Opus analysis of pipeline run
foreman debug <task-id> --raw   # Dump all artifacts without AI
foreman debug <task-id> --model anthropic/claude-sonnet-4-6  # Cheaper model

# Stuck or failed runs
foreman doctor         # Check native task store/Pi, DB integrity, stale runs/worktrees
foreman status         # See all active/failed agents
foreman retry <task>   # Re-run a specific pipeline phase

# Agent logs (streamed during run)
ls ~/.foreman/logs/    # One .log file per runId
cat ~/.foreman/logs/<runId>.log
foreman purge logs     # Remove old log files (retention policy)
foreman purge runs     # Remove stale failed run records

# Mail inspection
foreman inbox --all --watch  # Live stream all mail across all runs
foreman inbox --task X       # Mail/events for a specific task

# Worktree cleanup
foreman worktree list   # See all active worktrees
foreman worktree clean  # Remove orphaned worktrees

# Test failures
npm test               # Run all tests
npx vitest run src/orchestrator/__tests__/dispatcher.test.ts  # Single file
npx tsc --noEmit       # Type-check without building
```

**Common failure modes:**

- Agent stuck in Developer phase → check `foreman inbox --task <id> --events` for overwatch nudges, then `foreman retry <task>` or Elixir recovery workflow
- Branch not merged after completion → `foreman merge` to trigger manually
- autoMerge returns failed=1 → check run status is "completed" before merge queue entry
- Merge conflict on SESSION_LOG.md → already fixed (excluded from commits)
- native task store state diverged from git → `native task store sync --flush-only && git add .tasks/ && git commit -m "sync tasks"`
- agent-worker crash on startup → check `~/.foreman/logs/<runId>.err` for syntax/import errors

<!-- native task store-agent-instructions-v1 -->

### Session Protocol

Follow the worker phase instructions, write required reports, and keep audit artifacts out of commits.

### Session Logging

Session logging is required, not optional. The worker also writes automatic logs under `~/.foreman/logs/`; each agent session must maintain `SESSION_LOG.md` using this format:

---

## Metadata
- Date: <ISO date>
- Phase: <explorer | developer | qa | reviewer | finalize>
- Task: <task-id>
- Run ID: <run-id>

## Key Activities
- <brief description of each major action taken>

## Artifacts Created
- <list of files created or modified>

## Notes
- <any observations, blockers, or context for the next agent>
```

### Best Practices

- Check `native task store ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `native task store create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always sync before ending session

<!-- end-native task store-agent-instructions -->

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

Link evidence when available: `--evidence-commit <sha>`, `--evidence-task <id>`

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
