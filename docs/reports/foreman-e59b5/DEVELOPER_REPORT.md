# Developer Report: Harden trace and pipeline report artifacts

## Approach

- **Path sanitization**: Added `sanitizeValue()` in `pi-observability-extension.ts` to replace absolute worktree paths with `<worktree>` placeholder during tool call args/results capture. Also added `serializeTrace()` in `pi-observability-writer.ts` using a JSON.stringify reviver to sanitize all string fields in the JSON output. This ensures no committed trace artifact contains host-specific absolute paths.

- **Builtin phase reporting**: Verified via code review that builtin phases (`create-pr`, `pr-wait`, `prepare-pr-review`) are correctly tracked with `phaseType: "builtin"` and flow into `ctx.activityPhases` passed to `writeIncrementalPipelineReport`. No code changes were needed; the pipeline report already includes builtin phases when they execute.

- **QA prompt analysis**: Scanned `src/defaults/prompts/` for piped test evidence patterns (`| tail`, `| head`). Found none in `qa.md`. Patterns exist only in `recover.md` and `troubleshooter.md` (error recovery prompts, not QA verification), which are out of scope.

## Files Changed

- **`src/orchestrator/pi-observability-extension.ts`**
  - Added `sanitizeValue()` helper function
  - Updated `summarizeUnknown()` to accept optional `worktreePath` parameter and apply sanitization to string and JSON-stringified values
  - Updated all 4 call sites (tool_execution_start, tool_execution_update, tool_result, tool_execution_end) to pass `trace.worktreePath`

- **`src/orchestrator/pi-observability-writer.ts`**
  - Added `sanitizeWorktreePath()` helper function
  - Added `serializeTrace()` using JSON.stringify with a reviver that sanitizes all string values
  - Replaced `JSON.stringify(trace, null, 2)` with `serializeTrace(trace)` in `writePhaseTrace()`

## Tests Added/Modified

- **`src/orchestrator/__tests__/pi-observability-extension.test.ts`**
  - `sanitizes absolute worktree paths in tool call argsPreview` — verifies argsPreview doesn't contain absolute path, contains `<worktree>` placeholder
  - `sanitizes worktreePath field in JSON trace output` — verifies JSON file contains placeholder, not the absolute path

- **`src/orchestrator/__tests__/activity-logger.test.ts`**
  - `creates phase record with builtin phaseType for PR workflow phases` — verifies createPhaseRecord accepts builtin phaseType
  - `writeIncrementalPipelineReport includes builtin phases in phase table` — verifies both prompt and builtin phases appear in the report table with correct phase type shown

## Decisions & Trade-offs

- Sanitization is applied at two levels: (1) during tool call capture in the extension, and (2) during JSON serialization in the writer. This defense-in-depth ensures both `argsPreview`/`resultPreview` strings and the `worktreePath` field itself are sanitized.

- Used `<worktree>` as the placeholder rather than a relative path because the worktree location varies by host and the actual project root cannot be reliably derived without additional context. The placeholder is stable and self-documenting.

- Builtin phases were already correctly tracked; no changes to pipeline-executor.ts or agent-worker.ts were needed.

## Known Limitations

- The `troubleshooter.md` and `recover.md` prompts contain `| tail` patterns that could mask test failures. These are error-recovery prompts, not QA verification prompts, so they were left unchanged per scope guidance. If future QA use cases need recovery prompts, those should be updated to use `set -o pipefail`.
- Report path alignment (`docs/reports/<seed>/QA_REPORT.md` vs root `QA_REPORT.md`) — the EXPLORER_REPORT.md analysis confirmed actual reports live under `docs/reports/<seed>/`. The pipeline report already uses relative paths. No discrepancy found requiring changes.