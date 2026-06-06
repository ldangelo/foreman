/**
 * task-backend-ops.ts
 *
 * Task lifecycle operations for the pipeline worker using the native task store.
 *
 * Provides operations used by agent-worker.ts and the run command:
 *   - closeSeed()               — marks a task complete (finalize phase)
 *   - resetSeedToOpen()         — resets a task back to ready (markStuck path)
 *   - markSeedFailed()           — marks a task as failed
 *   - updateSeedStatus() — updates task status directly
 *
 * All operations use the native Postgres task store via ForemanStore.
 * Beads (br CLI) operations have been removed — native tasks are mandatory.
 */

import { ForemanStore } from "../lib/store.js";
import { PostgresStore } from "../lib/postgres-store.js";
import { mapRunStatusToSeedStatus } from "../lib/run-status.js";
import type { StateMismatch } from "../lib/run-status.js";

type StartupTaskStatusStore = {
  getRunsByStatuses(
    statuses: Parameters<ForemanStore["getRunsByStatuses"]>[0],
    projectId?: string,
  ): ReturnType<ForemanStore["getRunsByStatuses"]> | Promise<ReturnType<ForemanStore["getRunsByStatuses"]>>;
};

// ── Native Task Operations ─────────────────────────────────────────────────────
//
// These functions perform task lifecycle operations directly on the native
// Postgres task store. They are called by agent-worker, refinery,
// pipeline-executor, and auto-merge.
//
// Unlike the deprecated Beads backend, there is no write queue or sequential
// drain pattern — native tasks support concurrent writes via Postgres MVCC.

/**
 * Close a task in the native task store.
 *
 * @param store - ForemanStore for the project.
 * @param seedId - The task ID to close.
 * @param sender - Human-readable source label (e.g. "refinery", "agent-worker").
 */
export function closeSeed(store: ForemanStore, seedId: string, sender: string): void {
  try {
    const project = store.getProjectByPath(store.getProjectPath?.() ?? "");
    if (project) {
      // Use PostgresStore for registered projects
      const pgStore = new PostgresStore(project.id);
      pgStore.closeTask(seedId).catch((err: unknown) => {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`[task-backend-ops] Warning: Failed to close task ${seedId}: ${msg.slice(0, 200)}`);
      });
    } else {
      // Fall back to local store operations
      store.closeTask?.(seedId);
    }
    console.error(`[task-backend-ops] Closed task ${seedId} (sender: ${sender})`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: Failed to close task ${seedId}: ${msg.slice(0, 200)}`);
  }
}

/**
 * Reset a task back to ready status in the native task store.
 * Called by markStuck() so the task reappears in the ready queue for retry.
 *
 * @param store - ForemanStore for the project.
 * @param seedId - The task ID to reset.
 * @param sender - Human-readable source label.
 */
export function resetSeedToOpen(store: ForemanStore, seedId: string, sender: string): void {
  try {
    const project = store.getProjectByPath(store.getProjectPath?.() ?? "");
    if (project) {
      const pgStore = new PostgresStore(project.id);
      pgStore.resetTask(seedId).catch((err: unknown) => {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`[task-backend-ops] Warning: Failed to reset task ${seedId}: ${msg.slice(0, 200)}`);
      });
    } else {
      store.resetTask?.(seedId);
    }
    console.error(`[task-backend-ops] Reset task ${seedId} to ready (sender: ${sender})`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: Failed to reset task ${seedId}: ${msg.slice(0, 200)}`);
  }
}

/**
 * Mark a task as failed in the native task store.
 *
 * @param store - ForemanStore for the project.
 * @param seedId - The task ID to mark as failed.
 * @param sender - Human-readable source label.
 */
export function markSeedFailed(store: ForemanStore, seedId: string, sender: string): void {
  try {
    const project = store.getProjectByPath(store.getProjectPath?.() ?? "");
    if (project) {
      const pgStore = new PostgresStore(project.id);
      pgStore.updateTaskStatus(seedId, "failed").catch((err: unknown) => {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`[task-backend-ops] Warning: Failed to mark task ${seedId} as failed: ${msg.slice(0, 200)}`);
      });
    } else {
      store.updateTaskStatus?.(seedId, "failed");
    }
    console.error(`[task-backend-ops] Marked task ${seedId} as failed (sender: ${sender})`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: Failed to mark task ${seedId} as failed: ${msg.slice(0, 200)}`);
  }
}

/**
 * Update a task's status directly in the native task store.
 *
 * @param store - ForemanStore for the project.
 * @param seedId - The task ID.
 * @param status - The new status.
 * @param sender - Human-readable source label.
 */
export function updateSeedStatus(store: ForemanStore, seedId: string, status: string, sender: string): void {
  try {
    const project = store.getProjectByPath(store.getProjectPath?.() ?? "");
    if (project) {
      const pgStore = new PostgresStore(project.id);
      pgStore.updateTaskStatus(seedId, status).catch((err: unknown) => {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`[task-backend-ops] Warning: Failed to update task ${seedId} status to ${status}: ${msg.slice(0, 200)}`);
      });
    } else {
      store.updateTaskStatus?.(seedId, status);
    }
    console.error(`[task-backend-ops] Updated task ${seedId} status to ${status} (sender: ${sender})`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: Failed to update task ${seedId} status to ${status}: ${msg.slice(0, 200)}`);
  }
}

