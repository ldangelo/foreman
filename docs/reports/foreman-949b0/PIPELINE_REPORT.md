# Pipeline Report — foreman-949b0

**Run ID:** `83a697f7-cc8e-40fc-8127-14f92553c39c`
**Workflow:** `feature`
**Workflow Path:** `/Users/ldangelo/.foreman/workflows/feature.yaml`
**Target Branch:** `main`
**VCS Branch:** `foreman/foreman-949b0`
**Generated:** 2026-06-03T18:16:54.472Z
**Status:** IN_PROGRESS

## Summary

| Metric | Value |
|--------|-------|
| Phases completed | 4 |
| Total cost | $0.4309 |
| Total turns | 101 |
| Total tool calls | 445 |
| Total duration | 1193.6s |

## Phase Results

| Phase | Type | Status | Duration | Cost | Turns | Artifact | Trace | Error |
|-------|------|--------|----------|------|-------|----------|-------|--------|
| `explorer` | prompt | pass | 118.0s | $0.1047 | 26 turns | EXPLORER_REPORT.md (present) | `docs/reports/foreman-949b0/EXPLORER_TRACE.json` | |
| `developer` | prompt | pass | 706.0s | $0.2343 | 41 turns | DEVELOPER_REPORT.md (missing) | `docs/reports/foreman-949b0/DEVELOPER_TRACE.json` | |
| `qa` | prompt | pass | 277.4s | $0.0400 | 17 turns | QA_REPORT.md (missing) | `docs/reports/foreman-949b0/QA_TRACE.json` | |
| `reviewer` | prompt | pass | 92.3s | $0.0519 | 17 turns | REVIEW.md (present) | `docs/reports/foreman-949b0/REVIEWER_TRACE.json` | |

## Phase Inputs

## Warnings

- Missing phase artifacts: developer -> DEVELOPER_REPORT.md, qa -> QA_REPORT.md
- developer: Blocked git commit during non-finalize/pr-review phase
- Long-running phases (>10min): developer (12min)

## Files Changed

- `/Users	ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/EXPLORER_REPORT.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/EXPLORER_REPORT.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/SESSION_LOG.md`
- `src/defaults/workflows/pr-review-workflow.yaml`
- `src/defaults/prompts/default/create-pr.md`
- `src/defaults/prompts/default/pr-wait.md`
- `src/defaults/prompts/default/prepare-pr-review.md`
- `src/defaults/prompts/default/pr-review.md`
- `docs/reports/foreman-949b0/DEVELOPER_REPORT.md`
- `SESSION_LOG.md`
- `docs/reports/foreman-949b0/QA_REPORT.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/REVIEW.md`