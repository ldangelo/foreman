# Developer Report: Multi-runtime support (pluggable AgentRuntime interface)

## Approach

Introduced a thin abstraction layer between the orchestration logic and the Claude Agent SDK by defining an `AgentRuntime` interface. The implementation follows the recommended phased approach from the Explorer Report:

1. **Define the interface** (`runtime.ts`) — `AgentRuntime` with `executeQuery()` method and `AgentQueryOptions` type
2. **Implement the default runtime** (`runtime-claude-sdk.ts`) — wraps the existing `query()` function
3. **Implement a test runtime** (`runtime-mock.ts`) — yields preset messages without API calls
4. **Wire it through** — `agent-worker.ts` and `dispatcher.ts` pass `runtime` through the config JSON
5. **Expand the type** — `RuntimeSelection` extended to `"claude-code" | "mock"`

The factory uses dynamic `import()` so runtimes are only loaded when needed — avoids importing the SDK when running with mock in tests.

## Files Changed

- **src/orchestrator/runtime.ts** — New file. Defines `AgentQueryOptions` interface, `AgentRuntime` interface, `createRuntime()` async factory, and `getAvailableRuntimes()` helper.

- **src/orchestrator/runtime-claude-sdk.ts** — New file. `ClaudeSDKRuntime` class wrapping the SDK `query()` function. Production default runtime.

- **src/orchestrator/runtime-mock.ts** — New file. `MockRuntime` class for testing. Yields preset messages, captures params for assertion, supports `reset()`.

- **src/orchestrator/types.ts** — `RuntimeSelection` expanded from `"claude-code"` to `"claude-code" | "mock"`. The discriminated union ensures the factory's `default: never` branch remains exhaustive.

- **src/orchestrator/agent-worker.ts** — Removed direct `query` import. Added runtime imports. Added `runtime?: RuntimeSelection` to `WorkerConfig`. `main()` now calls `createRuntime(config.runtime ?? "claude-code")` and passes the instance to `runPipeline()` and the single-agent loop. `runPhase()` accepts `runtime: AgentRuntime` and calls `runtime.executeQuery()` instead of `query()`. Removed `Parameters<typeof query>[0]` type annotation (no longer needed).

- **src/orchestrator/dispatcher.ts** — `WorkerConfig` interface gains `runtime?: RuntimeSelection`. `spawnAgent()` accepts `runtime?: RuntimeSelection` in its pipeline options and threads it into the worker config. The hardcoded `"claude-code"` literal in `dispatch()` is replaced with `opts?.runtime ?? "claude-code"`.

## Tests Added/Modified

- **src/orchestrator/__tests__/runtime.test.ts** — 12 new tests covering:
  - `MockRuntime`: name, default empty output, setMessages(), param capture, multi-call accumulation, reset(), ordering
  - `createRuntime`: creates MockRuntime, creates ClaudeSDKRuntime, throws for unknown selection
  - `getAvailableRuntimes`: returns both runtimes, exact count

All 12 tests pass. TypeScript compiles with zero errors (`tsc --noEmit` exits 0).

## Decisions & Trade-offs

- **`AsyncIterable<SDKMessage>` vs `AsyncGenerator<SDKMessage>`**: The interface uses `AsyncIterable` (the wider type) so implementations can return generators, async iterators, or any async iterable. The consuming code (`for await...of`) works with any of these.

- **Dynamic imports in factory**: `createRuntime()` uses dynamic `import()` to load runtime modules lazily. This avoids pulling in the SDK package when only the mock is needed (e.g., in unit tests). The trade-off is that the factory is async, requiring `await createRuntime(...)`.

- **`mock` runtime in production type**: `RuntimeSelection = "claude-code" | "mock"` includes `mock` in the type, which means it could theoretically be configured in a real dispatch. This is intentional — it makes the abstraction testable end-to-end (e.g., integration tests that don't call the API). In practice, the `mock` runtime would be filtered by the dispatcher before real use.

- **Minimal diff to agent-worker.ts**: The changes are surgical — only the import, WorkerConfig field, and the `query()` call sites are touched. All orchestration logic (pipeline phases, progress tracking, error handling) is unchanged.

- **Backward compatibility**: `config.runtime ?? "claude-code"` defaults ensure all existing worker configs without a `runtime` field continue to work exactly as before.

## Known Limitations

- Only two runtimes are implemented: `claude-code` (production) and `mock` (testing). Adding a real alternative (e.g., `openai-api`) requires implementing the `AgentRuntime` interface and adding a `case` to the factory.
- The `mock` runtime yields the same message list for every `executeQuery()` call. For tests that need different responses per call, callers must create a new `MockRuntime` instance or call `setMessages()` between calls.
- `dispatchPlanStep()` in `dispatcher.ts` still uses `query()` directly (inline, not via the runtime interface). It was left unchanged as it is a different execution path (inline, not a worker process) and would require passing a runtime instance into the Dispatcher constructor — a larger architectural change deferred for a future iteration.
