# Developer Report: Harden trace and pipeline report artifacts

## Approach
The task required fixing a path inconsistency between the smoke workflow's declared artifact path (`docs/reports/{{seedId}}/QA_REPORT.md`) and the smoke QA prompt's instructions (`QA_REPORT.md` in current directory). Analysis of the codebase revealed that the path sanitization infrastructure and builtin phase record completeness were already implemented in prior work; only the smoke/qa.md prompt alignment remained.

## Files Changed
- `src/defaults/prompts/smoke/qa.md` — Fixed QA report path from `QA_REPORT.md` in current directory to `docs/reports/{{seedId}}/QA_REPORT.md`, matching the `artifact:` declaration in `src/defaults/workflows/smoke.yaml:38`. Added explicit directory creation step and renumbered subsequent steps.

## Tests Added/Modified
- No new tests required — existing tests already covered the sanitization and builtin phase scenarios:
  - `src/orchestrator/__tests__/pi-observability-extension.test.ts` — 5 tests pass including `sanitizes absolute worktreePath in committed JSON trace`
  - `src/orchestrator/__tests__/activity-logger.test.ts` — 4 tests pass
  - `src/orchestrator/__tests__/pipeline-smoke.test.ts` — 22 tests pass

## Decisions & Trade-offs
- The path sanitization (`relativeWorktreePath` field in `PhaseTrace` and `sanitizeTrace()` in `pi-observability-writer.ts`) was already correctly implemented, so no changes were needed there.
- The builtin phase records in `pipeline-executor.ts` (lines 1184-1196) already correctly include `phaseType`, `workflowName`, and `workflowPath`, so no changes were needed there either.
- The only substantive fix required was aligning the smoke QA prompt with the workflow artifact declaration.

## Known Limitations
- None identified. The smoke/qa.md path issue is resolved, and all relevant tests pass.
