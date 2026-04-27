# Pipeline Report — foreman-ae63b

**Run ID:** `a664ddb4-4b76-43eb-b179-ca004793012a`
**Workflow:** `bug`
**Workflow Path:** `/Users/ldangelo/.foreman/workflows/bug.yaml`
**Target Branch:** `main`
**VCS Branch:** `foreman/foreman-ae63b`
**Generated:** 2026-04-27T20:48:21.105Z
**Status:** IN_PROGRESS

## Summary

| Metric | Value |
|--------|-------|
| Phases completed | 1 |
| Total cost | $0.0757 |
| Total turns | 33 |
| Total tool calls | 41 |
| Total duration | 129.5s |

## Phase Results

| Phase | Type | Status | Duration | Cost | Turns | Artifact | Trace | Error |
|-------|------|--------|----------|------|-------|----------|-------|--------|
| `fix` | command | pass | 129.5s | $0.0757 | 33 turns | DEVELOPER_REPORT.md (missing) | `docs/reports/foreman-ae63b/FIX_TRACE.json` | |

## Phase Inputs

### fix

- Type: command
- Input: `/skill:ensemble-fix-issue Fix foreman status --all active agent reporting Tasks (All Projects)
  Total:       31
  Ready:       13
  In Progress: 3
  Completed:   15
  Blocked:     0

Summary (All Projects)
  Active Agents: 5

Projects: task-daemon-test-mohbt8g6, task-daemon-test-mohbo2my, task-daemon-test-mogjkhpk, task-daemon-test-mogj5lrc, task-daemon-test-mogj38hr, task-daemon-test-mogiwj6w, task-daemon-test-mogiuje5, task-daemon-test-mogipytr, task-daemon-test-mogina4v, task-daemon-test-modbchae, task-daemon-test-mod9tr41, task-daemon-test-mod9hi14, task-daemon-test-mod9fmwk, task-daemon-test-mod9ez4t, task-daemon-test-mod9djs0, task-daemon-test, foreman, ensemble reports no running agents while Project Status

Tasks
  Total:       18
  Ready:       0
  In Progress: 3
  Completed:   15
  Blocked:     0
  Success Rate (24h): -- (daemon metrics pending)

Active Agents
▶ foreman-ac8dd RUNNING 62h 23m  foreman/foreman-ac8dd

▶ foreman-0207c RUNNING 62h 17m  foreman/foreman-0207c

▶ foreman-0ade6 RUNNING 59h 2m  foreman/foreman-0ade6

▶ foreman-cbfe7 RUNNING 58h 51m  foreman/foreman-cbfe7

▶ foreman-d5543 RUNNING 58h 46m  foreman/foreman-d5543 shows running agents for the same registered project. Investigate the all-project status aggregation path, compare it to the per-project daemon-backed active run query, and make the aggregate view report active agents consistently.`
- Trace: `docs/reports/foreman-ae63b/FIX_TRACE.json`
- Command honored: no
- Warning: Expected artifact missing: DEVELOPER_REPORT.md
- Warning: Command uses legacy slash syntax; runtime may treat it as plain prompt text
- Warning: No strong evidence that the command-phase workflow was honored

## Warnings

- Missing phase artifacts: fix -> DEVELOPER_REPORT.md
- Command phases without strong execution evidence: fix
- fix: Expected artifact missing: DEVELOPER_REPORT.md
- fix: Command uses legacy slash syntax; runtime may treat it as plain prompt text
- fix: No strong evidence that the command-phase workflow was honored

## Files Changed

- `/Users/ldangelo/Development/Fortium/foreman/src/cli/commands/status.ts`