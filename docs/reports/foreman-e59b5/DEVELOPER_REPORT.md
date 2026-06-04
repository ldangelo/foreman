# Developer Report: Harden trace and pipeline report artifacts

## Approach
The codebase already had significant work toward the acceptance criteria from previous sessions. My approach was to verify each requirement, identify what was missing or incorrect, and make targeted fixes. The main issue found was an incorrect test fixture that used the wrong artifact path for `create-pr`.

## Files Changed
- `src/orchestrator/__tests__/activity-logger.test.ts` — Fixed incorrect artifact path in test fixtures for `create-pr` builtin phase

## Tests Added/Modified
- `src/orchestrator/__tests__/activity-logger.test.ts`:
  - Updated `create-pr` phase artifact from `docs/reports/<seedId>/QA_REPORT.md` to `PR_METADATA.json` (the actual artifact per `defaults/workflows/feature.yaml`)
  - Updated the pipeline report test to use `PR_METADATA.json` with `artifactPresent: true`

## Decisions & Trade-offs
- **Path sanitization** (`pi-observability-extension.ts`, `pi-observability-writer.ts`): Already implemented with `sanitizeValue()` and `sanitizeWorktreePath()` functions that replace absolute worktree paths with `<worktree>` placeholder. Both JSON serialization and markdown rendering use this sanitization.
- **Builtin phase reporting**: Code review confirmed builtin phases (`create-pr`, `pr-wait`, `prepare-pr-review`) are correctly pushed to `ctx.activityPhases` in `pipeline-executor.ts` line 1213 and appear in `writeIncrementalPipelineReport`. No code changes were needed.
- **QA piped commands**: grep confirmed `src/defaults/prompts/default/qa.md` contains no piped test commands that mask exit codes. The only pipe usage is a direct grep for conflict markers (pre-flight check), which is appropriate.

## Known Limitations
- None — all acceptance criteria were already addressed by previous worktree sessions or required no changes.