# Developer Report: Refinery Agent

## Approach

Integrated the Pi SDK directly into the RefineryAgent's `runAgent()` method to create an agentic fix loop that replaces the legacy ~1500-line refinery script. The agent reads PR state via `gh` commands, spawns a Pi SDK session with the refinery-agent system prompt, iterates fix attempts (up to `maxFixIterations`), verifies build/test pass, and merges or escalates.

## Files Changed

- `src/orchestrator/refinery-agent.ts` — Integrated Pi SDK `runWithPiSdk()` into `runAgent()` method. Added `ForemanStore` and `SqliteMailClient` instances for mail. Added model/config options. Implemented fix iteration loop with build/test verification. Uses `createBashTool`, `createReadTool`, `createEditTool`, `createWriteTool`, `createGrepTool`, `createFindTool`, `createLsTool` from `@mariozechner/pi-coding-agent` plus `createSendMailTool` for escalations.

- `src/orchestrator/__tests__/refinery-agent.test.ts` — Added 3 new tests: model config options, PR state read failure handling, config validation. All 11 tests passing.

## Tests Added/Modified

- `src/orchestrator/__tests__/refinery-agent.test.ts` — 11 tests total (was 8):
  - `uses default model when not specified` (new)
  - `accepts custom model in config` (new)
  - `updates queue status when PR state cannot be read` (new)
  - `accepts all config options` (updated to include model)
  - 8 existing tests preserved

## Decisions & Trade-offs

1. **SqliteMailClient initialization pattern**: `SqliteMailClient` requires `ensureProject()` to be called before use, but it's async and the constructor is synchronous. Solved by storing an `mailInitialized` flag and calling `ensureMailClient()` at the start of `processQueue()`.

2. **Worktree path resolution**: Uses `run.worktree_path` from the store if available, falling back to `join(projectPath, "worktrees", seedId)`. This matches how the pipeline stores worktree paths.

3. **Build/test verification**: `checkBuildOk()` and `checkTestsOk()` use simple stdout pattern matching rather than exit codes, matching the existing refinery approach of looking for "build"/"PASS"/"passed" strings.

4. **Merge via gh**: After fix loop succeeds, agent calls `gh pr merge --squash --delete-branch` rather than using VcsBackend directly, which aligns with the system prompt's "merge via gh pr merge" instruction.

5. **Target branch detection**: Calls `vcsBackend.detectDefaultBranch()` once at the start of `runAgent()` rather than per-entry, avoiding redundant VCS calls.

## Known Limitations

- The fix iteration loop currently continues even after a failed agent attempt by looping, but doesn't provide the agent with the previous error context (the feedback variable is set but the task prompt isn't updated with it). A follow-up enhancement would pass the previous error as context to the next attempt.
- The `checkBuildOk()` and `checkTestsOk()` pattern matching is brittle; exit-code-based verification would be more reliable.
- The agent doesn't handle the case where a worktree doesn't exist (falls back to default path which may not exist).
- Mail client is scoped to the refinery agent's run ID but there's no per-entry run ID in the queue entry (only `run_id` from the original pipeline run). Escalation mail would benefit from having the original run's runId.
