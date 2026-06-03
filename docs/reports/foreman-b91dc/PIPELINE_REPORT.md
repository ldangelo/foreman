# Pipeline Report — foreman-b91dc

**Run ID:** `132ad714-8466-4cf6-8d00-e77888d237c3`
**Workflow:** `feature`
**Workflow Path:** `/Users/ldangelo/.foreman/workflows/feature.yaml`
**Target Branch:** `main`
**VCS Branch:** `foreman/foreman-b91dc`
**Generated:** 2026-06-03T14:00:40.535Z
**Status:** IN_PROGRESS

## Summary

| Metric | Value |
|--------|-------|
| Phases completed | 4 |
| Total cost | $0.1740 |
| Total turns | 56 |
| Total tool calls | 197 |
| Total duration | 460.1s |

## Phase Results

| Phase | Type | Status | Duration | Cost | Turns | Artifact | Trace | Error |
|-------|------|--------|----------|------|-------|----------|-------|--------|
| `explorer` | prompt | pass | 53.3s | $0.0443 | 13 turns | EXPLORER_REPORT.md (present) | `docs/reports/foreman-b91dc/EXPLORER_TRACE.json` | |
| `developer` | prompt | pass | 125.9s | $0.0644 | 16 turns | DEVELOPER_REPORT.md (missing) | `docs/reports/foreman-b91dc/DEVELOPER_TRACE.json` | |
| `qa` | prompt | pass | 125.4s | $0.0293 | 16 turns | QA_REPORT.md (missing) | `docs/reports/foreman-b91dc/QA_TRACE.json` | |
| `reviewer` | prompt | pass | 155.5s | $0.0360 | 11 turns | REVIEW.md (present) | `docs/reports/foreman-b91dc/REVIEWER_TRACE.json` | |

## Phase Inputs

## Warnings

- Missing phase artifacts: developer -> DEVELOPER_REPORT.md, qa -> QA_REPORT.md

## Files Changed

- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-b91dc/EXPLORER_REPORT.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-b91dc/SESSION_LOG.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-b91dc/src/lib/config.ts`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-b91dc/src/orchestrator/monitor.ts`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-b91dc/src/orchestrator/__tests__/monitor.test.ts`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-b91dc/docs/reports/foreman-b91dc/DEVELOPER_REPORT.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-b91dc/docs/reports/foreman-b91dc/QA_REPORT.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-b91dc/REVIEW.md`