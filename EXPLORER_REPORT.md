# Explorer Report: Extract per-phase model selection to environment variables

## Summary
The Foreman orchestrator currently uses hard-coded model selections for each pipeline phase (explorer, developer, qa, reviewer). The task is to extract these selections to environment variables, allowing dynamic configuration without code changes.

## Relevant Files

### `src/orchestrator/roles.ts` (PRIMARY TARGET)
- **Lines 21-46**: `ROLE_CONFIGS` object definition
  - Hard-coded model assignments per phase:
    - explorer: `claude-haiku-4-5-20251001` (budget: $1.00)
    - developer: `claude-sonnet-4-6` (budget: $5.00)
    - qa: `claude-sonnet-4-6` (budget: $3.00)
    - reviewer: `claude-sonnet-4-6` (budget: $2.00)
  - Exports `RoleConfig` interface (lines 13-19) with fields: role, model, maxBudgetUsd, reportFile
  - Currently a static record used at runtime

### `src/orchestrator/agent-worker.ts` (CONSUMER)
- **Line 21**: Imports `ROLE_CONFIGS`
- **Line 318**: `const roleConfig = ROLE_CONFIGS[role];` — retrieves config for current phase
- **Line 334**: Uses `roleConfig.model` to select model for SDK query
- **Line 337**: Uses `roleConfig.maxBudgetUsd` to set budget limit
- **Lines 501-650**: `runPipeline()` function orchestrates phases sequentially (explorer → developer → qa → reviewer → finalize)
- **Lines 310-399**: `runPhase()` function executes each phase with model/budget from `roleConfig`

### `src/orchestrator/__tests__/roles.test.ts` (TESTS TO UPDATE)
- **Lines 20-26**: Tests verify specific models for explorer/developer phases
- **Lines 36-51**: Tests verify budget values are positive and within expectations
- **Lines 54-58**: Test explicitly checks that maxTurns property does NOT exist

### `src/orchestrator/types.ts`
- **Line 5**: Defines `ModelSelection` type: `"claude-opus-4-6" | "claude-sonnet-4-6" | "claude-haiku-4-5-20251001"`
- Used by `ROLE_CONFIGS` and throughout the codebase

## Architecture & Patterns

### Current Model Selection Pattern
1. **Static Configuration**: `ROLE_CONFIGS` is a module-level constant initialized at import time
2. **Per-Phase Granularity**: Each phase (explorer, developer, qa, reviewer) has its own model
3. **Pipeline Architecture**: Each phase runs as a separate SDK query() session with sequential execution
4. **Budget Constraints**: Each phase has a `maxBudgetUsd` limit (separate from model cost)

### Environment Variable Convention
The codebase shows a pattern of using `process.env` for configuration:
- Checked in: `dispatcher.ts`, `agent-worker.ts`, `decomposer-llm.ts`
- Typical pattern: `process.env.HOME ?? "/tmp"` with fallback defaults
- No centralized env config file (no .env files found in repo)

### Type Safety
The codebase uses TypeScript with strong typing:
- `ModelSelection` type restricts to 3 valid models
- `ROLE_CONFIGS` typed as `Record<Exclude<AgentRole, "lead" | "worker">, RoleConfig>`
- Agent roles are union type: `"lead" | "explorer" | "developer" | "qa" | "reviewer" | "worker"`

## Dependencies

### Inbound Dependencies (what depends on ROLE_CONFIGS)
1. `agent-worker.ts` — uses it to configure SDK query for each phase
2. `roles.test.ts` — tests the configuration values
3. `agent-worker-team.test.ts` — likely uses it indirectly through agent-worker

### Outbound Dependencies (what ROLE_CONFIGS depends on)
1. `types.ts` — imports `ModelSelection` and `AgentRole` types
2. Module-level export (no runtime dependencies)

## Existing Tests

### Test Files Covering ROLE_CONFIGS
1. **`src/orchestrator/__tests__/roles.test.ts`** (59 lines total)
   - Lines 12-59: Comprehensive test suite for ROLE_CONFIGS
   - Tests cover: config existence, model assignments, budget values, budget ordering
   - Will need updates to test environment variable fallback behavior

