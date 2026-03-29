# Resolve Rebase Conflict — Troubleshooter Skill

You have received a `rebase-conflict` mail indicating that a mid-pipeline rebase onto **{{rebaseTarget}}** encountered conflicts. The rebase has already been **aborted** — the worktree is clean. Your job is to manually integrate the upstream changes and signal the pipeline to resume.

## Context from mail

- **Run ID:** {{runId}}
- **Worktree:** {{worktreePath}}
- **Rebase target:** {{rebaseTarget}}
- **Conflicting files:** {{conflictingFiles}}
- **Upstream diff:**
```
{{upstreamDiff}}
```

## Step 1: Understand what changed upstream

Read the upstream diff carefully. Identify:
- Which files were added, modified, or deleted on the upstream branch
- What the intent of each change is (feature, refactor, bug fix, config change)

## Step 2: Inspect the developer's work

```bash
cd {{worktreePath}}
git log --oneline -5
git diff HEAD origin/dev --stat 2>/dev/null || git diff HEAD~1 --stat
```

Read the files that were listed as conflicting to understand:
- What the developer changed
- How those changes interact with the upstream diff

## Step 3: Manually apply upstream changes

Since the rebase was aborted, the worktree contains **only the developer's changes** — the upstream changes have NOT been applied. You need to manually apply the upstream changes that don't conflict:

1. For each file in the upstream diff that the developer did NOT touch: the diff has already been incorporated (it's on the base branch). No action needed.

2. For each **conflicting file** (both developer and upstream changed it):
   - Read the current file content (developer's version)
   - Review the upstream diff for that file
   - Manually merge the upstream changes into the developer's version
   - The goal: keep the developer's feature intact while incorporating upstream changes

```bash
# Read each conflicting file
cat {{worktreePath}}/<conflicting-file>
```

Edit the conflicting files to incorporate both sets of changes.

## Step 4: Run tests to verify

```bash
cd {{worktreePath}}
npm test 2>&1 | tail -30
```

If tests fail, fix them before proceeding. Do not signal resolution with failing tests.

## Step 5: Commit the merged result

```bash
cd {{worktreePath}}
git add -A
git reset HEAD SESSION_LOG.md 2>/dev/null || true
git commit -m "chore: integrate upstream changes from {{rebaseTarget}} (conflict resolution for {{runId}})"
```

## Step 6: Write CONFLICT_RESOLUTION.md

Document what you did:

```markdown
# Conflict Resolution: {{runId}}

## Rebase Target
{{rebaseTarget}}

## Conflicting Files
<list each file>

## Resolution Strategy
<explain what you did for each conflict>

## Outcome
RESOLVED — <brief description>
```

## Step 7: Signal pipeline resume

Call `signal_rebase_resolved` to notify the pipeline that the conflict has been resolved and it should resume from the developer phase:

```
signal_rebase_resolved(runId="{{runId}}", resumePhase="developer")
```

If you cannot resolve the conflict (too complex, unclear intent), call:
```
send_mail(to="foreman", subject="rebase-failed", body={"runId":"{{runId}}", "reason":"<brief explanation>", "conflictingFiles":{{conflictingFiles}}})
```
Then stop — do not signal_rebase_resolved.

## Guardrails

- **Do NOT run `git rebase`** — the rebase was already aborted; running it again without the upstream changes is wrong
- **Do NOT force-push** — the pipeline will handle the push after resuming
- **No scope creep** — only resolve the conflicts, don't refactor the developer's code
- **Max 2 resolution attempts** — if the second attempt fails, escalate to human via send_mail
