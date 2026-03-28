/**
 * Merge queue enqueue helper for agent-worker finalize phase.
 *
 * Extracted as a separate module so it can be unit-tested independently
 * of the agent-worker process lifecycle.
 */
import type Database from "better-sqlite3";
import type { MergeQueueEntry } from "./merge-queue.js";
export interface EnqueueOptions {
    /** The database connection to use for the merge queue. */
    db: Database.Database;
    /** The seed ID for this task. */
    seedId: string;
    /** The run ID for this pipeline execution. */
    runId: string;
    /** The worktree path (used for context, not directly by enqueue). */
    worktreePath: string;
    /**
     * Callback that returns the list of modified files.
     * Typically wraps `execFileSync("git", ["diff", "--name-only", "main...HEAD"])`.
     * If this throws, enqueue proceeds with an empty file list.
     */
    getFilesModified: () => string[];
}
export interface EnqueueResult {
    success: boolean;
    entry?: MergeQueueEntry;
    error?: string;
}
/**
 * Enqueue a completed branch into the merge queue.
 *
 * Fire-and-forget semantics: errors are captured in the result but never thrown.
 * This ensures finalization is never blocked by merge queue failures.
 */
export declare function enqueueToMergeQueue(options: EnqueueOptions): EnqueueResult;
//# sourceMappingURL=agent-worker-enqueue.d.ts.map