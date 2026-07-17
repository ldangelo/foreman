# RCA: Worktree Creation Failure (`foreman-f134d`)

## Summary

`foreman-f134d` failed at the first phase (explorer) because `git worktree add -b foreman/foreman-f134d` could not acquire a lock on `.git/config` — the branch already existed from a prior run, and `.git/config.lock` was present at the moment of creation.

## Root Cause

**Error:**
```text
Failed to create worktree: Command failed: git worktree add -b foreman/foreman-f134d ... origin/main
error: could not lock config file .git/config: File exists
error: unable to write upstream branch configuration
```

**Chain of events:**

1. A prior run of `foreman-f134d` already created branch `foreman/foreman-f134d` and pushed it to `parent` (self-reference remote)
2. That branch has 3 commits with divergent changes from main (`+195 -1985` lines across 26 files)
3. The current run tried `git worktree add -b foreman/foreman-f134d origin/main`
4. Git tried to create a new branch with that name, but the branch already existed
5. Simultaneously (or due to a stale lock), `.git/config.lock` was held, blocking the config write
6. Worktree creation aborted — no worktree directory was created

## Why "branch already exists" wasn't the visible error

`git worktree add -b foreman/foreman-f134d` attempts to create the branch reference first (in `.git/config`), then create the worktree directory. If `.git/config` is locked, the config write fails before git can emit the cleaner "branch already exists" error.

## Current State

- **Branch `foreman/foreman-f134d`**: exists on `parent` remote with 3 divergent commits
- **Worktree**: does not exist
- **`.git/config.lock`**: not present (transient lock cleared)
- **No lock files anywhere in `.git/`**

## Remediations

### Immediate (allow retry)
Delete the stale branch so the worktree creation can succeed on retry:

```bash
# Archive the branch first to preserve the 3 divergent commits before deletion
git tag archive/foreman-f134d foreman/foreman-f134d
# Then delete the local and remote branch
git branch -D foreman/foreman-f134d
git push parent --delete foreman/foreman-f134d
```

### Systemic improvements

1. **Pre-check before `git worktree add -b`**: The worktree creation logic should check if the branch exists before attempting to create it. If it exists, either reuse the existing worktree (if it exists) or fail fast with "branch exists — remove it first".

2. **Process-safe lock detection**: Before removing `.git/config.lock`, verify the lock is not owned by an active git process (e.g., check PID file, process table). If an active lock is detected, fail with clear recovery instructions instead of removing the lock.

3. **Branch cleanup on failed worktree**: If `git worktree add` fails after creating the worktree directory (but before completing), the partial worktree should be cleaned up.

## Action Items

- [ ] Tag/archive `foreman/foreman-f134d` to preserve divergent commits before deletion
- [ ] Delete `foreman/foreman-f134d` branch locally and from `parent` remote
- [ ] Retry `foreman-f134d` — worktree creation should succeed once branch is removed


<!-- Nitpicks addressed: process-safe lock detection added, summary revised to avoid asserting active lock -->