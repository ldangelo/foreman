# TRD-2026-015: Break Workflow Run Loop Out of Orchestration Loop

## Status

- **Author:** ldangelo
- **Created:** 2026-06-12
- **PRD:** docs/TRD/TRD-2026-015-workflow-run-loop-decoupling.md (PRD in TRD dir — mislabeled)
- **Status:** Draft

## Summary

Extract the workflow phase iteration loop (`runPhaseSequence()`) from `pipeline-executor.ts` into a standalone `WorkflowRunner` class that can be invoked independently of the full `executePipeline()` call chain. This decouples workflow execution from pipeline bootstrapping (VCS backend init, heartbeat manager, epic mode detection).

## Problem Statement

The current `runPhaseSequence()` function is tightly embedded inside `executePipeline()`. Callers who want to run a subset of phases (e.g. just the `developer` phase for a quick turn) must either:

- Construct a full `PipelineContext` with all callbacks and dependencies, or
- Abuse `skipIfArtifact` / `retryOnly` YAML tricks to skip unwanted phases.

Additionally, `runPhaseSequence()` cannot be unit-tested in isolation because it is called as the last step of `executeSingleTaskPipeline()` / `executeEpicPipeline()`, which themselves require a fully-populated `PipelineContext`.

## Solution

Introduce a new `WorkflowRunner` class in `pipeline-executor.ts` that wraps the phase iteration loop and exposes a minimal interface:

```typescript
interface WorkflowRunnerCallbacks {
  onPhaseStart?: (phase: WorkflowPhaseConfig, index: number) => Promise<void> | void;
  onPhaseComplete?: (phase: WorkflowPhaseConfig, result: PhaseResult, index: number) => Promise<void> | void;
  onPhaseFailure?: (phase: WorkflowPhaseConfig, result: PhaseResult, index: number) => Promise<void> | void;
  onVerdict?: (phase: WorkflowPhaseConfig, verdict: "pass" | "fail" | "unknown", index: number) => Promise<void> | void;
  onRetry?: (fromPhase: string, toPhase: string, retryCount: number) => Promise<void> | void;
  onPipelineComplete?: (result: PhaseSequenceResult) => Promise<void> | void;
  log: (msg: string) => void;
}

interface WorkflowRunnerContext {
  phases: WorkflowPhaseConfig[];
  config: PipelineRunConfig;
  workflowConfig: WorkflowConfig;
  store: ForemanStore;
  logFile: string;
  runPhase: RunPhaseFn;
  runBuiltinPhase?: (phase: WorkflowPhaseConfig) => Promise<PhaseResult>;
  callbacks: WorkflowRunnerCallbacks;
  taskMeta?: TaskMeta;
}

class WorkflowRunner {
  constructor(context: WorkflowRunnerContext);
  run(): Promise<PhaseSequenceResult>;
}
```

### PhaseSequenceResult

```typescript
interface PhaseSequenceResult {
  success: boolean;
  phaseRecords: PhaseRecord[];
  retryCounts: Record<string, number>;
  qaVerdictForLog: "pass" | "fail" | "unknown";
  progress: RunProgress;
  retriesExhausted?: boolean;
  cooldownUntil?: string;
}
```

## Refactoring Steps

### Step 1: Extract `runPhaseSequence()` into `WorkflowRunner.run()`

Move the phase iteration logic from `runPhaseSequence()` into a new `WorkflowRunner` class. The `WorkflowRunner` receives a `WorkflowRunnerContext` containing only the data it needs:

- Phase list (`phases: WorkflowPhaseConfig[]`)
- Config (`config: PipelineRunConfig`)
- Workflow config (`workflowConfig: WorkflowConfig`)
- Store (`store: ForemanStore`)
- Log file path (`logFile: string`)
- Run phase function (`runPhase: RunPhaseFn`)
- Optional builtin phase runner (`runBuiltinPhase`)
- Callbacks (`callbacks: WorkflowRunnerCallbacks`)
- Task metadata (`taskMeta?: TaskMeta`)

