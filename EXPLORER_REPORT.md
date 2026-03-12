# Explorer Report: Multi-runtime support (pluggable AgentRuntime interface)

## Relevant Files

### Core Agent Execution
- **src/orchestrator/agent-worker.ts** (728 lines) — Spawned as a standalone process that runs a single SDK agent. Currently hardcoded to use `@anthropic-ai/claude-agent-sdk`'s `query()` function. Contains both single-agent mode and pipeline orchestration (explorer→developer→qa→reviewer).
  - Line 16: `import { query } from "@anthropic-ai/claude-agent-sdk"`
  - Lines 158, 330: Direct usage of `query()` function
  - Lines 310-399: `runPhase()` function runs each pipeline phase as a separate SDK query
  - Lines 598-636 in dispatcher.ts spawn this worker via `tsx agent-worker.ts <config-file>`

- **src/orchestrator/dispatcher.ts** (692 lines) — High-level dispatcher that creates worktrees and spawns agent-worker processes. Currently hardcodes `"claude-code"` as the runtime.
  - Line 5: `import { query } from "@anthropic-ai/claude-agent-sdk"`
  - Line 101: `const runtime: RuntimeSelection = "claude-code"` (hardcoded)
  - Line 359: `dispatchPlanStep()` also uses `query()` directly for plan generation
  - Lines 468-512: `spawnAgent()` spawns worker process that will use the SDK
  - Lines 598-636: `spawnWorkerProcess()` spawns the worker as a detached child

- **src/orchestrator/types.ts** (152 lines) — Core type definitions
  - Line 3: `export type RuntimeSelection = "claude-code"` — Currently only has one option
  - Lines 56-64: `DispatchedTask` interface includes `runtime: RuntimeSelection`

### Supporting Files
- **src/orchestrator/roles.ts** (302 lines) — Defines role prompts and configurations for the pipeline phases (explorer, developer, qa, reviewer)
  - Lines 13-19: `RoleConfig` interface with model and budget settings
  - Used to determine which model and budget each phase should use

- **src/lib/store.ts** — Manages the SQLite database for run tracking and progress

- **src/orchestrator/__tests__/agent-worker.test.ts** — Tests for agent-worker script

## Architecture & Patterns

### Current Design
1. **Two-level process model:**
   - Foreman dispatcher (parent) spawns detached worker processes (children)
   - Workers are independent and update SQLite store directly
   - This survives parent process exit

2. **Worker Configuration via JSON:**
   - Dispatcher writes a JSON config file to `~/.foreman/tmp/worker-<runId>.json`
   - Worker reads config (defined in WorkerConfig interface, lines 34-48 of agent-worker.ts)
   - Worker deletes config after reading (line 61)

3. **Pipeline Mode:**
   - When `config.pipeline === true`, worker orchestrates the full phase cycle (lines 99-104)
   - Each phase (`explorer`, `developer`, `qa`, `reviewer`) runs as a separate `query()` call with different models and budgets
   - Phases communicate via Markdown report files (EXPLORER_REPORT.md, DEVELOPER_REPORT.md, etc)

4. **Single Agent Mode:**
   - When `config.pipeline === false`, worker runs a single SDK query (lines 106-296)
   - Simpler flow, just execute the prompt and handle results

5. **SDK Integration Pattern:**
   - Direct import of `query` function from SDK
   - `query()` is an async generator that yields messages
   - Messages include `assistant`, `user`, `tool_result`, and `result` types
   - Config passed as options object with `prompt`, `options` (cwd, model, budget, env, etc)

### Key Constraints
- Current implementation tightly couples the SDK to both worker and dispatcher
- RuntimeSelection type is defined but not used meaningfully (always "claude-code")
- No abstraction layer between the agent execution logic and the SDK implementation
- Both `agent-worker.ts` and `dispatcher.ts` independently import and use `query()`

## Dependencies

### What depends on the SDK:
- `agent-worker.ts` — Uses `query()` to execute agents
- `dispatcher.ts` — Uses `query()` directly in `dispatchPlanStep()` (line 359)
- Both depend on SDK types: `SDKMessage`, `SDKResultSuccess`, `SDKResultError`

### What depends on agent-worker.ts:
- `dispatcher.ts` spawns it via `spawnWorkerProcess()` (line 496)
- Process communication is one-way: worker updates store, parent monitors status

