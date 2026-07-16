# RCA: Merge Phase Timeout (`foreman-31823`)

## Summary

`ElixirMergeQueue` is a **stub** — `enqueue()` does not actually enqueue anything to any merge queue. It returns `{ success: true }` with a fake pending entry, then the polling loop waits 5 minutes for a merge that never comes because no process is actually dequeuing and calling `gh pr merge`.

## Timeline

- `1:57:04 AM` — PR-REVIEW final gate PASSED (`checksTerminal=true`, `mergeConflict=false`, `blocking=0`)
- `1:57:04–2:02:09 AM` — merge phase ran; `ElixirMergeQueue.enqueue()` accepted (stub), then polled GitHub every 30s for 5 minutes
- `2:02:09 AM` — polling timeout fired, phase failed

## Root Cause

**`src/orchestrator/elixir-merge-queue.ts:34`:**
```ts
error: "Elixir merge queue API not implemented; accepted without legacy Postgres fallback"
```

`ElixirMergeQueue` is explicitly a placeholder. The `enqueue()` call succeeds but nothing processes the queue. The polling loop was added as a workaround and waits 5 minutes for a merge that cannot happen without a real backend.

**`src/orchestrator/agent-worker.ts:2209–2213`** (old):
```ts
// ElixirMergeQueue is currently a stub (does not process the queue), so without
// this poll the phase would return success immediately while the PR remains open.
// TODO (TRD-xxx): remove this poll once ElixirMergeQueue is fully implemented
```

## Fixes Applied

### 1. Fail fast on stub queue (foreman-639da, foreman-2c997)

When `ElixirMergeQueue.enqueue()` returns an entry with `"not implemented"` in the error field, the merge phase now:

- **With PR number**: Uses `gh pr merge --admin --squash` directly instead of waiting 5 minutes in a dead poll loop
- **Without PR number**: Fails immediately with a clear, actionable error message

### 2. Implement real merge (foreman-ff05f)

When the queue is a stub, the code now calls `gh pr merge` directly, providing a working merge path for unregistered projects.

### 3. Improved polling timeout error message

When polling a **real** queue times out, the error now includes the project ID and a registration hint:
```
Merge did not complete within the 300s polling timeout.
Verify refinery/RefineryAgent is running and processing the merge queue for project (unregistered);
or register the project with 'foreman project register'.
```

## Files Changed

- `src/orchestrator/agent-worker.ts` — stub queue detection, direct `gh pr merge` fallback, improved error messages
