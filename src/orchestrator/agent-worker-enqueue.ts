/**
 * Merge queue enqueue helper for agent-worker finalize phase.
 *
 * Extracted as a separate module so it can be unit-tested independently
 * of the agent-worker process lifecycle.
 */

import { MergeQueue } from "./merge-queue.js";
import { PostgresMergeQueue } from "./postgres-merge-queue.js";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import type { MergeQueueEntry } from "./merge-queue.js";
import type { MergeQueueOperation } from "./merge-queue.js";

interface SqlStatement<T = unknown> {
  get(...params: unknown[]): T;
  all(...params: unknown[]): T[];
  run(...params: unknown[]): unknown;
}

interface SqlDbLike {
  prepare(sql: string): SqlStatement;
}

export interface EnqueueOptions {
  /** The database connection to use for the merge queue (local path only). */
  db?: SqlDbLike;
  /** Optional daemon/Postgres project id for queue writes. */
  projectId?: string;
  /** The seed ID for this task. */
  seedId: string;
  /** The run ID for this pipeline execution. */
  runId: string;
  /** The merge action this completed run requires. */
  operation?: MergeQueueOperation;
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
export async function enqueueToMergeQueue(options: EnqueueOptions): Promise<EnqueueResult> {
  const { db, projectId, seedId, runId, operation = "auto_merge", getFilesModified } = options;

  try {
    // Collect modified files — tolerate failures
    let filesModified: string[] = [];
    try {
      filesModified = getFilesModified();
    } catch {
      // getFilesModified failed (e.g. git diff error) — proceed with empty list
    }

    const entry = projectId
      ? await new PostgresMergeQueue(projectId, new PostgresAdapter()).enqueue({
          branchName: `foreman/${seedId}`,
          seedId,
          runId,
          operation,
          agentName: "pipeline",
          filesModified,
        })
      : db
        ? new MergeQueue(db).enqueue({
            branchName: `foreman/${seedId}`,
            seedId,
            runId,
            operation,
            agentName: "pipeline",
            filesModified,
          })
        : null;

    if (!entry) {
      return { success: false, error: "merge queue db is required when projectId is not set" };
    }

    return { success: true, entry };
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    return { success: false, error: msg };
  }
}
