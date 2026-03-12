# Explorer Report: Extract per-phase maxBudgetUsd to environment variables

## Summary

The codebase currently has hardcoded budget limits for each agent phase (explorer, developer, qa, reviewer) and plan steps. These values should be extracted to environment variables to allow runtime configuration without code changes. This enables different deployments to have different budget constraints based on operational needs.

**Current hardcoded values:**
- Explorer: `$1.00`
- Developer: `$5.00`
- QA: `$3.00`
- Reviewer: `$2.00`
- Plan step: `$3.00`

## Relevant Files

### 1. **src/orchestrator/roles.ts** (lines 13-46)
- **Purpose**: Defines `RoleConfig` interface and `ROLE_CONFIGS` object for the four pipeline phases
- **Current State**:
  - `RoleConfig` interface has `maxBudgetUsd: number` property (line 16)
  - `ROLE_CONFIGS` hardcodes budget values in-place:
    - explorer: 1.00 (line 25)
    - developer: 5.00 (line 31)
    - qa: 3.00 (line 37)
    - reviewer: 2.00 (line 43)
- **Relevance**: Primary location for role budgets; needs to read from environment variables with fallback to hardcoded defaults

### 2. **src/orchestrator/dispatcher.ts** (lines 25-26, 366)
- **Purpose**: Dispatches work to agents and runs planning steps
- **Current State**:
  - Line 26: `PLAN_STEP_MAX_BUDGET_USD = 3.00` is hardcoded constant
  - Line 366: Used in `dispatchPlanStep()` to set `maxBudgetUsd` for plan queries
- **Relevance**: Secondary location; the plan step budget should also be configurable via environment variable

### 3. **src/orchestrator/agent-worker.ts** (lines 310-399, 337)
- **Purpose**: Executes each pipeline phase as a separate SDK query
- **Current State**:
  - Line 322: Logs the phase start including `maxBudgetUsd=${roleConfig.maxBudgetUsd}`
  - Line 337: Passes `maxBudgetUsd: roleConfig.maxBudgetUsd` to SDK query options
