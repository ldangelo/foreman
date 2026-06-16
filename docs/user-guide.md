# Foreman User Guide

This guide explains how to use Foreman day to day. For exact flags and command syntax, see the [CLI Reference](./cli-reference.md).

## What Foreman Does

Foreman runs AI engineering work through a managed pipeline:

1. Tasks enter the native PostgreSQL-backed task store.
2. `foreman run` dispatches ready tasks to isolated git worktrees.
3. Workflow phases run in order: exploration, implementation, verification, review, documentation, finalization, PR review, and merge where configured.
4. Foreman records progress, phase reports, logs, mail, and merge status.
5. Completed work is finalized and merged through the configured workflow.

Use Foreman when you want multiple AI agents working safely on one repository without sharing a dirty working tree.

## Core Concepts

### Projects

A project is a repository registered with Foreman. Commands that act on a project accept `--project <name-or-path>` so you can operate from another directory.

Common commands:

```bash
foreman init --name my-project
foreman project list
foreman status --project my-project
```

### Tasks

Tasks represent units of work. They have a type, priority, status, title, and description. Typical statuses include backlog, ready, in progress, needs attention, and closed.

```bash
foreman task create --title "Fix flaky retry" --type bug --priority high
foreman task approve <task-id>
foreman task show <task-id>
foreman task list
```

### Workflows

A workflow is a YAML phase sequence. Bundled workflows live in `src/defaults/workflows/`; installed or project-local workflows live under `.foreman/workflows/` or `~/.foreman/workflows/` depending on setup.

Important phase reports:

| Phase | Report |
|-------|--------|
| Explorer | `EXPLORER_REPORT.md` |
| Developer/Fix | `DEVELOPER_REPORT.md` |
| QA | `QA_REPORT.md` |
| Reviewer | `REVIEW.md` |
| Documentation | `DOCUMENTATION_REPORT.md` |
| Finalize | `FINALIZE_VALIDATION.md`, `FINALIZE_REPORT.md` |
| PR wait/review | `PR_WAIT_REPORT.md`, `PR_REVIEW_REPORT.md` |
| Merge | `MERGE_REPORT.md` |

See [Workflow YAML Reference](./workflow-yaml-reference.md) for configuration details.

### Worktrees

Each dispatched task runs in its own git worktree. This isolates agent edits from your main checkout and from other agents. Avoid manually editing active worktrees unless you are intentionally intervening.

### Documentation Gate

Foreman workflows include a documentation phase before finalization. The documentation agent checks whether the task changed user behavior, commands, workflows, prompts, setup, troubleshooting, or operator expectations. It updates relevant docs or records why no doc update was needed in `DOCUMENTATION_REPORT.md`.

Docs that must be considered for every fix or feature:

- `CLAUDE.md`
- `AGENTS.md`
- `README.md`
- `docs/user-guide.md`
- `docs/cli-reference.md`

## Day-to-Day Workflow

### 1. Start or Check the Daemon

Foreman uses PostgreSQL and usually runs through the daemon for shared project state.

```bash
foreman daemon status
foreman daemon start
foreman doctor
```

If commands report daemon or database issues, run `foreman doctor` and check [Troubleshooting](./troubleshooting.md).

### 2. Create a Task

Write a task with enough context for an agent to execute without guessing.

```bash
foreman task create \
  --title "Add cooldown retry for transient CLI review failures" \
  --type feature \
  --priority high \
  --description "When CodeRabbit reports a transient rate limit, schedule retry after cooldown instead of terminal failure."
```

You can also generate task(s) from a natural-language description (or a file path) with LLM parsing:

```bash
foreman task create --from-text "Fix the login timeout bug"
foreman task create --from-text docs/issue.md --dry-run
```

Good task descriptions include:

- Problem statement
- Expected behavior
- Constraints and non-goals
- Acceptance criteria
- Known files or commands, if relevant

### 3. Approve the Task

Tasks usually start in backlog. Approve when ready for dispatch.

```bash
foreman task approve <task-id>
```

### 4. Dispatch Work

```bash
foreman run --project my-project
```

Useful variants:

```bash
foreman run --bead <task-id>      # Dispatch one task
foreman run --max-agents 2        # Limit concurrency
foreman run --dry-run             # Preview dispatch
foreman run --no-watch            # Dispatch and exit
foreman run --workflow quick      # Use the quick workflow (no explorer/reviewer phases)
```

### 5. Monitor Progress

```bash
foreman status
foreman board
foreman watch
foreman logs <run-id>
foreman attach <run-id>
```

Use `foreman board` for kanban-style task triage. Use `foreman status` or `foreman watch` when you need execution health and active run state. To detect and reset stuck runs, use `foreman reset --detect-stuck`.

### 6. Triage Failures

Failed, stuck, blocked, conflict, and review statuses appear as needs-attention work. Start with artifacts before retrying.

Recommended order:

1. Read the latest pipeline report.
2. Read the failed phase report.
3. Identify whether the failure is transient, implementation-related, merge-related, or infrastructure-related.
4. Reset or retry only after the cause is understood.

