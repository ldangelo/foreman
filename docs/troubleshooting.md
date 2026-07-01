# Troubleshooting Guide

Common problems, their causes, and step-by-step solutions for Foreman pipelines.

---

## Quick Diagnostics

Before diving into specific issues, run these commands to understand the current state:

```bash
foreman status                    # Overview: tasks, agents, costs
foreman doctor                    # Health checks (br, DB, prompts)
foreman inbox --all --watch       # Live mail stream across all runs
foreman debug <task-id>           # AI-powered deep-dive on a specific task
foreman debug <task-id> --raw     # Raw artifacts without AI analysis
```

> **Note:** `<task-id>` is the primary identifier. `--bead` is accepted as a
> backward-compatible alias throughout the CLI.

---

## Elixir Backend Migration Issues

The TRD-2026-014 backend migration uses a three-part runtime: the Node CLI sends authenticated JSON commands/reads, the Elixir server owns durable events/projections/recovery/audits, and Node/Pi workers execute phases while streaming ordered events back to Elixir.

### `foreman server doctor` reports projection lag

**Symptoms:** status/watch/debug views look stale, or doctor/metrics reports non-zero projection lag.

**Diagnosis:**
```bash
foreman server doctor
# If auth is configured:
FOREMAN_SERVER_AUTH_TOKEN=... foreman server doctor
```

**How to reason about it:**
1. The event store is the source of truth. Confirm the expected event exists (`RunStarted`, `PhaseCompleted`, `WorkerRestarted`, `AuthorizationChecked`, etc.).
2. Projections are rebuildable read models. If the event exists but the view is stale, check projection lag and rebuild/restart projections.
3. Recovery is observation-first. Look for `ExternalWorkerObserved` before resolution events such as `WorkerReattached`, `WorkerRestarted`, or `NeedsOperator`.

### Debug timeline shows an anomaly

**Symptoms:** a run is completed but still appears active, a phase completes before it starts, or a worker event sequence looks inconsistent.

**Diagnosis:**
```bash
# Authenticated endpoint if FOREMAN_SERVER_AUTH_TOKEN is configured
curl -H "Authorization: Bearer $FOREMAN_SERVER_AUTH_TOKEN" \
  http://127.0.0.1:4766/api/v1/runs/<run-id>/debug?view=raw
```

The debug timeline identifies the first inconsistent transition. Use that event as the root cause, then inspect adjacent worker heartbeat/log/artifact events. Secret values are redacted from events, projections, logs, and debug output; worker start events keep only redacted env values and key metadata.

### Old command spelling still works but warns

Deprecated aliases are hidden from help and print replacements when used:

| Deprecated | Use instead |
|------------|-------------|
| `foreman dashboard` | `foreman watch` |
| `foreman bead` | Removed; use structured `foreman task create --title ...` |
| `foreman purge-logs` | `foreman purge logs` |
| `foreman purge-zombie-runs` | `foreman purge runs` |
| `--skip-explore` / `--skip-review` | `--workflow quick` or a custom workflow |

Legacy TypeScript delegation was removed after the Elixir cutover. Operator commands now either use Elixir-backed workflows or report removal with replacement guidance.

---

## Agent Issues

### Agent stuck — no progress for 10+ minutes

**Symptoms:** `foreman status` shows an agent running but turns/tools/cost haven't increased.

**Diagnosis:**
```bash
foreman status                    # Check turns and lastActivity timestamp
foreman attach <task-id> --follow # Tail the agent log
foreman inbox --task <task-id>    # Check for error mail and lifecycle events
```

**Common causes and fixes:**

1. **Rate limited** — The AI provider or CodeRabbit CLI throttled requests. Foreman retries CodeRabbit CLI rate limits with short backoff and then marks the run retryable instead of looping back through developer/QA.
   ```bash
   # Wait for rate limit to reset, then retry through Elixir-backed recovery
   foreman retry <task-id> --dispatch
   ```

2. **Agent in a loop** — The agent is retrying a failing operation.
   ```bash
   foreman attach <task-id> --follow  # Check what it's doing
   foreman debug <task-id>            # Analyze what went wrong
   foreman retry <task-id> --dispatch # Retry through Elixir-backed recovery
   ```

3. **Pi SDK session hung** — The in-process agent session stopped responding.
   ```bash
   foreman debug <task-id>            # Inspect failure context
   foreman retry <task-id> --dispatch # Retry through Elixir-backed recovery
   ```

