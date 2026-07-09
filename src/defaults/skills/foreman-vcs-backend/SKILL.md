---
name: foreman-vcs-backend
description: "Use when changing Foreman's Git/Jujutsu support, VcsBackend abstraction, worktree/workspace handling, finalize/rebase/merge/push commands, or workflow/project VCS configuration."
---

# Foreman VCS Backend

## When to Use

Use this skill for changes in `src/lib/vcs/**`, VCS config in `src/lib/project-config.ts`, dispatcher/worker backend resolution, finalize/rebase/merge paths, PR/merge code that interacts with branches/worktrees/workspaces.

## Abstraction Rule

- Orchestration code uses `VcsBackend`; no direct `git` or `jj` shell calls outside documented allowed locations and backend implementations.
- For new VCS behavior, add/extend interface methods and both `GitBackend` and `JujutsuBackend` as needed.

## Resolution Precedence

- Workflow `vcs.backend` overrides `.foreman/config.yaml` project VCS config; project config overrides auto-detection; `.jj` takes precedence over `.git` in auto-detection.
- Preserve `FOREMAN_VCS_BACKEND` propagation from dispatcher to worker so jj workers do not silently fall back to git.

## Git/Jujutsu Vocabulary

- Git branch maps to jj bookmark; git worktree maps to jj workspace; staging may be no-op for jj; finalize commands are backend-specific.

## Verification

- Target VCS unit/static tests (`src/lib/vcs/**/__tests__`) and any dispatcher/finalize tests touched by the change.
