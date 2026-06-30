import type { ITaskClient, Issue } from "../lib/task-client.js";
import type { NativeTask, Run } from "../lib/store.js";
import type { RunStatus } from "./read-models.js";
import type { DispatcherStoreDeps } from "./dispatcher-dependencies.js";
import type { BvClient } from "../lib/bv.js";
import type { EpicTask } from "./pipeline-executor.js";
import type { VcsBackend } from "../lib/vcs/index.js";
import type { TaskMeta } from "../lib/interpolate.js";
import type { SeedInfo, DispatchResult, RuntimeSelection, ModelSelection, PlanStepDispatched, NativeTaskStatus } from "./types.js";
import type { RuntimeMode } from "../cli/commands/run.js";
interface NativeTaskOps {
    hasNativeTasks(): Promise<boolean>;
    getReadyTasks(): Promise<NativeTask[]>;
    getTaskByExternalId(externalId: string): Promise<NativeTask | null>;
    getTaskById(id: string): Promise<NativeTask | null>;
    claimTask(taskId: string, runId: string): Promise<boolean>;
    updateTaskStatus?(taskId: string, status: NativeTaskStatus): Promise<void>;
    updateTaskLabels?(taskId: string, labels: string[]): Promise<void>;
    /** Get child task IDs for a given parent task (inverse of Beads' children field). */
    getChildren?(taskId: string): Promise<string[]>;
}
type Awaitable<T> = T | Promise<T>;
interface OrphanedWorkerConfigStore {
    getRun(runId: string): Awaitable<Run | null>;
}
interface BaseBranchRunLookup {
    getRunsForSeed(seedId: string): Awaitable<Run[]>;
}
export interface DispatcherOverrides {
    getRecentFailureCount?: (projectId: string, since: string) => Promise<number>;
    nativeTaskOps?: NativeTaskOps;
    getActiveSeedIds?: () => Promise<string[]>;
    hasActiveOrPendingRun?: (seedId: string) => Promise<boolean>;
    getActiveAgentCount?: () => Promise<number>;
    externalProjectId?: string;
    getRunsByStatus?: (status: RunStatus, projectId: string) => Promise<Run[]>;
    getRunsForSeed?: (seedId: string, projectId: string) => Promise<Run[]>;
    getRun?: (runId: string) => Promise<Run | null>;
    getActiveRuns?: (projectId: string) => Promise<Run[]>;
    runOps?: {
        createRun?: (args: {
            runId: string;
            projectId: string;
            seedId: string;
            agentType: string;
            branchName: string;
            worktreePath: string | null;
            baseBranch?: string | null;
            mergeStrategy?: Run["merge_strategy"];
        }) => Promise<Run | void>;
        updateRun?: (runId: string, updates: Partial<Pick<Run, "status" | "session_key" | "worktree_path" | "started_at" | "completed_at">>) => Promise<void>;
        sendMessage?: (runId: string, senderAgentType: string, recipientAgentType: string, subject: string, body: string) => Promise<void>;
        logEvent?: (runId: string, projectId: string, eventType: string, payload: Record<string, unknown>) => Promise<void>;
    };
}
/**
 * Convert a NativeTask row into a normalized Issue so that native tasks can be
 * processed by the same dispatch loop that handles Beads issues.
 *
 * Priority is stored as INTEGER (0–4) in the native store; normalise to string
 * form ('P0'–'P4') so the existing normalizePriority() helper works correctly.
 */
