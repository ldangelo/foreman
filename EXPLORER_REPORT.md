# Explorer Report: Cost tracking with per-agent and per-phase breakdowns

## Summary

The foreman project currently tracks costs at the run level (total cost per seed execution), but lacks granular visibility into per-phase and per-agent cost distribution. The task is to add database schema changes, progress tracking enhancements, and UI/API improvements to break down costs by individual pipeline phases (explorer, developer, qa, reviewer) and track which agent/model handled each phase.

## Relevant Files

### Core Storage & Metrics

1. **src/lib/store.ts** (lines 32-83)
   - **Purpose**: Central data store with SQLite database schema and queries
   - **Current State**:
     - `Cost` interface (lines 32-40): Stores `tokens_in`, `tokens_out`, `cache_read`, `estimated_cost`, `recorded_at` at the run level
     - `RunProgress` interface (lines 64-75): Tracks `costUsd`, `tokensIn`, `tokensOut`, `currentPhase` (phase name only, not cost breakdown)
     - `Metrics` interface (lines 77-82): Aggregates `totalCost`, `totalTokens`, `tasksByStatus`, `costByRuntime` (no phase breakdown)
     - Database schema (lines 110-119): `costs` table with single record per cost event, no phase information
   - **Relevance**: Primary file requiring schema changes to support per-phase cost tracking

2. **src/orchestrator/agent-worker.ts** (lines 300-650)
   - **Purpose**: Standalone worker that orchestrates pipeline phases and tracks progress
   - **Current State**:
     - Lines 310-399: `runPhase()` function executes individual phases, accumulates costs via `progress.costUsd += phaseResult.total_cost_usd` (line 372)
     - Line 319: Sets `progress.currentPhase = role` to track current phase name
     - Line 372: Accumulates total cost but doesn't record per-phase breakdown
     - Lines 529, 551, 560, 590, 612, 617: Log events with `phase` metadata but no persistent phase cost storage
     - Line 374: Updates progress with accumulated totals only
   - **Relevance**: Where phase costs need to be recorded to database

3. **src/orchestrator/roles.ts** (lines 13-46)
   - **Purpose**: Defines role configuration (model, max budget) for each pipeline phase
   - **Current State**:
     - `ROLE_CONFIGS` maps phase names to models: explorer (haiku), developer (sonnet), qa (sonnet), reviewer (sonnet)
     - Each phase has a different `model` property
   - **Relevance**: Agent/model type is defined here; needed for per-agent cost attribution

### Display & Metrics

4. **src/cli/watch-ui.ts** (lines 1-150+)
   - **Purpose**: Real-time status display for running agents
   - **Current State**:
     - Line 81: Displays `progress.costUsd.toFixed(4)` as total cost
     - Line 125: Shows `progress.currentPhase` in status output
     - Lines 135-150: `poll()` function aggregates run costs into totals
   - **Relevance**: Where per-phase cost breakdown will be displayed

5. **src/cli/commands/status.ts** (lines 134-149)
   - **Purpose**: CLI status command showing project overview
   - **Current State**:
     - Lines 134-136: Displays `progress.costUsd` from active runs
     - Lines 143-149: Shows `metrics.totalCost` and metrics aggregated by runtime
   - **Relevance**: Where metrics breakdown will be displayed in status output

### Tests

6. **src/lib/__tests__/store-metrics.test.ts** (lines 1-96)
   - **Purpose**: Tests cost tracking and metrics queries
   - **Current State**:
     - Lines 21-42: Tests `getCosts()` with runtime grouping (agent_type from run)
     - Lines 87-95: Tests `getMetrics()` for empty projects
   - **Relevance**: Existing test patterns for metrics queries; will need new tests for phase breakdown

7. **src/orchestrator/__tests__/agent-worker.test.ts** & related
   - **Purpose**: Tests agent worker pipeline orchestration
   - **Relevance**: May need updates to verify phase cost tracking

## Architecture & Patterns

### Pipeline Phase Execution
- **Sequential phases**: Explorer → Developer ⇄ QA → Reviewer → Finalize
- **Phase isolation**: Each phase runs as a separate SDK `query()` call with its own budget limit
- **Cost accumulation**: Phase results include `costUsd` which is summed into `progress.costUsd`
- **Agent assignment**: Phase → Agent mapping is defined in `ROLE_CONFIGS` (hardcoded per phase)