The `WorkflowRunner` manages internally:
- Phase index (`i`)
- Retry counts (`retryCounts`)
- Feedback context (`feedbackContext`)
- Verdict tracking (`qaVerdictForLog`)
- `retryOnlyActivations` set
- Explorer circuit breaker (`explorerFailures`)
- Rate limit tracking (`rateLimitRetries`)

### Step 2: Refactor `executeSingleTaskPipeline()`

```typescript
async function executeSingleTaskPipeline(ctx: PipelineContext): Promise<void> {
  const { config, workflowConfig, store, logFile } = ctx;
  const { taskId } = config;

  const progress: RunProgress = { /* ... */ };
  const phaseNames = workflowConfig.phases.map((p) => p.name).join(" → ");
  ctx.log(`Pipeline starting for ${taskId} [workflow: ${workflowConfig.name}]`);
  ctx.log(`[PIPELINE] Phase sequence: ${phaseNames}`);
  await appendFile(logFile, `\n[foreman-worker] Pipeline orchestration starting\n[PIPELINE] Phase sequence: ${phaseNames}\n`);

  // Initialize FR-3 heartbeat and FR-4 activity logger (remains here)
  const heartbeatConfig: HeartbeatConfig = { enabled: true, intervalSeconds: 60 };
  const worktreePath = config.worktreePath;
  ctx.heartbeatManager = config.vcsBackend
    ? createHeartbeatManager(heartbeatConfig, store, config.projectId, config.runId, config.vcsBackend, worktreePath, ctx.observabilityWriter) ?? undefined
    : undefined;
  ctx.heartbeatManager?.setTaskId(taskId);
  ctx.activityPhases = [];

  // Create WorkflowRunner with minimal context
  const runner = new WorkflowRunner({
    phases: workflowConfig.phases,
    config,
    workflowConfig,
    store,
    logFile,
    runPhase: ctx.runPhase,
    runBuiltinPhase: ctx.runBuiltinPhase,
    callbacks: {
      log: ctx.log,
      onPhaseStart: async (phase, idx) => { /* ... write phase-start event ... */ },
      onPhaseComplete: async (phase, result, idx) => { /* ... */ },
      onPhaseFailure: async (phase, result, idx) => { /* ... */ },
      onVerdict: async (phase, verdict, idx) => { /* ... */ },
      onRetry: async (from, to, count) => { /* ... */ },
      onPipelineComplete: ctx.onPipelineComplete,
    },
    taskMeta: ctx.taskMeta,
  });

  const result = await runner.run();

  // Session log and ACTIVITY_LOG.json (remains here)
  await writeSessionLogSafe(ctx, result.progress, result.phaseRecords, result.retryCounts, result.qaVerdictForLog);
  // ... generateActivityLog ...

  if (ctx.onPipelineComplete) {
    await ctx.onPipelineComplete({
      progress: result.progress,
      phaseRecords: result.phaseRecords,
      retryCounts: result.retryCounts,
      success: result.success,
    });
  }
}
```

### Step 3: Refactor `executeEpicPipeline()`

```typescript
async function executeEpicPipeline(ctx: PipelineContext): Promise<void> {
  // ... resume detection, epic init ...

  // Task loop: create WorkflowRunner for each task
  for (let taskIdx = 0; taskIdx < epicTasks.length; taskIdx++) {
    const task = epicTasks[taskIdx];
    // ...

    const taskRunner = new WorkflowRunner({
      phases: taskPhases,
      config: taskConfig,
      workflowConfig: taskWorkflowConfig,
      store,
      logFile,
      runPhase: ctx.runPhase,
      runBuiltinPhase: ctx.runBuiltinPhase,
      callbacks: { /* ... */ },
      taskMeta: ctx.taskMeta,
    });

    const result = await taskRunner.run();
    // ... accumulate results ...
  }

  // Final phases: create WorkflowRunner for finalPhases
  if (finalPhases.length > 0) {
    const finalRunner = new WorkflowRunner({
      phases: finalPhases,
      config,
      workflowConfig: finalWorkflowConfig,
      store,
      logFile,
      runPhase: ctx.runPhase,
      runBuiltinPhase: ctx.runBuiltinPhase,
      callbacks: { /* ... */ },
      taskMeta: ctx.taskMeta,
    });

    const finalResult = await finalRunner.run();
    // ...
  }
}
```

