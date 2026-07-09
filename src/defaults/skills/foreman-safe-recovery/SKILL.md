---
name: foreman-safe-recovery
description: "Use when deciding between Foreman retry, reset, doctor --fix, worktree clean, abandon, or clean-state for failed/stuck/obsolete runs, branches, worktrees, or PRs."
---

# Foreman Safe Recovery

## When to Use

Use this skill for failed/stuck tasks, obsolete work, stale worktrees, retryable failures, branch cleanup, stale runtime assets, or operator cleanup.

## Recovery Decision Tree

1. Diagnose first with `foreman-pipeline-diagnosis` order.
2. Use dry-run options before destructive commands when available.
3. Use `foreman retry <task-id> --dispatch` for understood retryable failures.
4. Use `foreman reset <task-id> --dry-run` before reset; add `--keep-worktree` when preserving uncommitted investigation matters.
5. Use `foreman doctor --fix` for safe automated stale prompt/workflow/skill/worktree checks/fixes.
6. Use `foreman worktree clean` instead of manual `rm -rf` for stale worktrees.
7. Use `foreman abandon <task-id>` for obsolete work that should not land.
8. Use `foreman clean-state --dry-run` before `--force` for state cleanup.

## Evidence to Record

Record the task ID, run ID, failed phase, current status, root cause classification, command chosen, dry-run result, and reason string.

## Guardrails

- Do not reset/abandon merged work as routine cleanup.
- Do not delete branches/worktrees when important work exists only in working copy.
- Do not use reset to hide a real implementation or verification failure.