### SDK Message Types (from lines 16-17, 195):
```typescript
import type { SDKMessage, SDKResultSuccess, SDKResultError } from "@anthropic-ai/claude-agent-sdk";
```

## Existing Tests

- **src/orchestrator/__tests__/agent-worker.test.ts** — Tests the worker script directly:
  - Tests config file reading/deletion
  - Tests log file creation
  - Tests error handling when no config provided

- **src/orchestrator/__tests__/dispatcher.test.ts** — Tests dispatcher functionality

## Recommended Approach

### Phase 1: Define AgentRuntime Interface
1. **Create new file:** `src/orchestrator/runtime.ts`
   - Define `AgentRuntime` interface with methods:
     - `executeQuery(prompt, options)` — Async generator yielding SDK messages
     - `name` property — Returns runtime identifier ("claude-code", "openai-api", etc)
   - Interface should match the current `query()` signature and behavior
   - Include types for query options, messages, and results

2. **Expand RuntimeSelection type in types.ts:**
   - Change from literal `"claude-code"` to union of all supported runtimes
   - Example: `type RuntimeSelection = "claude-code" | "openai-api"`

### Phase 2: Implement Claude SDK Runtime
1. **Create `src/orchestrator/runtime-claude-sdk.ts`:**
   - Export `ClaudeSDKRuntime` class implementing `AgentRuntime`
   - Wrap existing `query()` function calls
   - Maintain backward compatibility with current behavior

2. **Add runtime factory/registry:**
   - Simple factory function in runtime.ts to get runtime by name
   - Returns appropriate runtime implementation

### Phase 3: Update Agent Worker
1. **Modify agent-worker.ts:**
   - Accept `runtime` parameter in WorkerConfig
   - Inject `AgentRuntime` instance instead of importing `query()` directly
   - Replace all `query()` calls with `runtime.executeQuery()`
   - Keep all existing logic intact, just swap the underlying implementation

2. **Update WorkerConfig interface (lines 34-48):**
   - Add `runtime: RuntimeSelection` field
   - Keep all other fields unchanged

### Phase 4: Update Dispatcher
1. **Modify dispatcher.ts:**
   - Accept runtime parameter in dispatch/resume options
   - Pass runtime selection to worker config
   - Update `dispatchPlanStep()` to use AgentRuntime abstraction
   - Keep `RuntimeSelection = "claude-code"` as default

### Phase 5: Testing
1. Create tests for AgentRuntime interface in new test file
2. Update existing agent-worker tests to work with new runtime parameter
3. Ensure backward compatibility (default to claude-code)

## Implementation Notes

### Potential Pitfalls
1. **Message Type Compatibility:** Different runtimes may have slightly different message formats. The interface should be flexible enough to accommodate variations while maintaining the contract.

2. **Error Handling:** Different runtimes may fail differently (rate limits, API keys, timeouts). Ensure error extraction logic in agent-worker.ts (lines 222-240) can handle runtime-specific error formats.

3. **Pipeline Phase Coordination:** The pipeline orchestration depends on specific SDK features (budget tracking, turn counting). Ensure AgentRuntime interface includes all necessary metadata.

4. **Backward Compatibility:** The dispatcher currently hardcodes "claude-code". Changing this should maintain defaults so existing code paths work without modification.

5. **Worker Process Spawning:** The worker config JSON is passed to child process. Ensure runtime configuration is serializable and properly passed through.

### Edge Cases to Consider
- Resume functionality relies on SDK's session persistence (line 143 in agent-worker.ts). Alternative runtimes may not support this.
- Environment variable handling for telemetry and SDK-specific options (lines 91-93, 325, 538)
- Rate limit detection and retry logic (lines 223-225, 267, 394) may need runtime-specific adjustments

## Summary

The task requires creating an abstraction layer (AgentRuntime interface) between the current agent execution logic and the Claude Agent SDK. The main challenge is that both `agent-worker.ts` and `dispatcher.ts` directly import and use the SDK's `query()` function. By creating a pluggable interface, we can:

1. Support multiple runtime implementations (Claude SDK, OpenAI, local execution, etc)
2. Maintain the current two-level process architecture
3. Keep all existing pipeline and orchestration logic intact
4. Enable future runtime options without modifying worker/dispatcher logic

The implementation should prioritize minimal changes to existing code paths while providing clear extension points for new runtimes.
