# Developer Report: Fix task status after PR creation and merge

## Approach
Addressed the single blocking issue identified by CodeRabbit: the finalize fallback PR creation path was using an inconsistent client pair (`runtimeTaskBackend` from outer scope but `runtimeTaskClient` from a locally shadowed variable created by `createRuntimeTaskClient`). The fix removes the local shadowing so both the backend-type check and the status update use the outer scope `runtimeTaskClient`/`runtimeTaskBackend` pair — consistent with how `onTaskPhaseChange` works.

The broader feature (PR metadata writing + status update to "review" in finalize fallback, plus startup reconciliation for merged PRs) was already implemented in the worktree's uncommitted changes. My fix ensures the status update uses the correct/consistent client.

Verified that all acceptance criteria were already satisfied by existing code:
1. **PR creation status updates**: Handled by `nativeTaskStatusForPhase("create-pr")` → `"review"` via `onTaskPhaseChange` (explicit create-pr) and inline in finalize fallback
2. **Merge detection and task closing**: Handled by `syncTaskStatusOnStartup` via `mapRunStatusToNativeTaskStatus("merged")` → `"closed"`
3. **Consistent bookkeeping**: Finalize fallback and explicit create-pr share the same `PR_METADATA.json` writing
4. **Startup reconciliation**: Already covers stale finalize/review tasks with merged PRs and leaves closed tasks closed (tests in `startup-sync.test.ts`)

## Files Changed
- `src/orchestrator/agent-worker.ts` — Removed `const runtimeTaskClient = await createRuntimeTaskClient(pipelineProjectPath, registeredProjectId)` that was shadowing the outer scope variable. The outer scope `runtimeTaskClient` is now used consistently with `runtimeTaskBackend` for the Refinery initialization and the status update check/call.

## Tests Added/Modified
No new tests required. The worktree already contained comprehensive tests in `src/orchestrator/__tests__/startup-sync.test.ts` covering all reconciliation scenarios:
- `it("updates stale finalize task to review when run is completed")`
- `it("closes stale finalize task when run is merged")`
- `it("closes stale review task when run is merged")`
- `it("does not reopen closed native tasks from stale failed runs")`
- `it("does not reopen closed task even when run status suggests different status")`
- `it("does not update task that is already at correct status")`

## Decisions & Trade-offs
- Chose to use the outer scope `runtimeTaskClient` for the Refinery rather than keeping a separate local instance. The Refinery only needs the task client for post-merge `close()` calls; using the outer client is functionally equivalent and avoids a second client instantiation.
- Did not add board-only masking — the task explicitly forbids this and the existing reconciliation approach handles staleness correctly.

## Known Limitations
- The fix is minimal/surgical — the broader "task status after PR creation and merge" behavior was already implemented in prior worktree changes. This fix resolves the client inconsistency that could cause the status update to use the wrong backend client in edge cases.