### Agent crashes immediately on startup

**Symptoms:** Bead dispatches but immediately shows as failed. No tool calls, no cost.

**Diagnosis:**
```bash
# Check the agent worker error log
ls -t ~/.foreman/logs/*.err | head -1 | xargs tail -30

# Check for syntax errors in agent-worker.ts
cat ~/.foreman/logs/<runId>.err | grep "SyntaxError\|Error\|Cannot find"
```

**Common causes:**

1. **Missing export in TypeScript** — A merged task broke an import.
   ```bash
   npx tsc --noEmit                # Find the error
   # Fix the TypeScript error, then:
   npm run build
   foreman retry <task-id> --dispatch
   ```

2. **Pi SDK auth failure** — API key not found.
   ```bash
   # Check Pi auth
   cat ~/.pi/agent/auth.json | head -5
   # Or set the env var
   export ANTHROPIC_API_KEY=sk-ant-...
   ```

3. **Node.js version mismatch** — Requires Node.js 20+.
   ```bash
   node --version                  # Must be >= 20
   ```

### Agent completes but work isn't committed

**Symptoms:** Pipeline shows COMPLETED but `git log` on the branch has no new commits. The worktree has uncommitted changes.

**Diagnosis:**
```bash
cd ../.foreman-worktrees/<repo-name>/<task-id>
git status                        # Check for uncommitted files
git diff --stat                   # See what changed but wasn't committed
```

**Cause:** The finalize agent ran `git add` from the wrong directory.

**Fix:** This was addressed by adding `cd {{worktreePath}}` to the finalize prompt. If you're on an older version:
```bash
# Manually commit from the worktree
cd ../.foreman-worktrees/<repo-name>/<task-id>
git add -A
git commit -m "Manual commit for <task-id>"
git push -u origin foreman/<task-id>
foreman merge <task-id>
```

### Task won't dispatch because it's not in "ready" status

**Symptoms:** `foreman run --task <id>` fails with "task is not ready" or similar message.

**Cause:** The task status doesn't allow normal dispatch. Common reasons:
- Task was closed after a previous run
- Task failed and was marked as `failed`
- Task was manually set to a non-ready status

**Fix:** Operator use of `foreman run task` was removed after the Elixir cutover. Use `foreman retry <task-id>` for recovery, or update the task/workflow through Elixir-backed commands before the next scheduler tick.

### Testing a new workflow on an existing task

**Symptoms:** You want to test a custom workflow or different phase configuration on a task without changing its status.

**Fix:** Operator use of `foreman run task` was removed after the Elixir cutover. Test workflow changes through the normal Elixir scheduler path on a disposable task/project.

This is useful for validating phase configurations before applying them to production tasks.

---

## Merge Issues

### Branch won't merge — "pr-created" status instead of "merged"

**Symptoms:** `foreman status` shows tasks completed but they never merge. Run status shows `pr-created`.

**Diagnosis:**
```bash
# Check what autoMerge found
grep "autoMerge\|merge.*fail\|conflict" ~/.foreman/logs/<runId>.err

# Try the merge manually to see the error
git merge foreman/<task-id> --no-commit --no-ff
git merge --abort                 # Clean up
```

**Common causes:**

1. **Merge conflict on diagnostic files** — SESSION_LOG.md or RUN_LOG.md conflict.
   ```bash
   # These files should be excluded from commits. Check:
   grep "SESSION_LOG\|RUN_LOG" .gitignore

   # If missing, add them:
   echo "SESSION_LOG.md" >> .gitignore
   echo "RUN_LOG.md" >> .gitignore

   # Force merge, dropping the conflicting files
   git merge foreman/<task-id> --no-edit
   # If conflict: git rm SESSION_LOG.md && git commit --no-edit
   ```

2. **Branch diverged from target** — Other tasks merged to dev while this one was running.
   ```bash
   # Rebase the branch onto latest dev
   cd ../.foreman-worktrees/<repo-name>/<task-id>
   git fetch origin
   git rebase origin/dev
   git push -f origin foreman/<task-id>

   # Then merge
   cd ../..
   foreman merge <task-id>
   ```

3. **Test failures during merge** — The refinery runs tests and they fail.
   ```bash
   # Check which tests fail on the merge result
   git merge foreman/<task-id> --no-commit --no-ff
   npm test
   # Fix failures, then:
   git commit --no-edit
   git push
   ```

### autoMerge returns "failed=1"