export declare function nativeTaskToIssue(task: NativeTask): Issue;
export declare class Dispatcher {
    private seeds;
    private store;
    private projectPath;
    private bvClient?;
    private overrides?;
    private bvFallbackWarned;
    private runLifecycleService;
    constructor(seeds: ITaskClient, store: DispatcherStoreDeps, projectPath: string, bvClient?: (BvClient | null) | undefined, overrides?: DispatcherOverrides | undefined);
    private requireRegisteredRunOp;
    private validateRegisteredRunOps;
    private createRunRecord;
    private updateRunRecord;
    private updateNativeTaskStatus;
    private sendMailRecord;
    private logEventRecord;
    private getActiveRunsRecord;
    private getRunsByStatusRecord;
    private getRunsForSeedRecord;
    private getRunRecord;
    /**
     * Query ready seeds, create worktrees, write TASK.md, and record runs.
     */
    dispatch(opts?: {
        maxAgents?: number;
        runtime?: RuntimeSelection;
        runtimeMode?: RuntimeMode;
        model?: ModelSelection;
        dryRun?: boolean;
        telemetry?: boolean;
        projectId?: string;
        pipeline?: boolean;
        /**
         * Explicit workflow name override (from `foreman run --workflow <name>`).
         * Takes priority over `workflow:<name>` labels and taskTypeWorkflowMap.
         */
        workflow?: string;
        seedId?: string;
        /** URL of the notification server (e.g. "http://127.0.0.1:PORT") */
        notifyUrl?: string;
        /** Override target branch for merges (when working on a feature branch instead of default). */
        targetBranch?: string;
        /** P1: Stagger delay in milliseconds between dispatches to prevent thundering herd. */
        staggerMs?: number;
        /**
         * Treat the project as being on its default branch, skipping current-branch
         * inspection for `branch:<current>` auto-labeling.
         *
         * The daemon's background dispatch loop sets this so that dispatched tasks
         * always target the default branch — otherwise tasks would inherit whatever
         * branch a developer happens to have checked out (nondeterministic merge
         * targets driven by unrelated local activity). Interactive `foreman run`
         * leaves this unset to preserve the branch-stacking feature.
         *
         * Parent-bead branch-label inheritance is unaffected — a child still
         * inherits an explicit `branch:` label from its parent.
         */
        assumeDefaultBranch?: boolean;
    }): Promise<DispatchResult>;
    /**
     * Resume stuck/failed runs from previous dispatches.
     *
     * Finds runs in "stuck" or "failed" status, extracts their SDK session IDs,
     * and resumes them via the SDK's `resume` option. This continues the agent's
     * conversation from where it left off (e.g. after a rate limit).
     */
    resumeRuns(opts?: {
        maxAgents?: number;
        model?: ModelSelection;
        telemetry?: boolean;
        statuses?: Array<"stuck" | "failed">;
        /** URL of the notification server (e.g. "http://127.0.0.1:PORT") */
        notifyUrl?: string;
        runtimeMode?: RuntimeMode;
    }): Promise<DispatchResult>;
    /**
     * Dispatch a planning step (PRD/TRD) without creating a worktree.
     * Runs Claude Code via SDK and waits for completion.
     */
    dispatchPlanStep(projectId: string, seed: SeedInfo, ensembleCommand: string, input: string, outputDir: string): Promise<PlanStepDispatched>;
    /**
     * Build the TASK.md content for a seed (exposed for testing).
     *
     * Model selection is now handled per-phase by the workflow YAML `models` map
     * (see resolvePhaseModel in workflow-loader.ts). The TASK.md model field shows
     * the developer-phase default as informational context.
     */
    generateAgentInstructions(seed: SeedInfo, worktreePath: string): string;
    /**
     * Build the spawn prompt for an agent (exposed for testing — TRD-012).
     * Returns the multi-line string passed to the worker as its initial prompt.
     */
    buildSpawnPrompt(seedId: string, seedTitle: string): string;
    /**
     * Build the resume prompt for an agent (exposed for testing — TRD-012).
     */
    buildResumePrompt(seedId: string, seedTitle: string): string;
    /**
     * Spawn a coding agent as a detached worker process.
     *
     * Writes a WorkerConfig JSON file and spawns `agent-worker.ts` as a
     * detached child process that survives the parent foreman process exiting.
     * The worker runs the SDK `query()` loop independently and updates the
     * Postgres store with progress/completion.
     */
    private spawnAgent;
    /**
     * Resume a previously started agent session via a detached worker process.
     * The worker uses the SDK's `resume` option to continue the conversation.
     */
    private resumeAgent;
    /**
     * Return recent stuck runs for a seed within the configured time window.
     * Ordered by created_at DESC (most recent first).
     *
     * Note: Runs that have a `cooldown_until` timestamp (either expired or in the
     * future) are excluded because they are in cooldown state, not truly stuck.
     * The cooldown state is handled separately by checkCooldownState, which
     * takes precedence over stuck backoff.
     */
    private getRecentStuckRuns;
    /**
     * Check whether a seed is currently in exponential backoff due to recent
     * stuck runs. Returns `{ inBackoff: false }` if the seed may be dispatched,
     * or `{ inBackoff: true, reason }` if it must be skipped this cycle.
     */
    private checkStuckBackoff;
    /**
     * Check whether a seed is currently in cooldown state after a retryable failure
     * with retryAfterCooldown enabled. Returns `{ inCooldown: false }` if the seed
     * may be dispatched, or `{ inCooldown: true, reason }` if it must be skipped
     * until the cooldown period expires.
     */
    private checkCooldownState;
    /**
     * Returns true when an issue status indicates the issue is in a terminal state
     * (closed, completed, cancelled, done, duplicate) and any active runs should
     * be stopped or worktrees cleaned up.
     */
    private isTerminalState;
    /**
     * Stop a run whose issue has transitioned to a terminal state.
     * Marks the run as stuck, logs the event, and archives the worktree.
     */
    private cancelRun;
    /**
     * Reconcile active runs against their underlying issue state.
     * Stop any runs whose issues have transitioned to a terminal state
     * (closed/completed) or are no longer found.
     *
     * Called at the start of each dispatch cycle to catch issues that were
     * closed while an agent was still running.
     *
     * @returns The number of runs that were stopped.
     */
    private reconcileRunningIssues;
    /**
     * Clean up orphaned worktrees for issues that are already in a terminal state
     * when the daemon starts. This handles the case where worktrees exist for
     * issues that were closed while the daemon was not running.
     *
     * Terminal states: closed, completed, cancelled, done, duplicate
     *
     * @returns The number of worktrees removed.
     *
     * Native-only: Returns 0 unconditionally. Worktree cleanup for terminal
     * issues is handled by reconcileRunningIssues() during the dispatch cycle.
     *
     * NOTE: This method is a no-op in native-only mode. Worktree cleanup for
     * terminal issues is handled by:
     *   1. reconcileRunningIssues() — stops runs and archives worktrees for issues
     *      that transition to terminal state while the daemon is running.
     *   2. The daemon startup path calls cleanupTerminalStateWorktrees() to catch
     *      issues that were closed while the daemon was not running. However, since
     *      the native dispatcher does not call beads for status, and the native
     *      store does not expose a way to iterate all tasks with their worktrees,
     *      we rely on the reconciliation pass at the start of each dispatch cycle
     *      to catch terminal issues. Orphaned worktrees will be cleaned up on the
     *      next daemon restart if the issue status has been updated externally.
     */
    private cleanupTerminalStateWorktrees;
    /**
     * Once a bead has a merged/PR-created run, it must not be dispatched again
     * unless a later explicit reset exists. This protects against stale bead
     * status or delayed queue writes causing accidental redispatch after merge.
     */
    private hasMergedOutcomeWithoutLaterReset;
    private resolveProjectId;
}
/**
 * Resolve the base branch for a seed's worktree.
 *
 * For native-only mode: Native tasks do not have dependency information (unlike
 * Beads issues which support `br dep add`). This function returns undefined
 * (no stacking) for native tasks.
 *
 * For Beads mode (when nativeTaskOps is not configured): If any of the seed's
 * blocking dependencies have an unmerged local branch (i.e. a `foreman/<depId>`
 * branch exists locally and its latest run is "completed" but not yet "merged"),
 * stack the new worktree on top of that dependency branch instead of the default
 * branch.
 *
 * This allows agent B to build on top of agent A's work before A is merged.
 * After A merges, the refinery will rebase B onto main.
 *
 * Returns the dependency branch name (e.g. "foreman/story-1") or undefined
 * when no stacking is needed.
 *
 * Native-only: This function does not call Beads client.
 * Stacking is disabled for native tasks since they lack dependency metadata.
 */
