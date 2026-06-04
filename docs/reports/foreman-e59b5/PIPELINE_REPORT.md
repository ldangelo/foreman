# Pipeline Report — foreman-e59b5

**Run ID:** `25c98ea8-78fa-44f3-bef6-66b033e61189`
**Workflow:** `feature`
**Workflow Path:** `/Users/ldangelo/.foreman/workflows/feature.yaml`
**Target Branch:** `main`
**VCS Branch:** `foreman/foreman-e59b5`
**Generated:** 2026-06-04T19:47:17.747Z
**Status:** IN_PROGRESS

## Summary

| Metric | Value |
|--------|-------|
| Phases completed | 15 |
| Total cost | $1.3579 |
| Total turns | 315 |
| Total tool calls | 2824 |
| Total duration | 2645.3s |

## Phase Results

| Phase | Type | Status | Duration | Cost | Turns | Artifact | Trace | Error |
|-------|------|--------|----------|------|-------|----------|-------|--------|
| `explorer` | prompt | pass | 208.7s | $0.0739 | 19 turns | EXPLORER_REPORT.md (present) | `docs/reports/foreman-e59b5/EXPLORER_TRACE.json` | |
| `developer` | prompt | pass | 273.6s | $0.1326 | 49 turns | DEVELOPER_REPORT.md (missing) | `docs/reports/foreman-e59b5/DEVELOPER_TRACE.json` | |
| `qa` | prompt | pass | 160.0s | $0.0601 | 27 turns | QA_REPORT.md (missing) | `docs/reports/foreman-e59b5/QA_TRACE.json` | |
| `reviewer` | prompt | pass | 181.9s | $0.3412 | 35 turns | REVIEW.md (present) | `docs/reports/foreman-e59b5/REVIEWER_TRACE.json` | |
| `developer` | prompt | pass | 138.3s | $0.2019 | 26 turns | DEVELOPER_REPORT.md (missing) | `docs/reports/foreman-e59b5/DEVELOPER_TRACE.json` | |
| `qa` | prompt | pass | 186.1s | $0.0820 | 28 turns | QA_REPORT.md (missing) | `docs/reports/foreman-e59b5/QA_TRACE.json` | |
| `reviewer` | prompt | pass | 104.3s | $0.0638 | 17 turns | REVIEW.md (present) | `docs/reports/foreman-e59b5/REVIEWER_TRACE.json` | |
| `finalize` | prompt | pass | 157.9s | $0.0198 | 16 turns | FINALIZE_VALIDATION.md (missing) | `docs/reports/foreman-e59b5/FINALIZE_TRACE.json` | |
| `create-pr` | builtin | pass | 3.9s | - | 0 turns | PR_METADATA.json (present) | — | |
| `pr-wait` | builtin | pass | 559.5s | - | 0 turns | PR_WAIT_REPORT.md (present) | — | |
| `prepare-pr-review` | builtin | pass | 1.3s | - | 0 turns | PR_REVIEW_FINDINGS.md (present) | — | |
| `pr-review` | prompt | pass | 96.5s | $0.0541 | 20 turns | PR_REVIEW_REPORT.md (present) | `docs/reports/foreman-e59b5/PR-REVIEW_TRACE.json` | |
| `developer` | prompt | pass | 192.0s | $0.1081 | 38 turns | DEVELOPER_REPORT.md (missing) | `docs/reports/foreman-e59b5/DEVELOPER_TRACE.json` | |
| `qa` | prompt | pass | 218.9s | $0.1400 | 15 turns | QA_REPORT.md (missing) | `docs/reports/foreman-e59b5/QA_TRACE.json` | |
| `reviewer` | prompt | pass | 162.2s | $0.0803 | 25 turns | REVIEW.md (present) | `docs/reports/foreman-e59b5/REVIEWER_TRACE.json` | |

## Phase Inputs

## Warnings

- Missing phase artifacts: developer -> DEVELOPER_REPORT.md, qa -> QA_REPORT.md, developer -> DEVELOPER_REPORT.md, qa -> QA_REPORT.md, finalize -> FINALIZE_VALIDATION.md, developer -> DEVELOPER_REPORT.md, qa -> QA_REPORT.md

## Files Changed

- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-e59b5/EXPLORER_REPORT.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-e59b5/SESSION_LOG.md`
- `src/orchestrator/pi-observability-types.ts`
- `src/orchestrator/pi-observability-writer.ts`
- `src/orchestrator/__tests__/pi-observability-extension.test.ts`
- `src/defaults/workflows/smoke.yaml`
- `src/orchestrator/pipeline-executor.ts`
- `SessionLogs/session-040625-14:10.md`
- `docs/reports/foreman-e59b5/DEVELOPER_REPORT.md`
- `docs/reports/foreman-e59b5/QA_REPORT.md`
- `SessionLogs/session-040625-14:14.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-e59b5/REVIEW.md`
- `src/defaults/prompts/smoke/qa.md`
- `SessionLogs/session-040625-14:18.md`
- `SessionLogs/session-040625-14:20.md`
- `SESSION_LOG.md`
- `docs/reports/foreman-e59b5/FINALIZE_VALIDATION.md`
- `docs/reports/foreman-e59b5/FINALIZE_REPORT.md`
- `PR_REVIEW_REPORT.md`
- `src/orchestrator/__tests__/activity-logger.test.ts`
- `SessionLogs/session-040626-14:40.md`
- `/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-e59b5/docs/reports/foreman-e59b5/QA_REPORT.md`