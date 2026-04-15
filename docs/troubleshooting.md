# Troubleshooting Guide

Common problems, their causes, and step-by-step solutions for Foreman pipelines.

---

## Quick Diagnostics

Before diving into specific issues, run these commands to understand the current state:

```bash
foreman status                    # Overview: tasks, agents, costs
foreman doctor                    # Health checks (br, DB, prompts)
foreman inbox --all --watch       # Live mail stream across all runs
foreman debug <task-or-bead-id>           # AI-powered deep-dive on a specific task
foreman debug <task-or-bead-id> --raw     # Raw artifacts without AI analysis
```

---

## Agent Issues

### Agent stuck — no progress for 10+ minutes

**Symptoms:** `foreman status` shows an agent running but turns/tools/cost haven't increased.

**Diagnosis:**
```bash
foreman status                    # Check turns and lastActivity timestamp
foreman attach <bead-id> --follow # Tail the agent log
foreman inbox --bead <bead-id>    # Check for error mail
```

**Common causes and fixes:**

1. **Rate limited** — The AI provider throttled requests.
   ```bash
   # Wait for rate limit to reset, or stop and retry later
   foreman stop <bead-id>
   foreman retry <bead-id> --dispatch
   ```

2. **Agent in a loop** — The agent is retrying a failing operation.
   ```bash
   foreman attach <bead-id> --follow  # Check what it's doing
   foreman stop <bead-id>             # Kill it
   foreman reset --bead <bead-id>     # Reset to open
   ```

3. **Pi SDK session hung** — The in-process agent session stopped responding.
   ```bash
   foreman stop <bead-id> --force     # Force kill
   foreman reset --bead <bead-id>
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

1. **Missing export in TypeScript** — A merged bead broke an import.
   ```bash
   npx tsc --noEmit                # Find the error
   # Fix the TypeScript error, then:
   npm run build
   foreman retry <bead-id> --dispatch
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
cd ../.foreman-worktrees/<repo-name>/<bead-id>
git status                        # Check for uncommitted files
git diff --stat                   # See what changed but wasn't committed
```

**Cause:** The finalize agent ran `git add` from the wrong directory.

**Fix:** This was addressed by adding `cd {{worktreePath}}` to the finalize prompt. If you're on an older version:
```bash
# Manually commit from the worktree
cd ../.foreman-worktrees/<repo-name>/<bead-id>
git add -A
git commit -m "Manual commit for <bead-id>"
git push -u origin foreman/<bead-id>
foreman merge --bead <bead-id>
```

---

## Merge Issues

### Branch won't merge — "pr-created" status instead of "merged"

**Symptoms:** `foreman status` shows tasks completed but they never merge. Run status shows `pr-created`.

**Diagnosis:**
```bash
# Check what autoMerge found
grep "autoMerge\|merge.*fail\|conflict" ~/.foreman/logs/<runId>.err

# Try the merge manually to see the error
git merge foreman/<bead-id> --no-commit --no-ff
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
   git merge foreman/<bead-id> --no-edit
   # If conflict: git rm SESSION_LOG.md && git commit --no-edit
   ```

2. **Branch diverged from target** — Other tasks merged to dev while this one was running.
   ```bash
   # Rebase the branch onto latest dev
   cd ../.foreman-worktrees/<repo-name>/<bead-id>
   git fetch origin
   git rebase origin/dev
   git push -f origin foreman/<bead-id>

   # Then merge
   cd ../..
   foreman merge --bead <bead-id>
   ```

3. **Test failures during merge** — The refinery runs tests and they fail.
   ```bash
   # Check which tests fail on the merge result
   git merge foreman/<bead-id> --no-commit --no-ff
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
foreman debug <bead-id> --raw | grep "Run ID"

# Check why merge fails
grep "merge.*fail\|test.*fail" ~/.foreman/logs/<latest-runId>.err
```

**Cause:** The pipeline fixes tests on the branch, but autoMerge runs the full test suite against the merge result — which includes pre-existing failures on dev.

**Fix:**
```bash
# Stop the loop
foreman stop <bead-id>
br close <bead-id> --force --reason "Stopping retry loop"

# Manually merge if the fix is good
git merge foreman/<bead-id> --no-edit
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
foreman stop <bead-id>
foreman worktree clean --dry-run  # Preview what will be removed
foreman worktree clean            # Remove the worktree and prune stale refs
foreman reset --bead <bead-id>
foreman run --bead <bead-id>      # Fresh dispatch
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

### Bead stuck in wrong status (IN_PROGRESS but actually merged)

**Symptoms:** `br list` shows beads as IN_PROGRESS but they're already on dev.

**Diagnosis:**
```bash
# Check if the bead's work is on dev
git log --oneline dev | grep <bead-id>

# Check br status
br show <bead-id>
```

**Fix:**
```bash
# Close tasks that are already merged in the legacy beads store
br close <bead-id> --force --reason "Already merged to dev"

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
foreman attach <bead-id> --follow # Watch what the agent is doing
```

**Common causes:**

1. **Agent in fix-test-fix loop** — Developer keeps fixing, QA keeps failing.
   ```bash
   foreman stop <bead-id>
   foreman debug <bead-id>         # Analyze what went wrong
   ```

2. **Agent exploring too broadly** — Explorer reading too many files.
   ```bash
   # Reduce maxTurns in the workflow YAML
   # explorer.maxTurns: 15 (instead of 30)
   ```

3. **Wrong model for the task** — Using opus for simple work.
   ```bash
   # Check the workflow YAML models map
   cat .foreman/workflows/default.yaml | grep -A 3 models
   ```

### Smoke test costs too much

**Symptoms:** Smoke tests cost $0.30+ for doing nothing.

**Cause:** The system prompt (~10K tokens) is sent fresh to each phase, causing prompt cache writes.

**Fix:** Use haiku for all smoke phases and keep maxTurns low:
```yaml
# .foreman/workflows/smoke.yaml
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
foreman inbox --bead <bead-id>

# Check if the mail client initialized
grep "agent-mail" ~/.foreman/logs/<runId>.err
```

**Common causes:**

1. **Wrong run ID** — The inbox defaults to the latest run, which might not be the one you expect.
   ```bash
   foreman inbox --bead <bead-id>  # Use task/bead ID instead of run ID
   ```

2. **Agent Mail client failed to initialize** — Check logs for errors.
   ```bash
   grep "SqliteMailClient\|mail.*fail" ~/.foreman/logs/<runId>.err
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
   grep -A 2 setupCache .foreman/workflows/default.yaml
   ```

### Symlink errors after cache populated

**Symptoms:** Agents fail with "ENOENT" errors accessing node_modules.

**Cause:** The symlink target was deleted or moved.

**Fix:**
```bash
# Clear the cache and let it rebuild
rm -rf .foreman/setup-cache/
foreman reset --bead <bead-id>
foreman run --bead <bead-id>
```

---

## Getting Help

```bash
foreman doctor                    # Automated health checks
foreman doctor --fix              # Auto-fix common issues
foreman debug <bead-id>           # AI analysis of what went wrong
foreman debug <bead-id> --raw     # All artifacts without AI cost

# Report issues
# https://github.com/ldangelo/foreman/issues
```
