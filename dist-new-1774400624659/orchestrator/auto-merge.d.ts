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
import type { ForemanStore } from "../lib/store.js";
import type { ITaskClient } from "../lib/task-client.js";
/**
 * Immediately sync a bead's status in the br backend after a merge outcome.
 *
 * Fetches the latest run status from SQLite, maps it to the expected bead
 * status via mapRunStatusToSeedStatus(), updates br, then flushes with
 * `br sync --flush-only`.
 *
 * When `failureReason` is provided (non-empty), adds it as a note on the bead
 * so that the bead record explains WHY it was blocked/failed. This is the
 * immediate fix described in the task: rather than waiting for
 * syncBeadStatusOnStartup() on the next restart, the bead is updated right
 * away with both status and context.
 *
 * Non-fatal — logs a warning on failure and lets the caller continue.
 */
export declare function syncBeadStatusAfterMerge(store: ForemanStore, taskClient: ITaskClient, runId: string, seedId: string, projectPath: string, failureReason?: string): Promise<void>;
/** Options for the autoMerge function. */
export interface AutoMergeOpts {
    store: ForemanStore;
    taskClient: ITaskClient;
    projectPath: string;
    /** Merge target branch. When omitted, auto-detected via detectDefaultBranch(). */
    targetBranch?: string;
}
/** Result summary returned by autoMerge(). */
export interface AutoMergeResult {
    merged: number;
    conflicts: number;
    failed: number;
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
//# sourceMappingURL=auto-merge.d.ts.map