### Current Cost Tracking Pattern
```typescript
// agent-worker.ts line 372
progress.costUsd += phaseResult.total_cost_usd;
progress.tokensIn += phaseResult.usage.input_tokens;
progress.tokensOut += phaseResult.usage.output_tokens;
```

### Progress Update Pattern
```typescript
// agent-worker.ts line 320
progress.currentPhase = role;
store.updateRunProgress(runId, progress);
```

### Event Logging Pattern
```typescript
// agent-worker.ts line 529
store.logEvent(projectId, "complete", { seedId, phase: "explorer", costUsd: result.costUsd }, runId);
```

### Metrics Query Pattern
```typescript
// store.ts lines 437-508
getMetrics(projectId, since) → Metrics {
  totalCost, totalTokens, tasksByStatus, costByRuntime
}
```

## Dependencies

### What Depends on Cost Data
1. **watch-ui.ts**: Reads `RunProgress.costUsd` for display
2. **status.ts**: Reads `Metrics.totalCost` and per-run progress
3. **CLI output**: Shows cost summaries to users
4. **Events**: Cost data logged in event details (for auditing)

### What Cost Tracking Depends On
1. **SDK result objects**: Provide `total_cost_usd` after each phase
2. **RunProgress in SQLite**: Stores aggregated progress
3. **Events table**: Logs phase-specific costs
4. **Phase executor (runPhase)**: Accumulates and records costs

### New Dependencies After Implementation
1. Phase cost storage (new table or columns)
2. Per-phase cost queries in Store
3. UI components to display phase breakdown

## Existing Tests

### Coverage Areas
1. **store-metrics.test.ts**: Cost aggregation, filtering by project/date, runtime grouping
2. **agent-worker tests**: Phase execution, progress updates (but not detailed cost assertions)
3. **dispatcher tests**: Cost logging in events

### Test Gap
- No tests verify per-phase cost breakdown after implementation
- No tests verify per-agent cost attribution
- No integration tests for full pipeline cost tracking

## Recommended Approach

### Phase 1: Extend RunProgress Data Structure
1. **File**: `src/lib/store.ts` (lines 64-75)
   - Add to `RunProgress` interface:
     ```typescript
     costByPhase?: Record<string, number>;      // e.g. { explorer: 0.10, developer: 0.50 }
     agentByPhase?: Record<string, string>;     // e.g. { explorer: "claude-haiku", developer: "claude-sonnet" }
     ```
   - Benefits: No DB schema change needed; stores data in existing progress JSON column

2. **Rationale**:
   - Minimal schema disruption (reuses existing JSON column)
   - Maintains backwards compatibility (optional fields)
   - Supports querying phase costs from existing queries

### Phase 2: Record Per-Phase Costs in agent-worker.ts
1. **File**: `src/orchestrator/agent-worker.ts` (lines 310-399, 501-650)
   - In `runPhase()` function, after line 372:
     ```typescript
     progress.costByPhase ??= {};
     progress.costByPhase[role] = phaseResult.total_cost_usd;
     progress.agentByPhase ??= {};
     progress.agentByPhase[role] = roleConfig.model;
     ```
   - Update line 320 to pass role as parameter for attribution

2. **Rationale**:
   - Records cost immediately after each phase completes
   - Captures agent/model used for that phase
   - Accumulation pattern already established

### Phase 3: Add Per-Phase Cost Query Methods to Store
1. **File**: `src/lib/store.ts` (lines 349-508)
   - Add method to extract phase costs from RunProgress:
     ```typescript
     getCostBreakdown(runId: string): { byPhase: Record<string, number>, byAgent: Record<string, number> }
     ```
   - Add method to aggregate phase costs across runs:
     ```typescript
     getPhaseMetrics(projectId, since?): { totalByPhase: Record<string, number>, runsByPhase: Record<string, number> }
     ```

2. **Rationale**:
   - Keeps phase cost logic in store layer
   - Enables future UI/reporting features
   - Follows existing metrics pattern

