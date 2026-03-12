# Explorer Report: Cost tracking with per-agent and per-phase breakdowns

## Summary
The task is to add cost tracking that breaks down expenses by both **agent** (model/runtime used) and **phase** (explorer, developer, qa, reviewer) in the pipeline. Currently, costs are tracked at the run level only, with phase costs logged in event details. This report outlines what needs to be changed to support structured per-agent and per-phase cost analytics.

## Relevant Files

### Core Stores & Models
1. **src/lib/store.ts** (lines 32-40, 348-392)
   - **Purpose**: SQLite state store with Cost, Run, and Metrics interfaces
   - **Current State**:
     - `Cost` interface: `{id, run_id, tokens_in, tokens_out, cache_read, estimated_cost, recorded_at}`
     - `costs` table stores costs linked to `run_id` only (no phase column)
     - `recordCost()` method: inserts cost record without phase info
     - `getCosts()` method: queries costs with optional project/date filtering
     - `getMetrics()` method: aggregates cost by runtime via JOIN with runs
   - **Gap**: No schema support for per-phase costs; no query methods for phase-based aggregation
   - **Relevance**: Primary file needing schema migration and new query methods

2. **src/lib/__tests__/store-metrics.test.ts**
   - **Purpose**: Tests for metrics queries
   - **Current State**:
     - Tests `getCosts()` with project/date filtering
     - Tests `costByRuntime` aggregation
     - Tests `getMetrics()` empty state
   - **Gap**: No tests for per-phase costs or agent+phase 2D breakdown
   - **Relevance**: Will need new test cases for phase-based metrics

### Orchestration & Phase Execution
3. **src/orchestrator/agent-worker.ts** (lines 300-399, 501-600)
   - **Purpose**: Runs the full pipeline with sequential phases
   - **Current State**:
     - `PhaseResult` interface has `{success, costUsd, turns, error}`
     - Each phase accumulates costs: `progress.costUsd += phaseResult.total_cost_usd`
     - Phase completion logged: `store.logEvent(projectId, "complete", { beadId, phase: "explorer", costUsd: result.costUsd }, runId)`
     - `RunProgress` interface includes `currentPhase?: string` field
     - Costs are summed but not broken down per phase in the database
   - **Gap**: Cost data exists per-phase but isn't persisted to database in structured format
   - **Relevance**: Needs to record per-phase costs to database for later querying

4. **src/orchestrator/roles.ts** (lines 13-46)
   - **Purpose**: Defines role configurations with model, budget, and report file
   - **Current State**:
     - `ROLE_CONFIGS` defines config for: explorer, developer, qa, reviewer
     - Each has `model`, `maxBudgetUsd`, `reportFile`
     - Phases run in `runPhase()` via agent-worker.ts
   - **Relevance**: Phase names and models are defined here; useful reference for phase list

### CLI & Display
5. **src/cli/watch-ui.ts** (lines 57-100)
   - **Purpose**: Renders agent progress cards for terminal display
   - **Current State**:
     - Shows cost (total), turns, tool calls, tool breakdown for active agents
     - Displays via `renderAgentCard()` function
     - Uses `RunProgress.costUsd` (aggregate cost)
   - **Gap**: No phase-level cost breakdown in display
   - **Relevance**: Will need to add phase cost display

6. **src/cli/commands/status.ts** (lines 60-100)
   - **Purpose**: Shows project status and active agent details
   - **Current State**:
     - Displays active agents with elapsed time, status
     - Shows progress: turns, tools, files, cost
     - Parses `RunProgress` from `run.progress` column
   - **Gap**: No per-phase cost reporting
   - **Relevance**: Will display phase cost breakdown

### Type Definitions
7. **src/orchestrator/types.ts** (lines 1-149)
   - **Purpose**: Defines orchestration types
   - **Current State**:
     - `RunProgress` interface (referenced from store.ts) has: `costUsd, tokensIn, tokensOut, currentPhase`
     - No per-phase cost fields
   - **Relevance**: RunProgress may need extended fields for per-phase costs

## Architecture & Patterns

### Cost Tracking Flow
```
Pipeline Phase (explorer|developer|qa|reviewer)
  ↓
runPhase() executes SDK query() with budget limit
  ↓
SDK returns result with: total_cost_usd, usage.input_tokens, usage.output_tokens
  ↓
Accumulated into progress: progress.costUsd += result.total_cost_usd
  ↓
Phase completion logged: store.logEvent(..., { phase, costUsd }, runId)
  ↓
Database: Event stored with phase+cost in JSON details
  ✗ Database: No structured phase_cost record
```

### Current Cost Aggregation Patterns
- **Per-Run**: All run costs summed via `getCosts()` JOIN with project
- **Per-Runtime/Agent**: Costs grouped by `run.agent_type` in `getMetrics()`
- **Per-Phase**: Only in event logs; no database aggregation

### Phase Lifecycle
- Phases run sequentially: Explorer → Dev → QA → Reviewer
- Dev ⇄ QA may loop if QA fails (up to MAX_DEV_RETRIES=2)
- Each phase gets its own SDK session with `maxBudgetUsd` limit
- Phase costs are accumulated into single `progress.costUsd` for the entire run
- After completion, phase info is logged but not in costs table