```bash
foreman logs <run-id>
foreman reset --bead <task-id> --dry-run
foreman retry <task-id> --dispatch
```

Avoid mass retrying unless failures are known transient and the root cause is external.

### 7. Review and Merge

Auto-merge workflows create PRs, wait for PR checks/review, and merge through the configured merge phase. If merge fails, inspect `MERGE_REPORT.md` and any PR review artifacts.

```bash
foreman merge
foreman pr
```

## Operating the Board

`foreman board` is the primary interactive task board.

Common keys:

| Key | Action |
|-----|--------|
| `h` / `l` | Move between columns |
| `j` / `k` | Move within a column |
| `Enter` | Show task details |
| `r` | Refresh board from store |
| `R` | Mark selected task ready |
| `s` / `S` | Cycle status forward/backward |
| `c` / `C` | Close task |
| `e` / `E` | Edit task in editor |
| `n` | Create task |
| `?` | Help |
| `q` | Quit |

The board also monitors agent inbox updates. When a new inbox message arrives for a run, the board reloads only the task tied to that run and moves that card if its status changed; it does not refresh the entire board. Press `r` for a full manual refresh. The header shows an animated `refreshing…` indicator while full reload is in progress, then a `refreshed <time>` marker when the latest event-driven or manual update finishes. For exact options and keybindings, see [CLI Reference](./cli-reference.md#foreman-board).

## Retry and Reset Guidance

Use retry/reset surgically.

- Use `foreman retry <task-id> --dispatch` when the latest failure is safe to rerun.
- Use `foreman reset --bead <task-id>` to clear failed/stuck run state and make the task retryable.
- Use `--dry-run` before destructive cleanup.
- Do not reset active work with uncommitted controller changes unless those changes are committed or exported.

Transient failures include provider rate limits, temporary network failures, and unavailable external CLIs. Implementation failures should route back through developer/remediation phases instead of blind retry.

### Direct Task Execution with `foreman run task`

For debugging, recovery, and manual reruns where the task may be in any state (failed, closed, in-progress, backlog, etc.), use `foreman run task`:

```bash
foreman run task <task-id> <workflow-path> [options]
```

**Key behaviors:**

- **Bypasses state gating** — runs regardless of task status (ready, backlog, closed, failed, etc.)
- **Preserves safety mechanisms** — worktree and run locking still apply
- **Explicit workflow** — specify the workflow as a positional argument (not via `--workflow` flag)
- **Suitable for:**
  - Re-running a completed/closed task with a different workflow
  - Testing a new workflow against an existing task
  - Debugging by running a subset of phases
  - Recovery scenarios where the task state doesn't reflect the desired action

**Common uses:**

```bash
# Run a closed task with the default task workflow
foreman run task foreman-12345 task --project my-project --no-watch

# Run with a custom workflow path
foreman run task foreman-12345 ~/.foreman/workflows/custom.yaml --target-branch main

# Dry run to preview without executing
foreman run task foreman-12345 task --dry-run

# Run with a specific model override
foreman run task foreman-12345 task --model anthropic/claude-opus-4-6
```

**When to use `foreman run task` vs `foreman run --task`:**

| Command | State gating | Workflow selection | Typical use |
|---------|--------------|--------------------|-------------|
| `foreman run --task <id>` | Yes (task must be `ready`) | `--workflow` flag | Normal dispatch |
| `foreman run task <id> <workflow>` | No (any state) | Positional argument | Debug, recovery, testing |

## Documentation Expectations

Every user-visible change should update docs in the same task. Examples:

| Change | Docs to consider |
|--------|------------------|
| New command or flag | `docs/cli-reference.md`, `docs/user-guide.md`, `README.md` |
| Workflow YAML option | `docs/workflow-yaml-reference.md`, `docs/user-guide.md` |
| Agent behavior/prompt contract | `CLAUDE.md`, `AGENTS.md`, `docs/user-guide.md` |
| Setup/install behavior | `README.md`, `docs/user-guide.md`, `docs/troubleshooting.md` |
| Operational failure mode | `docs/user-guide.md`, `docs/troubleshooting.md` |

If no docs need updating, `DOCUMENTATION_REPORT.md` must explain why.

## Safety Rules

- Keep the controller workspace clean before rerunning important tasks.
- Commit or patch-export important local changes before reset/cleanup.
- Prefer targeted retries over bulk retries.
- Inspect reports before changing task state.
- Do not manually mutate active worktrees unless you intend to take ownership of that run.
- Keep workflow changes synchronized between bundled defaults and active project overrides when both are in use.

## Troubleshooting Quick Links

- Command syntax: [CLI Reference](./cli-reference.md)
- Workflow config: [Workflow YAML Reference](./workflow-yaml-reference.md)
- VCS backends: [VCS Configuration Guide](./guides/vcs-configuration.md)
- Troubleshooting: [Troubleshooting Guide](./troubleshooting.md)