### Step 4: Remove Retry/Verdict Duplication

Currently, bash phase and builtin phase blocks duplicate the retry loop jump logic. After extraction, centralize in `WorkflowRunner`:

```typescript
private handleRetry(phase: WorkflowPhaseConfig, currentRetries: number): boolean {
  if (!phase.retryWith) return false;
  const maxRetries = phase.retryOnFail ?? 0;
  if (currentRetries< maxRetries) {
    const targetIdx = this.phaseIndex.get(phase.retryWith);
    if (targetIdx !== undefined) {
      this.retryOnlyActivations.add(phase.retryWith);
      this.currentPhaseIndex = targetIdx;
      return true; // indicates retry was initiated
    }
  }
  return false;
}
```

### Step 5: Update `agent-worker.ts`

No changes required to `agent-worker.ts` — the external API of `executePipeline()` is unchanged. The refactor is internal to `pipeline-executor.ts`.

## Backward Compatibility

- `executePipeline()` remains the public API. Callers (agent-worker.ts) do not change.
- `PipelineContext` is unchanged — it still contains all fields; the internal refactor is invisible to callers.
- `PipelineRunConfig` is unchanged.
- `PhaseResult` interface is unchanged.

## Acceptance Criteria

- [ ] `WorkflowRunner` class exists with `run()` method that accepts `WorkflowRunnerContext`.
- [ ] `executeSingleTaskPipeline()` uses `WorkflowRunner` internally.
- [ ] `executeEpicPipeline()` uses `WorkflowRunner` for both task phases and final phases.
- [ ] Retry loop jumps (QA→Developer, Reviewer→Developer) work identically after refactor.
- [ ] Verdict parsing (PASS/FAIL) works identically after refactor.
- [ ] Rate limit handling with backoff works identically after refactor.
- [ ] Explorer circuit breaker works identically after refactor.
- [ ] Haiku fallback to Sonnet on rate limit works identically after refactor.
- [ ] No new `any` types introduced — all interfaces are explicitly typed.
- [ ] Existing tests pass without modification.
- [ ] Unit tests added for `WorkflowRunner` in isolation.

## Non-Goals

- Parallel phase execution (deferred to a future TRD).
- Subset workflow composition via CLI (out of scope for this TRD).
- Changes to the YAML workflow schema.
- Modifying `PipelineContext` or `PipelineRunConfig` interfaces.
- WorkflowRunService / WorkflowRunStore (tracked in PRD, out of scope for this TRD).

## Files Affected

- `src/orchestrator/pipeline-executor.ts` — extract `runPhaseSequence()` into `WorkflowRunner`, refactor `executeSingleTaskPipeline()` and `executeEpicPipeline()` to use it.
- `src/orchestrator/agent-worker.ts` — no changes required (interface unchanged).
- `src/orchestrator/__tests__/` — add unit tests for `WorkflowRunner` in isolation.

## Open Questions

1. Should `WorkflowRunner` own the `feedbackContext` string, or should it be passed back to the caller via a callback?
 - **Decision:** `WorkflowRunner` owns `feedbackContext` internally. It is passed to `runPhase` via the phase prompt context, not via a callback.

2. Should the `PhaseSequenceResult` be the return type of `WorkflowRunner.run()`, or should we introduce a `WorkflowResult` wrapper?
   - **Decision:** `WorkflowRunner.run()` returns `PhaseSequenceResult` directly. No wrapper needed.

3. Should we move `WorkflowRunner` to a new file (`workflow-runner.ts`) or keep it in `pipeline-executor.ts`?
   - **Decision:** Keep in `pipeline-executor.ts` to minimize file churn. The class is co-located with the types it uses (`PipelineRunConfig`, `WorkflowConfig`, `PhaseResult`).

4. Should we extract the phase-specific verdict handling (QA verdict, finalize integration contract) into the `WorkflowRunner` or keep it in `executePipeline()`?
   - **Decision:** Keep verdict handling in `WorkflowRunner` for now. Extracting phase-specific logic can be a follow-up TRD.