// ── Startup Sync ────────────────────────────────────────────────────────────

export interface SyncResult {
  /** Number of tasks whose status was successfully updated. */
  synced: number;
  /** All mismatches detected (includes both fixed and unfixed in dryRun mode). */
  mismatches: StateMismatch[];
  /** Non-fatal errors encountered during the sync (per-task failures). */
  errors: string[];
}

/**
 * Sync task status from Postgres run status to native task status on foreman startup.
 *
 * Queries all terminal runs from the store and reconciles the expected task
 * status (derived from run status) with the actual status stored in the task table.
 * This corrects "drift" that can occur when foreman was interrupted before
 * a task status update completed.
 *
 * Covers all terminal run statuses:
 *   merged, pr-created           → closed
 *   completed                    → in-progress (waiting for merge queue)
 *   failed, stuck, conflict, test-failed → ready (reset for retry)
 *
 * Non-fatal: individual task errors are collected and returned; startup
 * is not aborted.
 *
 * @param store       - Store to query runs from.
 * @param projectId   - Project ID to scope the run query.
 * @param opts.dryRun - Detect mismatches but do not fix them.
 */
export async function syncTaskStatusOnStartup(
  store: StartupTaskStatusStore,
  projectId: string,
  opts?: { dryRun?: boolean },
): Promise<SyncResult> {
  const dryRun = opts?.dryRun ?? false;

  // All terminal statuses
  const terminalStatuses: Array<"completed" | "merged" | "pr-created" | "conflict" | "test-failed" | "failed" | "stuck"> = [
    "completed",
    "merged",
    "pr-created",
    "conflict",
    "test-failed",
    "failed",
    "stuck",
  ];

  const terminalRuns = await Promise.resolve(store.getRunsByStatuses(terminalStatuses, projectId));

  // Deduplicate by seed_id: keep the most recently created run per seed
  type RunLike = { id: string; seed_id: string; status: string; created_at: string };
  const latestBySeed = new Map<string, RunLike>();
  for (const run of terminalRuns) {
    const existing = latestBySeed.get(run.seed_id);
    if (!existing || run.created_at > existing.created_at) {
      latestBySeed.set(run.seed_id, run);
    }
  }

  const mismatches: StateMismatch[] = [];
  const errors: string[] = [];
  let synced = 0;

  for (const run of latestBySeed.values()) {
    const expectedTaskStatus = mapRunStatusToSeedStatus(run.status);
    try {
      const task = await store.getTaskById?.(run.seed_id);
      if (!task) {
        // Task not found — skip silently (may have been deleted)
        continue;
      }

      if (task.status !== expectedTaskStatus) {
        mismatches.push({
          seedId: run.seed_id,
          runId: run.id,
          runStatus: run.status,
          actualSeedStatus: task.status,
          expectedSeedStatus,
        });

        if (!dryRun) {
          try {
            store.updateTaskStatus?.(run.seed_id, expectedTaskStatus);
            synced++;
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            errors.push(`Failed to sync task ${run.seed_id}: ${msg}`);
          }
        }
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      errors.push(`Could not check task ${run.seed_id}: ${msg}`);
    }
  }

  return { synced, mismatches, errors };
}

// ── Deprecated Beads Operations (removed) ─────────────────────────────────────
//
// The following Beads-specific operations have been removed:
//   - enqueueCloseSeed, enqueueResetSeedToOpen, enqueueMarkBeadFailed,
//     enqueueAddNotesToBead, enqueueAddLabelsToBead, enqueueSetBeadStatus
//   - closeSeed, resetSeedToOpen, markBeadFailed, addNotesToBead, addLabelsToBead
//   - syncBeadStatusOnStartup
//
// Use the native task operations above instead:
//   - closeSeed (store, seedId, sender)
//   - resetSeedToOpen (store, seedId, sender)
//   - markSeedFailed (store, seedId, sender)
//   - updateSeedStatus (store, seedId, status, sender)
//   - syncTaskStatusOnStartup (store, projectId, opts)
