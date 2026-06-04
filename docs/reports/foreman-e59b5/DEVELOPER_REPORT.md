# Developer Report: Harden trace and pipeline report artifacts

## Approach
Verified all acceptance criteria are correctly implemented by prior worktree sessions, then documented findings. No new implementation work was needed — all four requirements were already addressed by previous sessions on this branch.

## Files Changed
No source files were changed. Verified existing implementations:

- `src/orchestrator/pi-observability-extension.ts` — `sanitizeValue()` replaces worktree absolute paths with `<worktree>` placeholder at tool args/results capture time (via `summarizeUnknown()` with `worktreePath` parameter)
- `src/orchestrator/pi-observability-writer.ts` — `serializeTrace()` uses a custom JSON replacer function to sanitize all string fields in the trace output; `renderTraceMarkdown()` also emits sanitized previews from already-sanitized `argsPreview`/`resultPreview`
- `src/orchestrator/pipeline-executor.ts` — builtin phases (`create-pr`, `pr-wait`, `prepare-pr-review`) are pushed to `ctx.activityPhases` (line 1213) and passed to `writeIncrementalPipelineReport`; builtin phases show `phaseType: "builtin"` in the report table
- `src/defaults/prompts/default/qa.md` — contains no piped test commands that mask exit codes (grep confirmed; only pipe usage is `grep -rn` for conflict markers which is appropriate)
- `src/defaults/prompts/default/troubleshooter.md` — uses `set -o pipefail; npm test 2>&1 | tail -50`
- `src/defaults/prompts/default/recover.md` — uses `set -o pipefail; npm test 2>&1 | tail -50`

## Tests Added/Modified
No new tests were added — verified existing tests cover all requirements:

- `src/orchestrator/__tests__/pi-observability-extension.test.ts` — Tests `sanitizeValue()` for `argsPreview` in tool calls and `worktreePath` field in JSON trace output (2 new tests added by prior session: `sanitizes absolute worktree paths in tool call argsPreview` and `sanitizes worktreePath field in JSON trace output`)
- `src/orchestrator/__tests__/activity-logger.test.ts` — Tests builtin phase inclusion in `writeIncrementalPipelineReport` (`creates phase record with builtin phaseType for PR workflow phases` and `writeIncrementalPipelineReport includes builtin phases in phase table`)

## Decisions & Trade-offs
- **JSON replacer vs. field-level sanitization**: Used `JSON.stringify(trace, (_key, value) => ...)` with a replacer function rather than sanitizing only the `worktreePath` field. This ensures any string value that embeds the worktree path (e.g., tool call args containing JSON with path values) is sanitized uniformly. More robust than field-level approaches.
- **Sanitization strategy**: Paths are replaced with `<worktree>` placeholder (stable across runs, no info leakage) rather than relative paths (which would require project root inference that may not be reliable in all worktree configurations).
- **Builtin phase reporting**: Confirmed working by code inspection — `runBuiltinPhase()` result is pushed to `ctx.activityPhases` and `writeIncrementalPipelineReport` is called with that array. No changes needed.
- **Pre-existing test failure**: `dispatcher-native-integration.test.ts` has 18 failing tests about `approve` being undefined. Verified this failure exists in clean stash state and is unrelated to this task.

## Known Limitations
- The pre-existing `dispatcher-native-integration.test.ts` failure (18 tests about `approve` on undefined) is unrelated to trace/report hardening — it fails both with and without changes on this branch.
- The committed `DEVELOPER_TRACE.json` still contains the full raw prompt with the worktree path because it was written before `serializeTrace()` was added (commit order: bd1815c added the code, but artifacts were committed before the fix took effect in the same commit). Future pipeline runs will produce sanitized traces.