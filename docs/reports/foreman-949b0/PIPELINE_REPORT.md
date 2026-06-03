# Pipeline Report — foreman-949b0

**Run ID:** `f9ec664d-acab-4aef-bf31-6febd6942008`
**Workflow:** `feature`
**Workflow Path:** `/Users/ldangelo/.foreman/workflows/feature.yaml`
**Target Branch:** `main`
**VCS Branch:** `foreman/foreman-949b0`
**Generated:** 2026-06-03T16:39:05.146Z
**Status:** IN_PROGRESS

## Summary

| Metric | Value |
|--------|-------|
| Phases completed | 4 |
| Total cost | $0.4726 |
| Total turns | 113 |
| Total tool calls | 457 |
| Total duration | 1252.8s |

## Phase Results

| Phase | Type | Status | Duration | Cost | Turns | Artifact | Trace | Error |
|-------|------|--------|----------|------|-------|----------|-------|--------|
| `explorer` | prompt | pass | 110.0s | $0.0723 | 20 turns | EXPLORER_REPORT.md (present) | `docs/reports/foreman-949b0/EXPLORER_TRACE.json` | |
| `developer` | prompt | pass | 569.8s | $0.2145 | 51 turns | DEVELOPER_REPORT.md (missing) | `docs/reports/foreman-949b0/DEVELOPER_TRACE.json` | |
| `qa` | prompt | pass | 129.6s | $0.0503 | 18 turns | QA_REPORT.md (missing) | `docs/reports/foreman-949b0/QA_TRACE.json` | |
| `reviewer` | prompt | pass | 443.4s | $0.1355 | 24 turns | REVIEW.md (present) | `docs/reports/foreman-949b0/REVIEWER_TRACE.json` | |

## Phase Inputs

## Warnings

- Missing phase artifacts: developer -> DEVELOPER_REPORT.md, qa -> QA_REPORT.md

## Files Changed

- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/EXPLORER_REPORT.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/SESSION_LOG.md`
- `src/defaults/prompts/default/create-pr.md`
- `src/defaults/prompts/default/pr-wait.md`
- `src/defaults/prompts/default/prepare-pr-review.md`
- `src/defaults/prompts/default/pr-review.md`
- `src/defaults/workflows/default.yaml`
- `README.md`
- `docs/reports/foreman-949b0/DEVELOPER_REPORT.md`
- `SESSION_LOG.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/docs/reports/foreman-949b0/QA_REPORT.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-949b0/REVIEW.md`