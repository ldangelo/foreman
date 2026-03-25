import type { ITaskClient } from "../lib/task-client.js";
import type { ForemanStore } from "../lib/store.js";
import type { BvClient } from "../lib/bv.js";
import type { SeedInfo, DispatchResult, RuntimeSelection, ModelSelection, PlanStepDispatched } from "./types.js";
export declare class Dispatcher {
    private seeds;
    private store;
    private projectPath;
    private bvClient?;
    private bvFallbackWarned;
    constructor(seeds: ITaskClient, store: ForemanStore, projectPath: string, bvClient?: (BvClient | null) | undefined);
    /**
     * Query ready seeds, create worktrees, write TASK.md, and record runs.
     */
    dispatch(opts?: {
        maxAgents?: number;
        runtime?: RuntimeSelection;
        model?: ModelSelection;
        dryRun?: boolean;
        telemetry?: boolean;
        projectId?: string;
        pipeline?: boolean;
        skipExplore?: boolean;
        skipReview?: boolean;
        seedId?: string;
        /** URL of the notification server (e.g. "http://127.0.0.1:PORT") */
        notifyUrl?: string;
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
     * SQLite store with progress/completion.
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
     */
    private getRecentStuckRuns;
    /**
     * Check whether a seed is currently in exponential backoff due to recent
     * stuck runs. Returns `{ inBackoff: false }` if the seed may be dispatched,
     * or `{ inBackoff: true, reason }` if it must be skipped this cycle.
     */
    private checkStuckBackoff;
    /**
     * Drain the bead_write_queue and execute all pending br operations sequentially.
     *
     * This is the single writer for all br CLI operations — called by the dispatcher
     * process only. Agent-workers, refinery, pipeline-executor, and auto-merge enqueue
     * operations via ForemanStore.enqueueBeadWrite() instead of calling br directly,
     * eliminating concurrent SQLite lock contention on .beads/beads.jsonl.
     *
     * Each entry is processed in insertion order. If an individual operation fails,
     * the error is logged but draining continues (non-fatal per-entry). A single
     * `br sync --flush-only` is called at the end to persist all changes atomically.
     *
     * @returns Number of entries successfully processed.
     */
    drainBeadWriterInbox(): Promise<number>;
    private resolveProjectId;
}
/**
 * Resolve the base branch for a seed's worktree.
 *
 * If any of the seed's blocking dependencies have an unmerged local branch
 * (i.e. a `foreman/<depId>` branch exists locally and its latest run is
 * "completed" but not yet "merged"), stack the new worktree on top of that
 * dependency branch instead of the default branch.
 *
 * This allows agent B to build on top of agent A's work before A is merged.
 * After A merges, the refinery will rebase B onto main.
 *
 * Returns the dependency branch name (e.g. "foreman/story-1") or undefined
 * when no stacking is needed.
 */
export declare function resolveBaseBranch(seedId: string, projectPath: string, store: Pick<ForemanStore, "getRunsForSeed">): Promise<string | undefined>;
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
    skipExplore?: boolean;
    skipReview?: boolean;
    /** Absolute path to the SQLite DB file (e.g. .foreman/foreman.db) */
    dbPath?: string;
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
}
/** Result returned by a SpawnStrategy */
export interface SpawnResult {
}
/** Strategy interface for spawning worker processes */
export interface SpawnStrategy {
    spawn(config: WorkerConfig): Promise<SpawnResult>;
}
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
export declare function purgeOrphanedWorkerConfigs(store: Pick<import("../lib/store.js").ForemanStore, "getRun">): Promise<number>;
//# sourceMappingURL=dispatcher.d.ts.map