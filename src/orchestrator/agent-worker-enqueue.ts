/**
 * Merge queue enqueue helper for agent-worker finalize phase.
 *
 * Extracted as a separate module so it can be unit-tested independently
 * of the agent-worker process lifecycle.
 */

import type Database from "better-sqlite3";
import { MergeQueue } from "./merge-queue.js";
import type { MergeQueueEntry } from "./merge-queue.js";
import { getForemanBranchName } from "../lib/branch-names.js";

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
export function enqueueToMergeQueue(options: EnqueueOptions): EnqueueResult {
  const { db, seedId, runId, getFilesModified } = options;

  try {
    // Collect modified files — tolerate failures
    let filesModified: string[] = [];
    try {
      filesModified = getFilesModified();
    } catch {
      // getFilesModified failed (e.g. git diff error) — proceed with empty list
    }

    const mq = new MergeQueue(db);
    const entry = mq.enqueue({
      branchName: getForemanBranchName(seedId),
      seedId,
      runId,
      agentName: "pipeline",
      filesModified,
    });

    return { success: true, entry };
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    return { success: false, error: msg };
  }
}