**Symptoms:** Agent logs show `[FINALIZE] autoMerge result: merged=0 conflicts=0 failed=1`.

**Diagnosis:**
```bash
grep "autoMerge\|no-completed-run" ~/.foreman/logs/<runId>.err
```

**Cause:** The run wasn't marked as "completed" in the database before autoMerge triggered (race condition).

**Fix:** This was fixed by reordering `store.updateRun(status: "completed")` before the autoMerge call. If on an older version:
```bash
foreman merge                     # Trigger manual merge
```

### Infinite retry loop on sentinel tasks

**Symptoms:** A task keeps getting dispatched, completing, failing to merge, resetting to open, and dispatching again.

**Diagnosis:**
```bash
# Count runs for the task
foreman debug <task-id> --raw | grep "Run ID"

# Check why merge fails
grep "merge.*fail\|test.*fail" ~/.foreman/logs/<latest-runId>.err
```

**Cause:** The pipeline fixes tests on the branch, but autoMerge runs the full test suite against the merge result — which includes pre-existing failures on dev.

**Fix:**
```bash
# Inspect and move forward through Elixir-backed recovery
foreman debug <task-id>
foreman retry <task-id> --dispatch

# Manually merge if the fix is good
git merge foreman/<task-id> --no-edit
npm test                          # Verify
git push
```

---

## Worktree Issues

### "Rebase failed due to unstaged changes" loop

**Symptoms:** `foreman run` keeps retrying dispatch with "Rebase failed due to unstaged changes" error.

**Diagnosis:**
```bash
# Check the worktree state
cd ../.foreman-worktrees/<repo-name>/<seedId>
git status
```

**Fix:**
```bash
# Use Foreman commands instead of manual rm -rf
foreman worktree clean --dry-run  # Preview what will be removed
foreman worktree clean            # Remove the worktree and prune stale refs
foreman retry <task-id> --dispatch # Retry through Elixir-backed recovery
```

### "index.lock: File exists" error

**Symptoms:** Git operations fail with "Unable to create index.lock: File exists".

**Cause:** A crashed git process left a lock file behind.

**Fix:**
```bash
rm -f .git/index.lock
# Also check worktrees (emergency only — prefer foreman worktree clean):
rm -f ../.foreman-worktrees/<repo-name>/<seedId>/.git/index.lock 2>/dev/null
```

### Orphaned worktrees accumulating

**Symptoms:** Disk usage growing, the external Foreman workspace root (`../.foreman-worktrees/<repo-name>/` by default) has many directories.

**Fix:**
```bash
foreman worktree list             # See all worktrees
foreman worktree clean            # Remove orphaned ones
foreman worktree clean --all      # Remove ALL (including active)
foreman worktree clean --dry-run  # Preview first
```

### Daemon logs "skipped checkout sync" for a registered project

**Symptoms:** Daemon log shows a one-time warning that checkout sync was skipped because the project is on a non-default branch or has uncommitted changes.

**Cause:** This is intentional. The daemon refreshes registered project checkouts on its dispatch loop, but it never switches branches out from under you or mutates a dirty working tree. While you are on a feature branch it only fetches (and fast-forwards the local default-branch ref); normal sync resumes when the checkout returns to the default branch.

**Fix:** Nothing to fix — finish your work and switch back to the default branch, or ignore the warning. Worktree-based agent dispatch is unaffected (worktrees are created from `origin/<default-branch>`, not your checkout).

---

## Database Issues

### "br" commands fail with merge conflict in issues.jsonl

**Symptoms:** `br show`, `br ready`, etc. fail with "Merge conflict markers detected in issues.jsonl".

**Fix:**
```bash
# Option 1: Resolve conflicts keeping our version
python3 -c "
import re
with open('.beads/issues.jsonl') as f:
    content = f.read()
result = re.sub(
    r'<<<<<<< .*?\n(.*?\n)(?:\|\|\|\|\|\|\| .*?\n(?:.*?\n)*?)?=======\n(?:.*?\n)*?>>>>>>> .*?\n',
    r'\1', content, flags=re.DOTALL)
with open('.beads/issues.jsonl', 'w') as f:
    f.write(result)
"

# Option 2: Force sync from DB (DB is source of truth)
br sync --force

# Verify
br doctor
```

### Task stuck in wrong status (IN_PROGRESS but actually merged)

**Symptoms:** `br list` shows tasks as IN_PROGRESS but they're already on dev.

