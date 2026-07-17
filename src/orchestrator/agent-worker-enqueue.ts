/**
 * Merge queue enqueue helper for agent-worker finalize phase.
 *
 * Extracted as a separate module so it can be unit-tested independently
 * of the agent-worker process lifecycle.
 */

import { MergeQueue } from "./merge-queue.js";
import { ElixirMergeQueue } from "./elixir-merge-queue.js";
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
  /** The project path for gh commands (defaults to worktreePath if not provided). */
  projectPath?: string;
  /** The task ID for this task. */
  taskId: string;
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
  const { db, projectId, projectPath, taskId, runId, operation = "auto_merge", getFilesModified } = options;

  try {
    // Collect modified files — tolerate failures
    let filesModified: string[] = [];
    try {
      filesModified = getFilesModified();
    } catch {
      // getFilesModified failed (e.g. git diff error) — proceed with empty list
    }

    // Registered-project (ElixirMergeQueue) path requires a projectPath so `gh` has a cwd.
    // Fail fast when context is partial instead of passing undefined into the constructor.
    if (projectId && !projectPath && !options.worktreePath) {
      return {
        success: false,
        error: "projectPath is required when projectId is set (no worktreePath fallback available)",
      };
    }

    const entry = projectId
      ? await new ElixirMergeQueue(projectId, projectPath ?? options.worktreePath ?? "").enqueue({
          branchName: `foreman/${taskId}`,
          taskId,
          runId,
          operation,
          agentName: "pipeline",
          filesModified,
        })
      : db
        ? new MergeQueue(db).enqueue({
            branchName: `foreman/${taskId}`,
            taskId,
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