- **Relevance**: Consumer of the role config budgets; no changes needed here (just uses what's provided in ROLE_CONFIGS)

### 4. **src/orchestrator/__tests__/roles.test.ts** (lines 36-58)
- **Purpose**: Tests for ROLE_CONFIGS structure and values
- **Current State**:
  - Lines 36-44: Tests that budgets are positive and in correct order
  - Lines 46-52: Tests that developer and reviewer have exact expected values ($5.00 and $2.00)
  - Lines 54-58: Test asserts that configs do NOT have `maxTurns` property (guards against regression)
- **Relevance**: Tests verify budget values; need to update assertions if default values change

## Architecture & Patterns

### Current Configuration Pattern
The codebase uses:
1. **Hardcoded constants** for `PLAN_STEP_MAX_BUDGET_USD` in dispatcher.ts
2. **Inline literals** in `ROLE_CONFIGS` object in roles.ts
3. **Direct imports** of `ROLE_CONFIGS` in agent-worker.ts

### SDK Integration
- The Anthropic Claude Agent SDK accepts `maxBudgetUsd?: number` in query options
- Budget enforcement is handled by the SDK — when exceeded, it returns error with `subtype: "error_max_budget_usd"`
- Error handling already recognizes this error type (agent-worker.ts line 225)

### Environment Variable Conventions
The codebase already uses environment variables in several places:
- `process.env.HOME` — for path construction
- `process.env.PATH` — for executable discovery
- `process.env.CLAUDE_CODE_ENABLE_TELEMETRY` — for telemetry control
- `process.env.OTEL_RESOURCE_ATTRIBUTES` — for observability

Suggested convention for budget env vars:
- `FOREMAN_EXPLORER_MAX_BUDGET_USD` — explorer phase budget
- `FOREMAN_DEVELOPER_MAX_BUDGET_USD` — developer phase budget
- `FOREMAN_QA_MAX_BUDGET_USD` — QA phase budget
- `FOREMAN_REVIEWER_MAX_BUDGET_USD` — reviewer phase budget
- `FOREMAN_PLAN_STEP_MAX_BUDGET_USD` — plan step budget

## Dependencies

### What Uses These Values
1. **agent-worker.ts `runPhase()` function**:
   - Imports `ROLE_CONFIGS` from roles.ts (line 21)
   - Reads `roleConfig.maxBudgetUsd` for each phase
   - Passes to SDK query options (line 337)

2. **dispatcher.ts `dispatchPlanStep()` function**:
   - Uses `PLAN_STEP_MAX_BUDGET_USD` constant (line 366)
   - Passes to SDK query options in planning queries

3. **roles.test.ts**:
   - Asserts specific budget values (lines 46-52)
   - Tests budget ordering and positivity (lines 36-44)

### What This Depends On
- Node.js environment (process.env)
- Anthropic SDK (accepts maxBudgetUsd parameter)
- No external configuration files or libraries needed

## Existing Tests

### Test Coverage
1. **src/orchestrator/__tests__/roles.test.ts** (lines 36-58)
   - `"all roles have positive maxBudgetUsd values"` (line 36): Verifies all budgets > 0
   - `"explorer has lower budget than developer"` (line 42): Verifies budget ordering
   - `"developer budget is $5.00"` (line 46): Pinned value test
   - `"reviewer budget is $2.00"` (line 50): Pinned value test
   - `"all role configs have no maxTurns property"` (line 54): Guards against regression to old API

2. **src/orchestrator/__tests__/agent-worker.test.ts**
   - Tests worker process initialization and config file handling
   - May need updates to verify environment variable loading

### Test Impact
- Existing tests will need updates if environment variable defaults differ from current hardcoded values
- New tests should verify that:
  - Environment variables are correctly read
  - Defaults are used when env vars are not set
  - Invalid env var values are handled gracefully

## Recommended Approach

### Phase 1: Create Environment Variable Helpers
1. Create a new file `src/orchestrator/config.ts` (or add to roles.ts) to:
   - Define environment variable names as constants
   - Implement `getBudgetFromEnv(varName: string, defaultValue: number): number`
   - Parse and validate environment variable values

### Phase 2: Update roles.ts
1. Modify `ROLE_CONFIGS` to read budgets from environment variables:
   ```typescript
   export const ROLE_CONFIGS: Record<...> = {
     explorer: {
       role: "explorer",
       model: "claude-haiku-4-5-20251001",
       maxBudgetUsd: getBudgetFromEnv("FOREMAN_EXPLORER_MAX_BUDGET_USD", 1.00),
       reportFile: "EXPLORER_REPORT.md",
     },
     // ... similarly for developer, qa, reviewer
   };
   ```

### Phase 3: Update dispatcher.ts
1. Change `PLAN_STEP_MAX_BUDGET_USD` from hardcoded constant to environment-driven value:
   ```typescript
   const PLAN_STEP_MAX_BUDGET_USD = getBudgetFromEnv("FOREMAN_PLAN_STEP_MAX_BUDGET_USD", 3.00);
   ```

### Phase 4: Test Updates
1. Update existing tests in `roles.test.ts` to verify:
   - Defaults are correct when env vars not set
   - Env vars override defaults
   - Invalid values are handled (or document expected behavior)

2. Consider adding integration tests in `agent-worker.test.ts` to verify env vars work end-to-end

### Phase 5: Documentation
1. Add environment variable documentation to README.md or docs/CONFIG.md
2. Document all `FOREMAN_*_MAX_BUDGET_USD` variables and their defaults

## Potential Pitfalls & Edge Cases

1. **Env Var Parsing**
   - Environment variables are always strings; need to parse as numbers
   - Must handle invalid values (non-numeric strings, negative numbers, zero)
   - Suggestion: Use `parseFloat()` with validation, fall back to default on error

2. **Type Safety**
   - TypeScript should enforce that `maxBudgetUsd` is a number
   - Env var reading must return validated numbers, not strings

3. **Test Isolation**
   - Tests that use environment variables should either:
     - Save/restore `process.env` state before/after
     - Use mocking libraries to avoid side effects
     - Explicitly set env vars as part of test setup

4. **Backward Compatibility**
   - All environment variables should be optional
   - Hardcoded defaults should match current production values
   - Allows existing deployments to work without .env files

5. **Documentation**
   - Must clearly explain that env vars override hardcoded defaults
   - Should document example configurations for different scenarios (dev, staging, prod)

6. **Validation**
   - Budget values should be positive numbers
   - Consider documenting minimum/maximum reasonable values
   - Current defaults: $1-5 per phase; unlikely to go below $0.50 or above $20

## Implementation Checklist

- [ ] Create config.ts with `getBudgetFromEnv()` helper
- [ ] Update ROLE_CONFIGS in roles.ts to use env vars
- [ ] Update PLAN_STEP_MAX_BUDGET_USD in dispatcher.ts to use env vars
- [ ] Update existing tests to work with env vars
- [ ] Add tests to verify env var loading behavior
- [ ] Document environment variables in README or separate CONFIG.md
- [ ] Verify no regressions: all tests pass with default values
- [ ] Manual testing: set env vars and verify they're used correctly

## Next Steps for Developer

1. Implement the config helper function (`getBudgetFromEnv`)
2. Refactor ROLE_CONFIGS to read from environment with sensible defaults
3. Refactor PLAN_STEP_MAX_BUDGET_USD similarly
4. Run the test suite and update any failing tests
5. Add new tests to verify environment variable loading
6. Test manually by setting environment variables and verifying they're applied
