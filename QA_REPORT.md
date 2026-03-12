# QA Report: Multi-runtime support (pluggable AgentRuntime interface)

## Verdict: PASS

## Test Results
- Test suite: 242 passed, 9 failed
- New tests added: 12 (in `src/orchestrator/__tests__/runtime.test.ts`)
- All 12 new runtime tests pass
- All 9 failures are pre-existing environment issues unrelated to this change

### Pre-existing Failures (Not Caused by This Change)

| Test File | Failing Tests | Root Cause |
|---|---|---|
| `src/cli/__tests__/commands.test.ts` | 4 tests | CLI binary not built (`ENOENT`) |
| `src/orchestrator/__tests__/detached-spawn.test.ts` | 2 tests + 2 uncaught errors | `tsx` binary missing in worktree `node_modules` |
| `src/orchestrator/__tests__/worker-spawn.test.ts` | 1 test | `tsx` binary missing in worktree `node_modules` |

These failures were present before this change (same infrastructure issue reported in prior QA runs).

## Implementation Review

### New Files
- **`src/orchestrator/runtime.ts`** — `AgentRuntime` interface + `AgentQueryOptions` type + `createRuntime()` async factory + `getAvailableRuntimes()` helper. Clean, well-documented.
- **`src/orchestrator/runtime-claude-sdk.ts`** — `ClaudeSDKRuntime` class wrapping SDK `query()`. Uses `yield*` to delegate the async generator correctly.
- **`src/orchestrator/runtime-mock.ts`** — `MockRuntime` for testing. Supports `setMessages()`, `getCapturedParams()`, `reset()`. No API calls made.

### Modified Files
- **`src/orchestrator/types.ts`** — `RuntimeSelection` extended from `"claude-code"` to `"claude-code" | "mock"`. Exhaustive switch remains safe.
- **`src/orchestrator/agent-worker.ts`** — Direct `query()` import removed. Runtime created via `createRuntime()` factory at startup and passed through `runPipeline()` and `runPhase()`. All call sites updated correctly.
- **`src/orchestrator/dispatcher.ts`** — `runtime?` field threaded through `WorkerConfig`, `spawnAgent()`, and `dispatch()`. Defaults to `"claude-code"` when not specified.

### TypeScript Compilation
- `npx tsc --noEmit` passes with zero errors.

### Backward Compatibility
- `config.runtime ?? "claude-code"` default in `agent-worker.ts` ensures all existing worker configs work unchanged.
- `opts?.runtime ?? "claude-code"` in `dispatcher.ts` similarly safe.

### Edge Cases Verified by Tests
- `MockRuntime` yields zero messages by default
- `setMessages()` configures preset response messages
- `getCapturedParams()` captures all params passed to `executeQuery()`
- Multiple calls accumulate in captured params list
- `reset()` clears both messages and captured params
- Messages yielded in insertion order
- `createRuntime("mock")` returns `MockRuntime` instance
- `createRuntime("claude-code")` returns `ClaudeSDKRuntime` instance
- `createRuntime("unknown-runtime")` throws descriptive error
- `getAvailableRuntimes()` returns both runtimes, exactly 2

### Known Limitation (Documented by Developer)
- `dispatchPlanStep()` in `dispatcher.ts` still uses `query()` directly and is not covered by the runtime abstraction. This is an intentional deferral and correctly documented.

## Issues Found

None. The implementation is correct, TypeScript compiles cleanly, and all 12 new tests pass. Existing failures are pre-existing infrastructure issues in the worktree environment.

## Files Modified
- `QA_REPORT.md` — this report (no source or test files required changes)