export declare function resolveBaseBranch(_seedId: string, _projectPath: string, _runLookup: BaseBranchRunLookup, _backend?: Pick<VcsBackend, "branchExists">): Promise<string | undefined>;
export interface WorkerConfig {
    runId: string;
    projectId: string;
    seedId: string;
    seedTitle: string;
    seedDescription?: string;
    seedComments?: string;
    model: string;
    worktreePath: string;
    /** Project root directory (contains .beads/). Used as cwd for br commands. */
    projectPath?: string;
    prompt: string;
    env: Record<string, string>;
    resume?: string;
    pipeline?: boolean;
    /** Legacy local-store path retained for compatibility only. */
    dbPath?: string;
    /** Explicit workflow name/path for direct task execution. Overrides seed labels/type. */
    workflowName?: string;
    workflowPath?: string;
    /**
     * Resolved workflow type (e.g. "smoke", "feature", "bug").
     * Derived from label-based override or bead type field.
     * Used for prompt-loader workflow scoping and spawn strategy selection.
     */
    seedType?: string;
    /**
     * Labels from the bead. Forwarded to agent-worker so it can resolve
     * `workflow:<name>` label overrides.
     */
    seedLabels?: string[];
    /**
     * Bead priority string ("P0"–"P4", "0"–"4", or undefined).
     * Forwarded to the pipeline executor to resolve per-priority models from YAML.
     */
    seedPriority?: string;
    /**
     * Override target branch for auto-merge after finalize.
     * When set, the agent worker merges into this branch instead of detectDefaultBranch().
     */
    targetBranch?: string;
    /**
     * Optional task ID from native task store (NativeTaskStore.claim()).
     * When present, pipeline will call taskStore.updatePhase(taskId, phaseName)
     * at each phase transition for phase-level visibility (REQ-012).
     * Null/undefined when no task ID is available — no-op via optional chaining.
     */
    taskId?: string | null;
    /**
     * Ordered list of child tasks for epic execution mode (TRD-2026-007).
     * When set, the worker runs the epic pipeline: taskPhases per child task,
     * then finalPhases once at the end.
     */
    epicTasks?: EpicTask[];
    /**
     * Parent epic bead ID (TRD-2026-007).
     * When set, this run is an epic execution — the worker executes all
     * epicTasks within a single worktree.
     */
    epicId?: string;
    /**
     * Task metadata for placeholder interpolation in bash/command phases (REQ-008).
     * Populated from the bead/seed that triggered this run.
     */
    taskMeta?: TaskMeta;
    /**
     * GitHub issue number for this task (from github_issue_number field).
     * When set, finalize commit messages are suffixed with "Fixes #{issueNumber}" (TRD-042).
     */
    githubIssueNumber?: number;
    /** One-based dispatch attempt number for lifecycle hook environment. */
    attemptNumber?: number;
    /**
     * Directory guardrail config (FR-1). When set, wraps tool factories with
     * cwd verification in the Pi SDK session. Prevents agents from operating
     * in the wrong worktree.
     */
    guardrailConfig?: {
        /** Guardrail enforcement mode. Default: `auto-correct`. */
        mode?: "auto-correct" | "veto" | "disabled";
        /** Expected working directory for this agent session. */
        expectedCwd?: string;
        /** Optional list of allowed path prefixes. */
        allowedPaths?: string[];
    };
    /**
     * Workspace lifecycle hooks for pre/post-run customization.
     * Loaded from project config and passed to the agent worker.
     */
    hooks?: import("../lib/project-config.js").ProjectHooksConfig;
}
/** Result returned by a SpawnStrategy */
export interface SpawnResult {
    pid: number | null;
}
/** Strategy interface for spawning worker processes */
export interface SpawnStrategy {
    spawn(config: WorkerConfig): Promise<SpawnResult>;
}
/**
 * Resolve common paths needed by both spawn strategies.
 */
