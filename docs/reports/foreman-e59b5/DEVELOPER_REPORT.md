# Developer Report: Harden trace and pipeline report artifacts

## Approach
1. **Path sanitization** — Added `sanitizePhaseTrace()` in `pi-observability-writer.ts` that replaces host-specific `worktreePath` strings with a stable `<worktree>` placeholder across all PhaseTrace string fields (rawPrompt, resolvedCommand, argsPreview, resultPreview, etc.). The function is called at write time so original trace objects retain accurate paths for internal use.
2. **Builtin phase report coverage** — Confirmed `writeIncrementalPipelineReport()` in `activity-logger.ts` correctly renders builtin phases with `phaseType: "builtin"` in the phase table. Added a test to verify the report includes all four PR builtin phases.
3. **Pipefail for test evidence** — Updated all `npm test ... | tail` patterns in `recover.md` and `troubleshooter.md` to use `set -o pipefail` prefix so exit codes propagate through the pipe.

## Files Changed
- `src/orchestrator/pi-observability-writer.ts` — Added `sanitizePhaseTrace()` function and applied it in `writePhaseTrace()` before writing JSON/MD artifacts.
- `src/defaults/prompts/default/recover.md` — Replaced 4 occurrences of `npm test ... | tail` with `set -o pipefail && npm test ... | tail`.
- `src/defaults/prompts/default/troubleshooter.md` — Replaced 1 occurrence of `npm test ... | tail` with `set -o pipefail && npm test ... | tail`.

## Tests Added/Modified
- `src/orchestrator/__tests__/pi-observability-extension.test.ts`:
  - `"sanitizes host-specific worktree paths in trace artifacts"` — Creates a trace with an absolute `/Users/...` worktree path and tool call args containing that path, writes the trace, then asserts neither the JSON nor MD output contains the original path and both contain `<worktree>`.
  - `"pipeline report includes builtin PR workflow phases"` — Creates phase records for `create-pr`, `pr-wait`, `prepare-pr-review`, `pr-review` as `builtin` type, writes the incremental pipeline report, then asserts all four phase names appear in the report and the type column shows `builtin`.

## Decisions & Trade-offs
- Chose to sanitize at write time rather than at trace creation time, preserving accurate internal paths while ensuring committed artifacts contain only the placeholder.
- The `<worktree>` placeholder was chosen as it is stable, self-documenting, and cannot occur in normal source code paths.
- Only string fields containing the worktreePath are sanitized; numeric/boolean fields (updateCount, success, etc.) are unaffected.

## Known Limitations
- The `workflowPath` field in PhaseTrace is not sanitized because it is a genuine workflow YAML path (e.g., `/tmp/project/.foreman/workflows/bug.yaml`) not derived from the worktree. This is not a host-leak concern since it's a generated temp path, not a user directory.
- Artifact path alignment (`EXPLORER_REPORT.md` at root vs `docs/reports/<seed>/...`) was investigated and found to already be correct — trace artifacts use `docs/reports/<seed>/` consistently.