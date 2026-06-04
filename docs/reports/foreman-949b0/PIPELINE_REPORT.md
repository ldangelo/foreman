# Pipeline Report — foreman-949b0

**Run ID:** `682addfb-ebea-4ae1-bfbf-08c33698f6ba`
**Workflow:** `feature`
**Workflow Path:** `/Users/ldangelo/.foreman/workflows/feature.yaml`
**Target Branch:** `main`
**VCS Branch:** `foreman/foreman-949b0`
**Generated:** 2026-06-04T15:56:12.997Z
**Status:** IN_PROGRESS

## Summary

| Metric | Value |
|--------|-------|
| Phases completed | 4 |
| Total cost | $0.1962 |
| Total turns | 51 |
| Total tool calls | 170 |
| Total duration | 422.7s |

## Phase Results

| Phase | Type | Status | Duration | Cost | Turns | Artifact | Trace | Error |
|-------|------|--------|----------|------|-------|----------|-------|--------|
| `explorer` | prompt | pass | 116.2s | $0.0240 | 11 turns | EXPLORER_REPORT.md (present) | `docs/reports/foreman-949b0/EXPLORER_TRACE.json` | |
| `developer` | prompt | pass | 44.7s | $0.0234 | 11 turns | DEVELOPER_REPORT.md (missing) | `docs/reports/foreman-949b0/DEVELOPER_TRACE.json` | |
| `qa` | prompt | pass | 137.8s | $0.1167 | 18 turns | QA_REPORT.md (missing) | `docs/reports/foreman-949b0/QA_TRACE.json` | |
| `reviewer` | prompt | pass | 124.1s | $0.0322 | 11 turns | REVIEW.md (present) | `docs/reports/foreman-949b0/REVIEWER_TRACE.json` | |

## Phase Inputs

## Warnings

- Missing phase artifacts: developer -> DEVELOPER_REPORT.md, qa -> QA_REPORT.md

## Files Changed

- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/EXPLORER_REPORT.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/SESSION_LOG.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/README.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/docs/reports/foreman-949b0/DEVELOPER_REPORT.md`
- `docs/reports/foreman-949b0/QA_REPORT.md`
- `SESSION_LOG.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/REVIEW.md`