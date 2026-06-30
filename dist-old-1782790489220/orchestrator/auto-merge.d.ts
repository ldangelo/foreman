/**
 * auto-merge.ts — Standalone autoMerge function and supporting helpers.
 *
 * Extracted from src/cli/commands/run.ts so that both the `foreman run`
 * dispatch loop AND the agent-worker's onPipelineComplete callback can
 * trigger merge queue draining without creating circular module dependencies.
 *
 * The key design goal: when an agent completes its pipeline (finalize phase
 * succeeds), it should immediately drain the merge queue rather than waiting
 * for `foreman run` to be running and call autoMerge() in its dispatch loop.
 */
import type { ForemanStore, Run } from "../lib/store.js";
import type { ITaskClient } from "../lib/task-client.js";
type Awaitable<T> = T | Promise<T>;
export interface AutoMergeReadLookup {
    getRun(id: string): Awaitable<Run | null>;
    getRunsByStatus(status: Run["status"], projectId?: string): Awaitable<Run[]>;
    getRunsByStatuses(statuses: Run["status"][], projectId?: string): Awaitable<Run[]>;
    getRunsByBaseBranch(baseBranch: string, projectId?: string): Awaitable<Run[]>;
}
/**
 * Immediately sync a task's status in the native task store after a merge outcome.
 *
 * Fetches the latest run status from Postgres, maps it to the expected task
 * status via mapRunStatusToSeedStatus(), and updates the native task store.
 *
 * When `failureReason` is provided (non-empty), logs it (native task store
 * does not have a notes field for failure context).
 *
 * Non-fatal — logs a warning on failure and lets the caller continue.
 */
export declare function syncBeadStatusAfterMerge(store: ForemanStore, taskClient: ITaskClient, runId: string, seedId: string, projectPath: string, failureReason?: string, readLookup?: Pick<AutoMergeReadLookup, "getRun">): Promise<void>;
/** Options for the autoMerge function. */
export interface AutoMergeOpts {
    store: ForemanStore;
    taskClient: ITaskClient;
    projectPath: string;
    registeredProjectId?: string;
    readLookup?: AutoMergeReadLookup;
    /** Merge target branch. When omitted, auto-detected via detectDefaultBranch(). */
    targetBranch?: string;
    /**
     * Optional run ID for the immediate auto-merge case (agent-worker finalize).
     * When provided, this is passed to mergeCompleted's runId path, which fetches
     * the run directly by ID without status filtering. This is the most reliable
     * approach for immediate auto-merge calls where timing is critical.
     *
     * The runId should match the queue entry's run_id so mergeCompleted can locate
     * the run even if the status update hasn't been fully committed/visible yet.
     */
    runId?: string;
    /**
     * Optional pre-fetched run to bypass the getRun() query entirely.
     * When provided, this run is used directly instead of querying by runId.
     * This eliminates the race condition where the run status update hasn't been
     * committed/visible when autoMerge queries for the run by ID.
     */
    overrideRun?: Run;
}
/** Result summary returned by autoMerge(). */
export interface AutoMergeScopedResult {
    runId: string;
    merged: number;
    conflicts: number;
    failed: number;
}
export interface AutoMergeResult {
    merged: number;
    conflicts: number;
    failed: number;
    /** Outcome for opts.runId only. Present only when opts.runId was provided. */
    target?: AutoMergeScopedResult;
}
/**
 * Process the merge queue: reconcile completed runs, then drain pending entries
 * via the Refinery.
 *
 * Non-fatal — errors are logged and the caller continues. Returns a summary of
 * what happened (for logging / testing).
 *
 * Sends mail notifications for each merge outcome so that `foreman inbox` shows
 * the full lifecycle from dispatch through merge:
 *   - merge-complete  — branch merged successfully, bead closed
 *   - merge-conflict  — conflict detected, PR created or manual intervention needed
 *   - merge-failed    — merge failed (test failures, no completed run, or unexpected error)
 *   - bead-closed     — bead status synced in br after merge outcome
 *
 * Note: Refinery also sends per-run merge lifecycle messages. autoMerge sends
 * wrapper-level messages from sender "auto-merge" to provide queue-level context.
 *
 * This function is called from two places:
 *  1. `foreman run` dispatch loop — between agent batches (existing behaviour)
 *  2. `agent-worker` onPipelineComplete callback — immediately after finalize
 *     succeeds (new behaviour, fixes the "foreman run exits early" bug)
 */
export declare function autoMerge(opts: AutoMergeOpts): Promise<AutoMergeResult>;
export {};
//# sourceMappingURL=auto-merge.d.ts.map