## Dependencies

### What Needs Phase Cost Data
1. **Dashboard/Metrics API** (future):
   - Will query: `getCostsByPhase(projectId)` → `{explorer: $X, developer: $Y, ...}`
   - Will query: `getCostsByAgentAndPhase(projectId)` → 2D breakdown
   - Will query: `getCostsByAgent(projectId)` → already exists via JOIN

2. **CLI Status Display**:
   - `src/cli/commands/status.ts` will call new methods to show phase costs
   - `src/cli/watch-ui.ts` will render per-phase cost cards

3. **Agent Worker**:
   - `src/orchestrator/agent-worker.ts` `runPhase()` must record costs to database
   - Currently only logs to events; needs to call `recordCost()` with phase info

### What Phase Cost Data Depends On
1. **Database Schema**:
   - Existing `costs` table must be extended or new table created
   - `run_id` (foreign key to runs)
   - `phase` (string: explorer|developer|qa|reviewer)
   - Other cost fields: tokens_in, tokens_out, estimated_cost

2. **Existing Interfaces**:
   - `RunProgress`: Already tracks `currentPhase`
   - `Cost`: Minimal interface; can extend or create new struct
   - `Metrics`: Will gain new fields for phase-based aggregations

## Existing Tests

### Test Files
1. **src/lib/__tests__/store-metrics.test.ts**
   - Tests `getCosts()` with project/date filtering ✓
   - Tests cost aggregation by runtime via join ✓
   - Tests `getRunsByStatus()` filtering ✓
   - Tests `getMetrics()` empty state ✓
   - **Missing**: Tests for per-phase cost queries, agent+phase combinations

2. **src/lib/__tests__/store.test.ts**
   - Tests `recordCost()` basic functionality ✓
   - Tests `getCosts()` with date filters ✓
   - Tests cost accumulation in metrics ✓
   - **Missing**: Per-phase cost tests

3. **src/orchestrator/__tests__/agent-worker-team.test.ts**
   - Tests pipeline execution with cost tracking
   - May test cost accumulation in `progress.costUsd`
   - **Status**: Likely needs updates to verify phase costs are recorded

## Recommended Approach

### Phase 1: Schema Extension (Database Backward Compatibility)
1. Add new `phase_costs` table to support per-phase granularity:
   ```sql
   CREATE TABLE IF NOT EXISTS phase_costs (
     id TEXT PRIMARY KEY,
     run_id TEXT NOT NULL,
     phase TEXT NOT NULL,  -- 'explorer'|'developer'|'qa'|'reviewer'
     tokens_in INTEGER DEFAULT 0,
     tokens_out INTEGER DEFAULT 0,
     cache_read INTEGER DEFAULT 0,
     estimated_cost REAL DEFAULT 0.0,
     recorded_at TEXT,
     FOREIGN KEY (run_id) REFERENCES runs(id)
   );
   ```
2. **Alternative**: Extend `costs` table with `phase` column (allows consolidation)
3. Add migration to create table safely (idempotent, no errors if exists)

### Phase 2: Store Methods (src/lib/store.ts)
1. Extend `Cost` interface with optional `phase` field:
   ```typescript
   export interface Cost {
     id: string;
     run_id: string;
     phase?: string;  // 'explorer'|'developer'|'qa'|'reviewer'
     tokens_in: number;
     tokens_out: number;
     cache_read: number;
     estimated_cost: number;
     recorded_at: string;
   }
   ```

2. Add new method `recordPhaseCost()`:
   ```typescript
   recordPhaseCost(
     runId: string,
     phase: string,
     tokensIn: number,
     tokensOut: number,
     cacheRead: number,
     estimatedCost: number
   ): void
   ```

3. Add query methods for aggregation:
   ```typescript
   // Cost by phase only
   getCostsByPhase(projectId?: string, since?: string):
     Array<{phase: string; totalCost: number; totalTokens: number}>

   // Cost by agent (runtime) - already have via getMetrics()

   // Cost by agent + phase (2D breakdown)
   getCostsByAgentAndPhase(projectId?: string, since?: string):
     Array<{agent_type: string; phase: string; cost: number; tokens: number}>
   ```

4. Extend `Metrics` interface:
   ```typescript
   export interface Metrics {
     totalCost: number;
     totalTokens: number;
     tasksByStatus: Record<string, number>;
     costByRuntime: Array<{run_id: string; cost: number; ...}>;
     costByPhase?: Array<{phase: string; cost: number}>; // NEW
     costByAgentAndPhase?: Array<{agent_type: string; phase: string; cost: number}>; // NEW
   }
   ```

### Phase 3: Persist Phase Costs (src/orchestrator/agent-worker.ts)
1. In `runPhase()` function (around line 372-375 where costs are accumulated):
   ```typescript
   // After accumulating into progress.costUsd
   store.recordPhaseCost(
     config.runId,
     role,  // phase name
     phaseResult.usage.input_tokens,
     phaseResult.usage.output_tokens,
     0,     // cache_read (if available from SDK)
     phaseResult.total_cost_usd
   );
   ```