### Phase 4: Update Metrics Interface
1. **File**: `src/lib/store.ts` (lines 77-82)
   - Extend `Metrics` interface:
     ```typescript
     export interface Metrics {
       totalCost: number;
       totalTokens: number;
       tasksByStatus: Record<string, number>;
       costByRuntime: Array<{ run_id: string; cost: number; duration_seconds: number | null }>;
       costByPhase?: Record<string, number>;     // NEW
       agentCostBreakdown?: Record<string, number>; // NEW (cost per model)
     }
     ```
   - Update `getMetrics()` to calculate phase costs from progress records

2. **Rationale**:
   - Aggregates phase-level data for reporting
   - Follows existing metrics pattern
   - Backwards compatible (optional fields)

### Phase 5: Update UI Display
1. **File**: `src/cli/watch-ui.ts` (lines 57-120)
   - After cost display (line 81), add phase breakdown:
     ```typescript
     if (progress.costByPhase) {
       for (const [phase, cost] of Object.entries(progress.costByPhase).sort()) {
         lines.push(`  ${phase.padEnd(10)} $${cost.toFixed(4)}`);
       }
     }
     ```

2. **File**: `src/cli/commands/status.ts` (lines 143-149)
   - Add phase cost summary after total cost:
     ```typescript
     if (metrics.costByPhase) {
       console.log(`  By phase: ${JSON.stringify(metrics.costByPhase)}`);
     }
     ```

3. **Rationale**:
   - Shows breakdown where users look for cost info
   - Non-breaking changes to existing display
   - Uses existing progress/metrics data

### Phase 6: Add Tests
1. **File**: `src/lib/__tests__/store-metrics.test.ts`
   - Add test for per-phase cost extraction
   - Add test for agent cost aggregation
   - Test backwards compatibility (runs without phase data)

2. **Rationale**:
   - Ensures new functionality works correctly
   - Catches regressions in metrics
   - Documents expected behavior

## Potential Pitfalls & Edge Cases

1. **Backwards Compatibility**
   - Old progress records may not have `costByPhase` field
   - **Solution**: Use optional chaining, check for existence before accessing
   - **Test**: Add test for runs without phase data

2. **Phase Attribution Accuracy**
   - Single-agent mode doesn't track phases (no `runPhase()` calls)
   - **Solution**: Only populate phase costs in pipeline mode; single-agent shows zero phase breakdown
   - **Handling**: Check `progress.currentPhase` existence before displaying phase breakdown

3. **JSON Serialization**
   - Phase cost records are stored in SQLite as JSON strings
   - **Solution**: Ensure proper serialization/deserialization in `updateRunProgress()`
   - **Current pattern**: Already working (line 338 uses `JSON.stringify()`)

4. **Phase Identification**
   - Phase names are hardcoded strings: "explorer", "developer", "qa", "reviewer", "finalize"
   - Finalize phase has no SDK query, so no cost
   - **Solution**: Only record costs for phases that call `runPhase()` (skip finalize)
   - **Handling**: Check `PhaseResult` exists before recording

5. **Concurrent Updates**
   - SQLite WAL mode handles concurrent progress updates
   - **Solution**: No changes needed; existing pattern already safe
   - **Verified**: Line 148 sets `pragma("journal_mode = WAL")`

6. **Missing Phase Data in Events**
   - Current events already logged with phase metadata (line 529, etc.)
   - **Solution**: Phase costs should match event logging pattern
   - **Benefit**: Cross-validation possible via events table

## Implementation Order

1. ✅ Update `RunProgress` interface (non-breaking, backwards compatible)
2. Modify `agent-worker.ts` to record phase costs
3. Add query methods to `Store`
4. Update `Metrics` interface
5. Update UI displays (watch-ui.ts and status.ts)
6. Add comprehensive tests
7. Test with real pipeline runs to validate cost attribution

## Summary of Changes

| File | Type | Scope |
|------|------|-------|
| store.ts | Schema | Add optional `costByPhase` and `agentByPhase` to RunProgress |
| store.ts | Query | Add `getCostBreakdown()` and `getPhaseMetrics()` methods |
| store.ts | Type | Extend Metrics interface with phase breakdown fields |
| agent-worker.ts | Logic | Record phase costs after each phase in `runPhase()` |
| watch-ui.ts | Display | Show phase cost breakdown in running agent cards |
| status.ts | Display | Show aggregate phase costs in status summary |
| store-metrics.test.ts | Tests | Add tests for phase cost extraction and aggregation |

