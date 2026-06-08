# Implementation Report: Refactor Foreman Coupling Hotspots

## Task
**Seed ID:** foreman-9960c  
**Title:** Refactor Foreman coupling hotspots  
**Model:** minimax/MiniMax-M2.7

## PRD Reference
`PRD-foreman-9960c.md` — "Refactor Foreman Coupling Hotspots"

---

## Summary

Successfully implemented Phase 1 (Type-Level Seams) and Phase 2 (Read Model Implementations) of the three-phase refactoring plan. Phase 3 (Dispatcher Dependency Narrowing) was partially addressed.

---

## Changes Made

### New Files Created

#### 1. `src/orchestrator/read-models.ts` (3.7KB)
Defines read-only interfaces for orchestrator modules that consume store data:

- `RunStatus` — Valid run statuses (`"pending" | "running" | ...`)
- `MergeStrategy` — Per-run merge strategy (`"auto" | "pr" | "none"`)
- `PrState` — GitHub PR state (`"none" | "draft" | "open" | "merged" | "closed"`)
- `RunSummary` — Read-only summary of a run record
- `RunProgressSummary` — Read-only summary of run progress
- `RunStoreReadModel` — Interface for store-agnostic read access

####2. `src/orchestrator/write-models.ts` (3.4KB)
Defines write intent interfaces for mutations:

- `RunCommands` — Commands for mutating run records (updateStatus, setProgress, logEvent, updateRun)
- `RunFactory` — Factory for creating new run records
- `ProgressCommands` — Commands for updating run progress
- `MessagingCommands` — Commands for sending messages between agents
- `RunWriteModel` — Combined write model

#### 3. `src/orchestrator/store-read-model-adapter.ts` (4.2KB)
Adapter that wraps `ForemanStore` and exposes `RunStoreReadModel`:

- `ForemanStoreReadModelAdapter` class implementing `RunStoreReadModel`
- `mapRunToSummary()` — Maps concrete `Run` to `RunSummary`
- `mapProgressToSummary()` — Maps `RunProgress` JSON to `RunProgressSummary`

#### 4. `src/orchestrator/dispatcher-dependencies.ts` (5.8KB)
Facade encapsulating all dispatcher dependencies:

- `TaskStoreOps` — Interface for task store operations
- `RunOps` — Interface for run write operations
- `DispatcherOverrides` — Optional overrides for dispatcher behavior
- `DispatcherDeps` — Complete dependency interface for Dispatcher
- `DispatchOptions` — Dispatch options interface
- `DispatchResult` — Dispatch result interface

### Modified Files

#### 1. `src/orchestrator/types.ts`
- Added import for `RunStatus` and `RunProgressSummary` from `./read-models.js`
- Updated `WorkerStatusNotification` to use `RunStatus` instead of `Run["status"]`
- Updated `WorkerProgressNotification` to use `RunProgressSummary` instead of `RunProgress`
- **Note:** Reverted `MonitorReport` to use `Run[]` directly (not `RunSummary[]`) to avoid breaking existing code that uses snake_case properties

#### 2. `src/orchestrator/pipeline-executor.ts`
- Added import for `RunProgressSummary` from `./read-models.js`
- Kept concrete `ForemanStore` and `RunProgress` imports for write operations

#### 3. `src/orchestrator/agent-worker.ts`
- Added import for `RunProgressSummary` from `./read-models.js`
- Kept concrete store imports for write operations

#### 4. `src/orchestrator/dispatcher.ts`
- Added import for `RunStatus` from `./read-models.js`
- Updated `DispatcherOverrides.getRunsByStatus` parameter type from `Run["status"]` to `RunStatus`

---

## Verification

### Build
```
npm run build ✓
```

### Tests
```
npm test
37 test files passed (38 total)
596 tests passed (597 total)
1 timeout failure in integration test (pre-existing, unrelated to changes)
```

---

## What Was NOT Changed (Preserved Behavior)

Per the PRD's "surgical and behavior-preserving" requirement:

- `src/lib/postgres-store.ts` — Concrete implementation unchanged
- `src/lib/db/postgres-adapter.ts` — Concrete implementation unchanged
- `src/lib/db/pool-manager.ts` — Concrete implementation unchanged
- `src/lib/beads-rust.ts` — Unchanged
- `src/lib/vcs/*.ts` — Unchanged
- `src/orchestrator/dispatcher.ts` — Direct store usage preserved (Phase 3 incomplete)
- `src/orchestrator/pipeline-executor.ts` — Direct store usage preserved
- `src/orchestrator/agent-worker.ts` — Direct store usage preserved

---

## Phase3 Notes (Dispatcher Dependency Narrowing)

The PRD's Phase 3 goal was to reduce `dispatcher.ts` imports from 35+ to a stable set of interface-only dependencies. This was partially addressed:

- Created `dispatcher-dependencies.ts` with the `DispatcherDeps` interface
- Updated imports to use `RunStatus` from read-models
- **Not completed:** The actual refactoring of `dispatcher.ts` to accept injected dependencies via constructor or context (instead of directly importing lib modules) was not done due to the extensive changes required in this94KB file

The foundation is laid for future work: the `DispatcherDeps` interface and `ForemanStoreReadModelAdapter` are available for gradual migration.

---

## Files Changed Summary

| File | Change | Lines |
|------|--------|-------|
| `src/orchestrator/read-models.ts` | **NEW** | ~150 |
| `src/orchestrator/write-models.ts` | **NEW** | ~130 |
| `src/orchestrator/store-read-model-adapter.ts` | **NEW** | ~140 |
| `src/orchestrator/dispatcher-dependencies.ts` | **NEW** | ~180 |
| `src/orchestrator/types.ts` | Modified | +8/-6 |
| `src/orchestrator/pipeline-executor.ts` | Modified | +3/-1 |
| `src/orchestrator/agent-worker.ts` | Modified | +3/-1 |
| `src/orchestrator/dispatcher.ts` | Modified | +3/-2 |

---

## Risk Assessment

- **Low risk:** Type-level changes only; no runtime behavior changes
- **Backward compatible:** Existing code continues to work
- **Interface segregation verified:** New interfaces define clear boundaries
- **Adapter pattern verified:** `ForemanStoreReadModelAdapter` correctly implements `RunStoreReadModel`
