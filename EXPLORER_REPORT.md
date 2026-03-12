# Explorer Report: Replace maxTurns with maxBudgetUsd for pipeline phase limits

## Summary
The codebase uses `maxTurns` to limit SDK query execution in the agent orchestration pipeline. This needs to be replaced with `maxBudgetUsd` to enforce budget-based limits instead of turn-based limits. The change affects the role configurations, phase execution, and logging.

## Relevant Files

### 1. **src/orchestrator/roles.ts** (lines 13-46)
- **Purpose**: Defines role configurations for the specialization pipeline (explorer, developer, qa, reviewer)
- **Current State**:
  - `RoleConfig` interface has `maxTurns: number` property (line 16)
  - `ROLE_CONFIGS` object defines maxTurns for each phase:
    - explorer: 30 turns
    - developer: 80 turns
    - qa: 30 turns
    - reviewer: 20 turns
- **Relevance**: Primary file that needs modification - interface definition and config values

### 2. **src/orchestrator/agent-worker.ts** (lines 310-399)
- **Purpose**: Standalone worker process that runs individual SDK query calls for each pipeline phase
- **Current State**:
  - Line 322: Logs `maxTurns=${roleConfig.maxTurns}` when starting a phase
  - Line 337: Passes `maxTurns: roleConfig.maxTurns` to the SDK `query()` options
  - Line 225: Already handles `error_max_budget_usd` error subtype (future-ready)
- **Relevance**: Needs to replace logging and pass maxBudgetUsd to query() options instead

### 3. **src/orchestrator/dispatcher.ts** (line 361)
- **Purpose**: Dispatches beads to agents, handles one-off planning steps
- **Current State**:
  - Line 361: Uses `maxTurns: 50` for `dispatchPlanStep()` SDK query
- **Relevance**: Secondary location needing update for consistency with phase limits

## Architecture & Patterns

### Pipeline Orchestration Pattern
- **Sequential phases**: Explorer → Developer ⇄ QA → Reviewer → Finalize
- **Phase execution**: Each phase runs as a separate `query()` call with its own config
- **Error handling**: Already recognizes `error_max_budget_usd` error subtype (agent-worker.ts:225)
- **Naming convention**: `roleConfig.maxTurns` → should become `roleConfig.maxBudgetUsd`

### SDK Integration
- The Anthropic Claude Agent SDK supports `maxBudgetUsd?: number` in query options (confirmed in sdk.d.ts)
- Budget limits are enforced by the SDK during query execution
- Error subtype `error_max_budget_usd` is already handled by the error detection logic

### Role Config Structure
```typescript
export interface RoleConfig {
  role: AgentRole;
  model: ModelSelection;
  maxTurns: number;              // ← Change to maxBudgetUsd: number
  reportFile: string;
}
```

## Dependencies

### What Uses maxTurns
1. **agent-worker.ts**:
   - Imports `ROLE_CONFIGS` from roles.ts
   - Calls `roleConfig.maxTurns` in `runPhase()` function
   - Passes value to SDK `query()` options

2. **dispatcher.ts**:
   - Hard-coded `maxTurns: 50` in `dispatchPlanStep()`
   - No import from roles.ts (independent configuration)

3. **roles.ts**:
   - Defines the canonical values for all phases
   - No external dependencies on the property name

### SDK API Contract
- The SDK's `query()` function accepts `maxBudgetUsd?: number` parameter
- When a query exceeds budget, SDK returns error with `subtype: "error_max_budget_usd"`
- No backwards compatibility issues - this is a parameter replacement

## Existing Tests

### Test Files
1. **src/orchestrator/__tests__/roles.test.ts**
   - Tests ROLE_CONFIGS structure (all roles defined, models correct)
   - Tests prompt templates (context injection, read-only instructions)
   - Tests verdict/issue parsing from reports
   - **Status**: Tests focus on config existence, not specific maxTurns values
   - **Impact**: Tests will likely pass after renaming property (no assertions on maxTurns specifically)

2. **src/orchestrator/__tests__/agent-worker.test.ts**
   - Tests worker process initialization and logging
   - Tests config file handling and deletion
   - **Status**: No assertions on maxTurns values
   - **Impact**: Will need to verify logging format still works with maxBudgetUsd

### Test Coverage of Limits
- No tests directly assert maxTurns values
- No tests verify budget enforcement
- New tests may be beneficial to ensure budget limits work correctly

## Recommended Approach

### Phase 1: Update Role Configurations
1. Update `RoleConfig` interface in roles.ts:
   - Rename `maxTurns: number` → `maxBudgetUsd: number`

2. Update `ROLE_CONFIGS` values with reasonable budget estimates:
   - Need to estimate per-model costs based on token usage
   - Suggested starting points (requires validation):
     - **explorer** (haiku, 30 turns): $0.50-$1.00 USD
     - **developer** (sonnet, 80 turns): $5.00-$10.00 USD
     - **qa** (sonnet, 30 turns): $2.00-$4.00 USD
     - **reviewer** (sonnet, 20 turns): $1.50-$3.00 USD
   - Also update **dispatchPlanStep** budget in dispatcher.ts (currently maxTurns: 50)

### Phase 2: Update Phase Execution in agent-worker.ts
1. Update `runPhase()` function:
   - Line 322: Change log format to show `maxBudgetUsd=${roleConfig.maxBudgetUsd}`
   - Line 337: Pass `maxBudgetUsd: roleConfig.maxBudgetUsd` instead of `maxTurns`

2. Verify error handling:
   - Line 225 already checks for `error_max_budget_usd` — keep as-is

### Phase 3: Update Dispatcher Planning
1. In dispatcher.ts `dispatchPlanStep()`:
   - Replace `maxTurns: 50` with appropriate `maxBudgetUsd` value (suggest $3.00-$5.00)

### Phase 4: Update Tests & Documentation
1. roles.test.ts:
   - Update any hardcoded expectations if tests fail
   - Consider adding assertions for budget values being positive numbers

2. agent-worker.test.ts:
   - Verify logging format with new maxBudgetUsd parameter
   - Check that log output still contains relevant budget information

## Potential Pitfalls & Edge Cases

1. **Budget Estimation Accuracy**
   - Turn counts are discrete (explorer: 30) but budgets must be estimated
   - Per-model costs vary (Haiku cheaper than Sonnet than Opus)
   - May need to adjust budgets based on real usage data

2. **Error Handling Clarity**
   - Error message when budget exceeded may be different from turn limits
   - Current code checks `error_max_budget_usd` — verify message consistency

3. **Logging Clarity**
   - Phase startup logs currently show `maxTurns=30`
   - Should show `maxBudgetUsd=$X.XX` for clarity

4. **Backwards Compatibility**
   - Existing stored run data uses turns in progress tracking (agent-worker.ts line 196)
   - Budget limits don't track in progress.turns — separate concerns
   - No data migration needed (turns are tracked separately from limits)

5. **Dispersion Across Files**
   - dispatcher.ts has a hard-coded maxTurns value (50) separate from roles.ts
   - Consider whether plan steps should use same budget as phases or different

## Next Steps for Developer

1. Research typical costs per phase from production data (if available)
2. Update roles.ts with maxBudgetUsd values (start conservative)
3. Update agent-worker.ts runPhase() logging and query options
4. Update dispatcher.ts dispatchPlanStep() budget
5. Run tests to verify no regressions
6. Monitor first few runs with new budgets to validate appropriateness
