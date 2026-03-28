import type Database from "better-sqlite3";
import { GitBackend } from "../lib/vcs/git-backend.js";
export type MergeQueueStatus = "pending" | "merging" | "merged" | "conflict" | "failed";
export interface MergeQueueEntry {
    id: number;
    branch_name: string;
    seed_id: string;
    run_id: string;
    agent_name: string | null;
    files_modified: string[];
    enqueued_at: string;
    started_at: string | null;
    completed_at: string | null;
    status: MergeQueueStatus;
    resolved_tier: number | null;
    error: string | null;
    retry_count: number;
    last_attempted_at: string | null;
}
interface EnqueueInput {
    branchName: string;
    seedId: string;
    runId: string;
    agentName?: string;
    filesModified?: string[];
}
export interface MissingFromQueueEntry {
    run_id: string;
    seed_id: string;
}
export interface ReconcileResult {
    enqueued: number;
    skipped: number;
    invalidBranch: number;
    failedToEnqueue: Array<{
        run_id: string;
        seed_id: string;
        reason: string;
    }>;
}
/** Signature for an injected execFile-style async function. */
export type ExecFileAsyncFn = (cmd: string, args: string[], options?: {
    cwd?: string;
}) => Promise<{
    stdout: string;
    stderr: string;
}>;
export declare const RETRY_CONFIG: {
    maxRetries: number;
    initialDelayMs: number;
    maxDelayMs: number;
    backoffMultiplier: number;
};
export declare class MergeQueue {
    private db;
    constructor(db: Database.Database);
    /**
     * Add a branch to the merge queue.
     * Idempotent: if the same branch_name+run_id already exists, return the existing entry.
     */
    enqueue(input: EnqueueInput): MergeQueueEntry;
    /**
     * Atomically claim the next pending entry.
     * Sets status to 'merging' and started_at to now.
     * Returns null if no pending entries exist.
     */
    dequeue(): MergeQueueEntry | null;
    /**
     * Peek at the next pending entry without claiming it.
     */
    peek(): MergeQueueEntry | null;
    /**
     * List entries, optionally filtered by status.
     */
    list(status?: MergeQueueStatus): MergeQueueEntry[];
    /**
     * Update the status (and optional extra fields) of an entry.
     */
    updateStatus(id: number, status: MergeQueueStatus, extra?: {
        resolvedTier?: number;
        error?: string;
        completedAt?: string;
        lastAttemptedAt?: string;
        retryCount?: number;
    }): void;
    /**
     * Reset a failed/conflict entry for a given seed back to 'pending' so it
     * can be retried. Used by `foreman merge --seed <id>` to allow re-processing
     * entries that previously ended in a terminal failure state.
     *
     * Returns true if an entry was reset, false if no retryable entry was found.
     */
    resetForRetry(seedId: string): boolean;
    /**
     * Calculate the delay (in ms) before the next retry attempt using exponential backoff.
     */
    private retryDelayMs;
    /**
     * Determine whether an entry is eligible for automatic retry.
     * Returns true if retry_count < maxRetries AND enough time has passed since last attempt.
     */
    shouldRetry(entry: MergeQueueEntry): boolean;
    /**
     * Return all conflict/failed entries that are eligible for automatic retry.
     */
    getRetryableEntries(): MergeQueueEntry[];
    /**
     * Re-enqueue a failed/conflict entry by resetting it to pending.
     * Increments retry_count and records last_attempted_at.
     * Returns true if successful, false if entry not found or max retries exceeded.
     */
    reEnqueue(id: number): boolean;
    /**
     * Delete an entry from the queue.
     */
    remove(id: number): void;
    /**
     * Return all pending entries ordered by conflict cluster.
     * Entries within the same cluster (sharing modified files) are grouped consecutively.
     * Within each cluster, FIFO order (by enqueued_at) is maintained.
     */
    getOrderedPending(): MergeQueueEntry[];
    /**
     * Atomically claim the next pending entry using cluster-aware ordering.
     * Entries that share modified files with each other are processed consecutively
     * to reduce merge conflict likelihood.
     * Returns null if no pending entries exist.
     */
    dequeueOrdered(): MergeQueueEntry | null;
    /**
     * Return completed runs that are NOT present in the merge queue.
     * Used to detect runs that completed but were never enqueued (e.g. due to
     * missing branches, reconciliation failures, or system crashes).
     */
    missingFromQueue(): MissingFromQueueEntry[];
    /**
     * Reconcile completed runs with the merge queue.
     * For each completed run not already queued, validate its branch exists
     * and enqueue it with the list of modified files.
     */
    reconcile(db: Database.Database, repoPath: string, backend?: GitBackend): Promise<ReconcileResult>;
}
export {};
//# sourceMappingURL=merge-queue.d.ts.map