export declare function resolveWorkerPaths(homeDir?: string, orchestratorDirOverride?: string): {
    tsxBin: string;
    workerScript: string;
    logDir: string;
    projectRoot: string;
    runnerArgs: string[];
};
/**
 * Spawn worker as a detached child process (original behavior).
 */
export declare class DetachedSpawnStrategy implements SpawnStrategy {
    spawn(config: WorkerConfig): Promise<SpawnResult>;
}
/**
 * Spawn agent-worker using DetachedSpawnStrategy.
 *
 * DetachedSpawnStrategy spawns agent-worker.ts, which runs the full pipeline
 * (explorer → developer → QA → reviewer → finalize) and calls runWithPi()
 * per phase with the correct phase prompt and Pi extension env vars.
 */
export declare function spawnWorkerProcess(config: WorkerConfig): Promise<SpawnResult>;
/**
 * Build a clean env record (string values only) for worker config.
 * Removes CLAUDECODE to allow nested Claude sessions.
 */
export declare function buildWorkerEnv(telemetry: boolean | undefined, seedId: string, runId: string, model: string, notifyUrl?: string, vcsBackend?: VcsBackend, runtimeMode?: RuntimeMode): Record<string, string>;
export declare function buildSdkSessionKey(model: string, runId: string, pid: number | null, sdkSessionId?: string): string;
/**
 * Return the directory where worker config JSON files are written.
 */
export declare function workerConfigDir(): string;
/**
 * Delete the worker config file for a specific run (if it still exists).
 * Safe to call even if the file has already been deleted by the worker.
 */
export declare function deleteWorkerConfigFile(runId: string): Promise<void>;
/**
 * Purge stale worker config files from ~/.foreman/tmp/ for runs that are no
 * longer active in the database.
 *
 * Worker config files are written by the dispatcher and deleted by the worker
 * on startup.  When a run is killed externally, the worker never starts and
 * the config file is never cleaned up.  This function removes orphaned files
 * for runs that are in a terminal state (failed, stuck, completed, etc.) or
 * are entirely absent from the DB.
 *
 * Returns the number of files deleted.
 */
export declare function purgeOrphanedWorkerConfigs(store: OrphanedWorkerConfigStore): Promise<number>;
export {};
//# sourceMappingURL=dispatcher.d.ts.map