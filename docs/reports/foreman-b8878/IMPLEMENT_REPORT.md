# Implementation Report: Remove Beads Fallback; Native Tasks Only

## Summary

Successfully removed the Beads fallback mechanism from Foreman, making native tasks the only supported task store option. This simplifies the codebase by removing coexistence logic and environment variable overrides.

## Changes Made

### Core Task Client Factory (`src/lib/task-client-factory.ts`)

- **Removed types**: `TaskStoreMode`, `TaskClientBackend` (now just `"native"`)
- **Removed options**: `forceBeadsFallback`, `autoSelectNativeWhenAvailable`, `ensureBrInstalled`
- **Removed functions**:
  - `resolveTaskStoreMode()` - no longer needed
  - `createBeadsFallbackClient()` - beads client no longer used
  - `selectTaskReadBackend()` / `selectTaskReadBackendAsync()` - auto-selection removed
  - `projectHasNativeTasks()` - synchronous check no longer needed
  - `fetchBeadsTaskCounts()` - beads counting removed
- **Simplified `createTaskClient()`**: Always returns native task client
- **Simplified `fetchTaskCounts()`**: Always fetches native task counts

### Dispatcher (`src/orchestrator/dispatcher.ts`)

- **Removed imports**: `resolveTaskStoreMode`, `TaskStoreMode`
- **Removed coexistence logic**: No more `usingNativeStore` variable and conditional paths
- **Always uses native tasks**: `getReadyTasks()` from native store, `claimTask()` for atomic claims
- **Removed beads-specific code**:
  - Feature beads auto-close (beads-specific child tracking)
  - Epic children query and dispatch (beads-specific)
  - `this.seeds.show()` fallback for seedId lookup
  - `this.seeds.update()` for status updates
- **Updated WorkerConfig comment**: Removed "beads fallback mode" reference

### CLI Commands

#### `run.ts`
- Removed `resolveTaskStoreMode` import
- Simplified `createTaskClients()`: Always uses native tasks
- Removed `forceBeadsFallback` logic and test mode handling
- `bvClient` always `null` (not used for native tasks)

#### `sentinel.ts`
- Removed `forceBeadsFallback: true` from `createSentinelTaskClient()`

#### `plan.ts`
- Removed `selectTaskReadBackend` import
- `createPlanClient()` always returns `NativePlanTaskClient`

#### `merge.ts`
- Removed `ensureBrInstalled` from `createMergeTaskClient()`

#### `monitor.ts`
- Removed `ensureBrInstalled` from `createTaskClient()` call

#### `retry.ts`
- Changed default `backendType` from `"beads"` to `"native"`

### Orchestrator

#### `agent-worker.ts`
- Removed `forceBeadsFallback` from `createRuntimeTaskClient()`
- Removed `forceBeadsFallback` from `createTaskClient()` call in pipeline executor

#### `refinery.ts`
- **Removed `syncBeadStatusAfterMerge` import and fallback call**
- `closeNativeTaskPostMerge()` now only updates native tasks, no beads fallback

#### `pipeline-executor.ts`
- Updated comments to remove "beads fallback mode" references

### Doctor (`src/orchestrator/doctor.ts`)

- **Simplified `checkTaskStoreMode()`**: Always reports native mode
- **Simplified `checkBeadsInitialized()`**: Always skips (beads not required)

### Tests Updated

- `dispatcher-native.test.ts`: Removed `resolveTaskStoreMode` tests, beads fallback tests, FOREMAN_TASK_STORE override tests
- `dispatcher-native-integration.test.ts`: Updated description
- `dispatcher-epic.test.ts`: Tests updated for native-only behavior
- `pipeline-task-store-phase.test.ts`: Updated comments
- `refinery.test.ts`: Updated test expectations (no `syncBeadStatusAfterMerge` calls)
- `agent-worker-auto-merge.test.ts`: Updated test expectations
- `sentinel-backend.test.ts`: Updated test expectations

## What Was NOT Changed

- The `BeadsRustClient` class itself remains in `src/lib/beads-rust.ts` (may be used by other parts of the system)
- `syncBeadStatusAfterMerge` function remains in `auto-merge.ts` (may be used elsewhere)
- Other parts of the system that still use `ITaskClient` interface (the interface is still valid, just always backed by native tasks)

## Verification

- Build passes successfully
- Refinery tests pass
- TypeScript compilation succeeds

## Impact

- **Simplified task store logic**: No more coexistence mode, FOREMAN_TASK_STORE env var ignored
- **Consistent behavior**: Always uses native Postgres task store
- **Easier maintenance**: Removed conditional branches for beads fallback
- **Test simplification**: Tests no longer need to cover beads fallback paths

## Migration Notes

Projects using the old beads_rust task store will need to:
1. Run `foreman task import --from-beads` to migrate existing beads to native tasks
2. Remove `.beads/` directory after migration
3. Foreman will now always use the native task store