# QA Report: FT-002: Orchestrator delegates dispatch to task runner

## Verdict: PASS

## Summary
The implementation correctly refactors the dispatcher/orchestrator to use the same canonical workflow runner as the direct CLI path (`foreman run task`). The key changes are:

1. **Replaced skip flags with explicit workflow option**: The `--skip-explore` and `--skip-review` flags (which were never consumed by the pipeline executor) were removed and replaced with a `workflow` option that takes an explicit workflow name/path.

2. **Unified workflow execution path**: Both `Dispatcher.dispatch()` and `run-task.ts` now use `spawnWorkerProcess()` with `workflowName` parameter, ensuring the same canonical workflow runner is used regardless of how dispatch is triggered.

3. **Preserved scheduling/state-gating**: The dispatcher's scheduling decisions (cooldown, stuck backoff, concurrency limits, onError=stop guard) remain intact before dispatch.

4. **Daemon branch label fix**: Added `assumeDefaultBranch` option to suppress `branch:<current>` auto-labeling in daemon background dispatch, preventing nondeterministic merge targets.

## Test Results

### Targeted Tests Run

1. **run-workflow-flag.test.ts** (workflow flag CLI tests)
   - Command: `npx vitest run src/cli/__tests__/run-workflow-flag.test.ts -c vitest.unit.config.ts --reporter=dot`
   - Result: **12 passed**
   - Duration: 647ms

2. **run-task.test.ts** (direct task execution CLI tests)
   - Command: `npx vitest run src/cli/__tests__/run-task.test.ts -c vitest.unit.config.ts --reporter=dot`
   - Result: **8 passed**
   - Duration: 181ms

3. **dispatcher-branch-label.test.ts** (branch labeling with assumeDefaultBranch)
   - Command: `npx vitest run src/orchestrator/__tests__/dispatcher-branch-label.test.ts -c vitest.unit.config.ts --reporter=dot`
   - Result: **12 passed**
   - Duration: 443ms

4. **dispatcher.test.ts** (main dispatcher tests)
   - Command: `npx vitest run src/orchestrator/__tests__/dispatcher.test.ts -c vitest.unit.config.ts --reporter=dot`
   - Result: **73 passed**
   - Duration: 277ms

### Full Unit Test Suite
- Command: `npx vitest run -c vitest.unit.config.ts --reporter=dot`
- Result: **259 test files passed, 3699 tests passed, 6 skipped**
- Duration: 33.26s

## Files Modified (Reviewed)
- `src/orchestrator/dispatcher.ts` - Main dispatcher with workflow option and assumeDefaultBranch
- `src/cli/commands/run-task.ts` - CLI direct task execution using same spawnWorkerProcess
- `src/cli/commands/run.ts` - Main run command with --workflow flag
- `src/orchestrator/agent-worker.ts` - Worker process using workflowName
- `src/lib/workflow-loader.ts` - Workflow loading and resolution with explicit workflow option
- `src/defaults/workflows/*.yaml` - Bundled workflow definitions

## Key Implementation Details

### `dispatch()` method signature change
```typescript
// OLD
async dispatch(opts?: {
  skipExplore?: boolean;
  skipReview?: boolean;
  ...
})

// NEW
async dispatch(opts?: {
  workflow?: string;  // Explicit workflow name override
  assumeDefaultBranch?: boolean;  // For daemon background dispatch
  ...
})
```

### `spawnWorkerProcess()` now receives workflowName
The `skipExplore` and `skipReview` parameters were removed from `WorkerConfig` and replaced with:
```typescript
interface WorkerConfig {
  workflowName?: string;
  workflowPath?: string;
}
```

### Branch Label Auto-labeling Fix
The daemon's background dispatch loop now sets `assumeDefaultBranch: true` to suppress `branch:<current>` auto-labeling, preventing tasks from targeting arbitrary developer checkouts.

## Issues Found
None. All tests pass.

## Test Coverage Assessment
The existing tests cover:
- CLI `--workflow` flag parsing and workflow selection
- Direct task execution (`foreman run task`) bypassing state-gating
- Branch label auto-labeling with and without `assumeDefaultBranch`
- Dispatcher scheduling (cooldown, backoff, concurrency)

### Recommendations for Additional Tests (not implemented in QA)
1. **Integration test for daemon dispatch with assumeDefaultBranch**: Verify daemon background dispatch uses `assumeDefaultBranch: true` and that interactive dispatch does not.
2. **End-to-end workflow selection test**: A test that verifies when `--workflow quick` is passed, the `quick.yaml` phases are executed instead of `default.yaml`.
3. **Workflow resolution priority test**: Test that explicit `--workflow` flag takes priority over `workflow:<name>` labels and `taskTypeWorkflowMap`.

## Conclusion
The implementation correctly achieves the goal of making the orchestrator's dispatch use the same canonical workflow runner as the direct CLI path. All unit tests pass, and the refactoring preserves existing scheduling/state-gating behavior while adding the `assumeDefaultBranch` fix for daemon background dispatch.
