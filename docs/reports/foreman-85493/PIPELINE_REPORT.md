# Pipeline Report — foreman-85493

**Run ID:** `f87d5238-196f-415d-aa85-c3f10a93a0b0`
**Workflow:** `bug`
**Workflow Path:** `/Users/ldangelo/.foreman/workflows/bug.yaml`
**Target Branch:** `main`
**VCS Branch:** `foreman/foreman-85493`
**Generated:** 2026-04-30T00:15:02.242Z
**Status:** IN_PROGRESS

## Summary

| Metric | Value |
|--------|-------|
| Phases completed | 1 |
| Total cost | $2.1430 |
| Total turns | 73 |
| Total tool calls | 87 |
| Total duration | 844.9s |

## Phase Results

| Phase | Type | Status | Duration | Cost | Turns | Artifact | Trace | Error |
|-------|------|--------|----------|------|-------|----------|-------|--------|
| `fix` | command | pass | 844.9s | $2.1430 | 73 turns | DEVELOPER_REPORT.md (missing) | `docs/reports/foreman-85493/FIX_TRACE.json` | |

## Phase Inputs

### fix

- Type: command
- Input: `/skill:ensemble-fix-issue Show current PR on ticket list and track PR by ticket Native Foreman task version of bead bd-5oow. Ticket/list views should surface current PR state so operators can distinguish: no PR, open PR, merged historical PR for an older head, and PR/head mismatch. Acceptance: (1) task list output shows current PR state when a PR exists; (2) PR association is tied to current branch head/run, not just branch name; (3) stale merged PRs from older branch heads are distinguishable from current task state; (4) users can tell whether a failed task never created a PR or failed after PR creation.`
- Trace: `docs/reports/foreman-85493/FIX_TRACE.json`
- Command honored: no
- Warning: Blocked git commit during non-finalize phase
- Warning: Expected artifact missing: DEVELOPER_REPORT.md
- Warning: Command uses legacy slash syntax; runtime may treat it as plain prompt text
- Warning: No strong evidence that the command-phase workflow was honored

## Warnings

- Missing phase artifacts: fix -> DEVELOPER_REPORT.md
- Command phases without strong execution evidence: fix
- fix: Blocked git commit during non-finalize phase
- fix: Expected artifact missing: DEVELOPER_REPORT.md
- fix: Command uses legacy slash syntax; runtime may treat it as plain prompt text
- fix: No strong evidence that the command-phase workflow was honored
- Long-running phases (>10min): fix (14min)

## Files Changed

- `/Users/ldangelo/.foreman/worktrees/9c825a66-276b-4419-8594-219783b4cf4f/foreman-85493/src/lib/pr-state.ts`
- `/Users/ldangelo/.foreman/worktrees/9c825a66-276b-4419-8594-219783b4cf4f/foreman-85493/src/daemon/router.ts`
- `/Users/ldangelo/.foreman/worktrees/9c825a66-276b-4419-8594-219783b4cf4f/foreman-85493/src/lib/trpc-client.ts`
- `/Users/ldangelo/.foreman/worktrees/9c825a66-276b-4419-8594-219783b4cf4f/foreman-85493/src/cli/commands/task.ts`
- `/Users/ldangelo/.foreman/worktrees/9c825a66-276b-4419-8594-219783b4cf4f/foreman-85493/src/lib/vcs/__tests__/no-direct-git.test.ts`
- `/Users/ldangelo/.foreman/worktrees/9c825a66-276b-4419-8594-219783b4cf4f/foreman-85493/src/lib/vcs/__tests__/static-analysis.test.ts`