**Diagnosis:**
```bash
# Check if the task's work is on dev
git log --oneline dev | grep <task-id>

# Check br status
br show <task-id>
```

**Fix:**
```bash
# Close tasks that are already merged in the legacy beads store
br close <task-id> --force --reason "Already merged to dev"

# Or run doctor to reconcile
foreman doctor --fix
```

### DB and JSONL counts differ

**Symptoms:** `br doctor` warns "DB and JSONL counts differ".

**Fix:**
```bash
br sync --force                   # Re-import from JSONL
br sync --flush-only              # Then re-export from DB
br doctor                         # Verify
```

---

## Cost Issues

### Agent burning excessive budget

**Symptoms:** A phase is accumulating high cost ($5+) without completing.

**Diagnosis:**
```bash
foreman status                    # Check cost and turns per phase
foreman attach <task-id> --follow # Watch what the agent is doing
```

**Common causes:**

1. **Agent in fix-test-fix loop** — Developer keeps fixing, QA keeps failing.
   ```bash
   foreman debug <task-id>         # Analyze what went wrong
   foreman retry <task-id> --dispatch
   ```

2. **Agent exploring too broadly** — Explorer reading too many files.
   ```bash
   # Reduce maxTurns in the workflow YAML
   # explorer.maxTurns: 15 (instead of 30)
   ```

3. **Wrong model for the task** — Using opus for simple work.
   ```bash
   # Check the workflow YAML models map
   cat ~/.foreman/workflows/default.yaml | grep -A 3 models
   ```

### Smoke test costs too much

**Symptoms:** Smoke tests cost $0.30+ for doing nothing.

**Cause:** The system prompt (~10K tokens) is sent fresh to each phase, causing prompt cache writes.

**Fix:** Use haiku for all smoke phases and keep maxTurns low:
```yaml
# ~/.foreman/workflows/smoke.yaml
phases:
  - name: explorer
    models:
      default: haiku
    maxTurns: 5
```

---

## Mail Issues

### No messages appearing in inbox

**Diagnosis:**
```bash
# Check if messages exist in the DB
foreman inbox --all --limit 100

# Check specific task
foreman inbox --task <task-id>

# Check if the mail client initialized
grep "agent-mail" ~/.foreman/logs/<runId>.err
```

**Common causes:**

1. **Wrong run ID** — The inbox defaults to the latest run, which might not be the one you expect.
   ```bash
   foreman inbox --task <task-id>
   ```

2. **Agent Mail client failed to initialize** — Check logs for errors.
   ```bash
   grep "PostgresMailClient\|mail.*fail" ~/.foreman/logs/<runId>.err
   ```

### Duplicate lifecycle mail (phase-started/phase-complete sent twice)

**Cause:** Both the orchestrator (pipeline-executor) and the agent (via send_mail tool) send lifecycle mail. This is expected during the transition period.

**Fix:** Update prompts to remove lifecycle mail instructions — the orchestrator handles it. Error-only mail instructions should remain in prompts.

---

## Setup Cache Issues

### Cache miss on every worktree despite same dependencies

**Diagnosis:**
```bash
# Check if cache exists
ls .foreman/setup-cache/

# Check the hash
md5 package-lock.json             # Compare with cache dir names
```

**Common causes:**

1. **Lock file changes between runs** — Even a timestamp change invalidates the cache.
   ```bash
   # Check if package-lock.json is being modified
   git diff package-lock.json
   ```

2. **setupCache not configured** — Check the workflow YAML:
   ```bash
   grep -A 2 setupCache ~/.foreman/workflows/default.yaml
   ```

### Symlink errors after cache populated

**Symptoms:** Agents fail with "ENOENT" errors accessing node_modules.

**Cause:** The symlink target was deleted or moved.

**Fix:**
```bash
# Clear the cache and let it rebuild
rm -rf .foreman/setup-cache/
foreman retry <task-id> --dispatch # Retry through Elixir-backed recovery
```

---

## Getting Help

```bash
foreman doctor                    # Automated health checks
foreman doctor --dry-run          # Preview safe stale run/worktree cleanup
foreman doctor --fix              # Auto-fix safe retryable/stale/zombie runs, prompts/workflows, and merged/orphaned worktrees
foreman debug <task-id>           # AI analysis of what went wrong
foreman debug <task-id> --raw     # All artifacts without AI cost

# Report issues
# https://github.com/ldangelo/foreman/issues
```