2. **`src/orchestrator/__tests__/agent-worker.test.ts`**
   - Tests agent-worker initialization and execution
   - References models in test config setup (line 45: `"claude-sonnet-4-6"`)
   - May need minor updates for env var testing

3. **`src/orchestrator/__tests__/agent-worker-team.test.ts`**
   - Tests pipeline orchestration including phase execution
   - Likely references ROLE_CONFIGS indirectly

## Recommended Approach

### Phase 1: Environment Variable Integration
1. **Create function to build ROLE_CONFIGS from environment variables**
   - Location: Add to `src/orchestrator/roles.ts`
   - Function: `function buildRoleConfigs(): Record<Exclude<AgentRole, "lead" | "worker">, RoleConfig>`
   - Logic:
     - Read environment variables: `FOREMAN_EXPLORER_MODEL`, `FOREMAN_DEVELOPER_MODEL`, etc.
     - Fall back to current hard-coded defaults if env vars not set
     - Validate model values against `ModelSelection` type
     - Return constructed `ROLE_CONFIGS` object

2. **Update ROLE_CONFIGS initialization**
   - Replace static object with call to `buildRoleConfigs()`
   - Keep backward compatibility with defaults

3. **Environment variable naming convention**
   - Proposed: `FOREMAN_{PHASE}_MODEL` where PHASE is uppercase (EXPLORER, DEVELOPER, QA, REVIEWER)
   - Examples:
     - `FOREMAN_EXPLORER_MODEL=claude-sonnet-4-6` — override explorer to use sonnet
     - `FOREMAN_DEVELOPER_MODEL=claude-opus-4-6` — upgrade developer to opus
     - `FOREMAN_QA_MODEL=claude-haiku-4-5-20251001` — downgrade QA to haiku

### Phase 2: Update Tests
1. **Add tests for environment variable overrides**
   - Test each phase model can be overridden
   - Test invalid model values are rejected
   - Test fallback to defaults when env vars unset
   - Test env var takes precedence over hardcoded default

2. **Update existing tests to remain passing**
   - Tests that check specific model assignments should still pass with defaults
   - May need to use `beforeEach` to set/unset env vars

3. **Test file: `src/orchestrator/__tests__/roles.test.ts`**
   - Add new describe block: `"ROLE_CONFIGS with environment variables"`
   - Tests should cover all 4 phases with various env var combinations

### Phase 3: Documentation (optional but recommended)
1. Document the environment variable options in README or code comments
2. Show examples of common configurations (performance vs cost)

## Potential Pitfalls & Edge Cases

1. **Type Validation**: Environment variable values must be validated against `ModelSelection` type
   - Risk: Invalid model name from env var crashes at runtime
   - Solution: Validate at config initialization with helpful error message

2. **Test Isolation**: Tests that set env vars must restore them afterward
   - Risk: Test pollution, one test affects another
   - Solution: Use `beforeEach`/`afterEach` to set/restore env vars

3. **Logging and Debugging**: The phase startup log (line 322 in agent-worker.ts) shows which model is in use
   - Risk: Users may not realize they're using env-var-provided model
   - Solution: Log message should clarify if model came from env var vs default

4. **Multi-Agent Concurrency**: ROLE_CONFIGS is read at runtime during pipeline execution
   - Risk: If env vars change between agents, inconsistent behavior
   - Solution: Document that env vars should be stable during a run

5. **Backward Compatibility**: Existing scripts that don't set env vars should continue working
   - Risk: Breaking change if defaults are removed
   - Solution: Keep hard-coded defaults as fallback (current implementation)

## Implementation Notes

- **Entry point for changes**: `src/orchestrator/roles.ts` lines 21-46
- **No new files needed**: Integrate directly into existing roles.ts
- **Type safety maintained**: `ModelSelection` type validates all model values
- **Tests location**: `src/orchestrator/__tests__/roles.test.ts` (add new test suite)
- **No configuration files needed**: Use process.env directly (matches project pattern)
