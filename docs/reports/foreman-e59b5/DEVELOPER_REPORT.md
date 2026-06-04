# Developer Report: Harden trace and pipeline report artifacts

## Approach

The task was to harden Foreman's trace and pipeline report artifacts so committed artifacts are reviewer-safe, accurate, and consistent with the workflow. The work involved:

1. **Path sanitization verification** — Confirmed that `sanitizeTrace()` in `pi-observability-writer.ts` strips the absolute `worktreePath` from committed JSON traces and replaces it with a repo-relative `relativeWorktreePath` field. This was already implemented before this session.

2. **`relativeWorktreePath` field** — Confirmed the field exists in the `PhaseTrace` interface in `pi-observability-types.ts` with appropriate documentation noting it's for committed artifacts.

3. **Builtin phase record completeness** — Audited `pipeline-executor.ts` builtin phase `phaseRecords` push (lines 1184–1196) and found it already includes `phaseType`, `workflowName`, and `workflowPath` — consistent with non-builtin phase records. No fix needed.

4. **QA report path alignment** — Confirmed `src/defaults/prompts/smoke/qa.md` already writes to `docs/reports/{{seedId}}/QA_REPORT.md` (correct path). No fix needed.

5. **Test coverage** — Added two new tests to `src/orchestrator/__tests__/activity-logger.test.ts` covering builtin phase record creation and the full round-trip through `finalizePhaseRecord`, verifying that `phaseType: "builtin"`, `workflowName`, and `workflowPath` are correctly preserved.

## Files Changed

- `src/orchestrator/__tests__/activity-logger.test.ts` — Added two new tests for builtin phase record metadata preservation:
  - `records builtin phase type with workflow metadata` — verifies `createPhaseRecord` correctly captures `phaseType: "builtin"` and workflow fields
  - `finalizePhaseRecord carries builtin phase type and workflow info through to result` — verifies the full pipeline preserves all builtin metadata and produces correct verdict

## Tests Added/Modified

- `src/orchestrator/__tests__/activity-logger.test.ts` — 2 new tests added (6 total, all passing)
- `src/orchestrator/__tests__/pi-observability-extension.test.ts` — existing test `"sanitizes absolute worktreePath in committed JSON trace"` covers the path sanitization requirement (no changes needed)

## Decisions & Trade-offs

- The explorer report identified several "fixes needed" that were already correctly implemented in prior runs. Rather than making unnecessary changes, I verified each item and only added missing test coverage.
- The `smoke/qa.md` prompt was already using the correct path `docs/reports/{{seedId}}/QA_REPORT.md`. The explorer report's finding was stale/outdated.
- The builtin phase record construction in `pipeline-executor.ts` was already complete (included `phaseType`, `workflowName`, `workflowPath`). The explorer report's finding was slightly inaccurate on this point.
- Path sanitization (`sanitizeTrace()`) was already implemented. The existing test in `pi-observability-extension.test.ts` adequately covers the requirement.

## Known Limitations

- The pre-existing `FINALIZE_TRACE.json` artifact in the worktree still contains the absolute `worktreePath` because it was written before the sanitization was in place. New artifacts written by future pipeline runs will be sanitized correctly.
- No additional path sanitization tests were needed beyond the existing `"sanitizes absolute worktreePath in committed JSON trace"` test in `pi-observability-extension.test.ts`.