# Developer Report: FT-002: Orchestrator delegates dispatch to task runner

## Approach

The task required verifying that the orchestrator's normal task dispatch uses the same canonical workflow runner as the direct CLI path (`foreman run task`).

**Architecture verification confirmed both paths converge:**

| Path | Call Chain | `pipeline` value |
|------|-----------|------------------|
| `foreman run task` | `runTaskAction()` → `spawnWorkerProcess()` | `pipeline: true` (explicit) |
| `foreman run` | `run.ts` → `dispatcher.dispatch()` → `spawnAgent()` → `spawnWorkerProcess()` | `pipeline: true` (default) |

Both paths ultimately call `executePipeline()` from `pipeline-executor.ts` in `agent-worker.ts` (agent-worker.ts:1475).

No refactoring was needed — the architecture already correctly implements the desired behavior.

## Files Changed

**No task-related code changes were made.** The committed changes in `89ec75fd` ("fix: review follow-up cleanups") addressed unrelated cleanup items:
- `assumeDefaultBranch` option in dispatcher (daemon branch labeling)
- Orphan worktree cleanup in `reset.ts`
- Removed dead `rebaseAfterPhase` keys from bundled YAML files
- Deleted unreachable `lead-prompt.ts` and its tests

These changes do not relate to "making normal task dispatch use the same canonical workflow runner" — that requirement was already satisfied before these cleanup changes were made.

## Tests Added/Modified

No tests were added or modified for this task.

**Verification:**
- TypeScript compilation: `npx tsc --noEmit` — no errors
- Dispatcher tests: `npx vitest run src/orchestrator/__tests__/dispatcher.test.ts` — **73 tests passed**

## Decisions & Trade-offs

- The architecture was already correct — no code changes were needed for the task requirement
- `pipeline: true` is the default in `dispatcher.dispatch()` (dispatcher.ts:1417: `const usePipeline = pipelineOpts?.pipeline ?? true`), ensuring normal dispatch uses the same canonical runner as direct CLI execution
- The committed cleanup changes (`89ec75fd`) are unrelated to this task

## Known Limitations

None — the architecture is correct and tests pass. The CRITICAL feedback in the prior review correctly noted that the committed changes (`89ec75fd`) don't address the task requirement; however, the task requirement was already correctly implemented before those cleanup changes were committed.
