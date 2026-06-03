# Pipeline Report — foreman-949b0

**Run ID:** `4effce23-48d4-480a-b1f7-f77a2714e650`
**Workflow:** `feature`
**Workflow Path:** `/Users/ldangelo/.foreman/workflows/feature.yaml`
**Target Branch:** `main`
**VCS Branch:** `foreman/foreman-949b0`
**Generated:** 2026-06-03T19:01:45.668Z
**Status:** IN_PROGRESS

## Summary

| Metric | Value |
|--------|-------|
| Phases completed | 7 |
| Total cost | $0.4466 |
| Total turns | 150 |
| Total tool calls | 1079 |
| Total duration | 1138.8s |

## Phase Results

| Phase | Type | Status | Duration | Cost | Turns | Artifact | Trace | Error |
|-------|------|--------|----------|------|-------|----------|-------|--------|
| `explorer` | prompt | pass | 145.8s | $0.0535 | 27 turns | EXPLORER_REPORT.md (present) | `docs/reports/foreman-949b0/EXPLORER_TRACE.json` | |
| `developer` | prompt | pass | 336.2s | $0.2063 | 37 turns | DEVELOPER_REPORT.md (missing) | `docs/reports/foreman-949b0/DEVELOPER_TRACE.json` | |
| `qa` | prompt | pass | 207.8s | $0.0278 | 15 turns | QA_REPORT.md (missing) | `docs/reports/foreman-949b0/QA_TRACE.json` | |
| `reviewer` | prompt | pass | 79.1s | $0.0402 | 17 turns | REVIEW.md (present) | `docs/reports/foreman-949b0/REVIEWER_TRACE.json` | |
| `developer` | prompt | pass | 122.0s | $0.0411 | 19 turns | DEVELOPER_REPORT.md (missing) | `docs/reports/foreman-949b0/DEVELOPER_TRACE.json` | |
| `qa` | prompt | pass | 179.9s | $0.0479 | 25 turns | QA_REPORT.md (missing) | `docs/reports/foreman-949b0/QA_TRACE.json` | |
| `reviewer` | prompt | pass | 68.1s | $0.0298 | 10 turns | REVIEW.md (present) | `docs/reports/foreman-949b0/REVIEWER_TRACE.json` | |

## Phase Inputs

## Warnings

- Missing phase artifacts: developer -> DEVELOPER_REPORT.md, qa -> QA_REPORT.md, developer -> DEVELOPER_REPORT.md, qa -> QA_REPORT.md

## Files Changed

- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/EXPLORER_REPORT.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/SESSION_LOG.md`
- `/Users/ldangelo/.foreman/workflows/pr-review.yaml`
- `/Users/ldangelo/.foreman/prompts/default/create-pr.md`
- `/Users/ldangelo/.foreman/prompts/default/pr-wait.md`
- `/Users/ldangelo/.foreman/prompts/default/prepare-pr-review.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/docs/PRD.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/docs/reports/foreman-949b0/DEVELOPER_REPORT.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/docs/reports/foreman-949b0/QA_REPORT.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/REVIEW.md`
- `/Users/ldangelo/.foreman/prompts/default/pr-review.md`
- `README.md`
- `SESSION_LOG.md`
- `docs/reports/foreman-949b0/DEVELOPER_REPORT.md`