2. Ensure `progress.currentPhase` is set before executing phase (already done at line 319)

3. Consider updating `PhaseResult` interface to include phase info if needed

### Phase 4: Display in CLI (src/cli/watch-ui.ts & status.ts)
1. In `renderAgentCard()`, add phase cost breakdown if available:
   ```typescript
   // Parse phase costs from progress or store query
   // Display as: explorer: $X.XX | dev: $Y.YY | qa: $Z.ZZ | review: $W.WW
   ```

2. In `status.ts`, add metrics section with:
   - Cost by phase (total)
   - Cost by agent/model (already shown)
   - Cost by agent+phase (if available)

### Phase 5: Test Coverage
1. Add tests to `store-metrics.test.ts`:
   - `getCostsByPhase()` returns correct phase totals
   - `getCostsByAgentAndPhase()` returns 2D breakdown
   - Date filtering works with phase costs
   - Empty project returns empty arrays

2. Update agent-worker tests:
   - Verify `recordPhaseCost()` is called after each phase
   - Verify costs are attributed to correct phases

3. Integration test:
   - Run full pipeline, verify all phase costs recorded and queryable

## Potential Pitfalls & Edge Cases

### 1. Data Model Conflict
- **Issue**: Existing `costs` table is linked to runs, not phases
- **Solution**: Create separate `phase_costs` table to avoid breaking existing queries
- **Alternative**: Add optional `phase` column to `costs` (simpler, requires migration)

### 2. Developer ⇄ QA Loop Retries
- **Issue**: Developer phase may run multiple times; which "developer" cost to report?
- **Solution**: Record all developer phase costs separately (phase_costs allows multiple records per run)
- **Dashboard**: Aggregate by phase or show all occurrences

### 3. Phase Cost Persistence Timing
- **Issue**: Costs must be recorded after `phaseResult` is available
- **Solution**: Call `recordPhaseCost()` in `runPhase()` after line 372 (already have full result)
- **Watch**: Pipeline may fail between phase completion and cost recording (unlikely but possible)

### 4. RunProgress currentPhase Tracking
- **Issue**: `progress.currentPhase` is a string, not structured
- **Solution**: Could extend RunProgress with per-phase costs, but not required for database persistence
- **Recommendation**: Keep simple for now; aggregate at query time, not progress update time

### 5. Cache Read Tokens
- **Issue**: Phase result may not include `cache_read` data (optional in SDK)
- **Solution**: Pass 0 or extract from result if available; doesn't block feature

### 6. Backward Compatibility
- **Issue**: Existing runs have no phase cost records
- **Solution**: Dashboard must handle missing phase costs gracefully; aggregate from event logs if needed
- **Migration**: Can backfill from event logs if needed (non-blocking)

### 7. Phase Names Consistency
- **Issue**: Phase names hardcoded as "explorer"|"developer"|"qa"|"reviewer"
- **Solution**: Define as const in `roles.ts` or types, reference in agent-worker.ts and queries
- **Watch**: Ensure dashboard filters/grouping use same phase names

## Next Steps for Developer

1. **Choose schema approach**: Extend `costs` table with `phase` column OR create new `phase_costs` table
   - `phase` column: Simpler, fewer queries, backward-incompatible schema
   - New table: Safer, more explicit, requires JOINs for aggregation

2. **Implement schema migration**: Add CREATE TABLE or ALTER TABLE in store.ts MIGRATIONS array

3. **Implement store methods**:
   - `recordPhaseCost()` to insert per-phase costs
   - `getCostsByPhase()` to aggregate by phase
   - `getCostsByAgentAndPhase()` for 2D breakdown
   - Update `getMetrics()` to include phase aggregations

4. **Integrate with agent-worker**:
   - Call `recordPhaseCost()` after each `runPhase()` completes
   - Ensure phase name is passed correctly

5. **Update CLI displays**:
   - `watch-ui.ts`: Add phase cost breakdown to agent card
   - `status.ts`: Add metrics section for phase costs

6. **Write comprehensive tests**:
   - Store metrics tests for phase cost queries
   - Agent worker tests to verify costs are recorded
   - Integration test with full pipeline

7. **Consider dashboard enhancements**:
   - Add cost breakdown charts by phase
   - Add agent+phase matrix visualization
   - Track cost trends over time

## Summary Table

| File | Change | Impact |
|------|--------|--------|
| `src/lib/store.ts` | Add phase_costs table, new query methods | Core feature |
| `src/orchestrator/agent-worker.ts` | Call recordPhaseCost() per phase | Data collection |
| `src/cli/watch-ui.ts` | Display phase cost breakdown | User visibility |
| `src/cli/commands/status.ts` | Add phase metrics section | User visibility |
| `src/lib/__tests__/store-metrics.test.ts` | Test phase cost queries | Quality assurance |
| `src/orchestrator/__tests__/agent-worker*.ts` | Verify phase cost recording | Quality assurance |
