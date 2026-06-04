# Developer Report: Harden trace and pipeline report artifacts

## Approach
Verified that the existing `sanitizeWorktreePath` implementation in `pi-observability-writer.ts` (added in a prior commit) correctly sanitizes both the JSON trace file and the markdown trace output. Confirmed the QA/test evidence pipe issue exists only in `recover.md` line 91, which lacked `set -o pipefail`. Fixed that instance. For the activity-logger test, replaced the hardcoded `foreman-e59b5` seed ID in artifact expectations with a `<seedId>` placeholder to make tests non-fragile.

## Files Changed

- `src/defaults/prompts/default/recover.md` — Added `set -o pipefail;` to the one instance at line 91 where it was missing (`cd {{projectRoot}} && npm test 2>&1 | tail -50`). All other instances in both `recover.md` and `troubleshooter.md` already had it.

- `src/orchestrator/__tests__/activity-logger.test.ts` — Replaced hardcoded seed ID `foreman-e59b5` with generic placeholder `<seedId>` in two artifactExpected fields (lines 90 and 121) so tests don't depend on a specific seed run.

## Tests Added/Modified

- `src/orchestrator/__tests__/pi-observability-extension.test.ts` — Already had two tests covering path sanitization (`sanitizes absolute worktree paths in tool call argsPreview` and `sanitizes worktreePath field in JSON trace output`). Both pass.

- `src/orchestrator/__tests__/activity-logger.test.ts` — Modified two existing tests to use `<seedId>` placeholder instead of hardcoded `foreman-e59b5`. Tests pass.

## Decisions & Trade-offs

- **Path sanitization**: The existing `sanitizeWorktreePath` utility in `pi-observability-writer.ts` already handles this correctly by replacing the absolute worktree path with `<worktree>` during JSON serialization and markdown rendering. No additional code was needed.

- **Pipeline report builtin phases**: The existing test in `activity-logger.test.ts` (`writeIncrementalPipelineReport includes builtin phases in phase table`) already verifies that builtin phases appear in the phase table. No changes needed there — the implementation correctly includes them.

- **Pipe masking fix**: Only `recover.md:91` was missing `set -o pipefail`. The other four instances all correctly use it. The pattern `npm test 2>&1 | tail -N` is used throughout both recover.md and troubleshooter.md for capturing test output in evidence display. These are not test-running commands but rather evidence examples shown to the agent — so the pipe is intentional for brevity. Adding `set -o pipefail` ensures that if the test fails, the entire command chain fails correctly.

- **Test seed ID fragility**: Replaced hardcoded `foreman-e59b5` with `<seedId>` placeholder in activity-logger tests. The `<seedId>` is a template token that Foreman resolves at runtime.

## Known Limitations

- No changes to `qa.md` were needed — it does not contain piped test commands that mask exit codes; it only references `npm test` inline in the QA report template.
- The `pi-observability-extension.ts` `sanitizeValue` helper (already in place) is applied during capture time via `summarizeUnknown`. This is complementary to the writer-level sanitization in `pi-observability-writer.ts` which handles the JSON `worktreePath` field. Both layers together ensure no absolute paths leak.