/**
 * task-backend-ops.ts
 *
 * Task lifecycle operations for the pipeline worker using the native task store.
 *
 * Provides operations used by agent-worker.ts and the run command:
 *   - closeTask()               — marks a task complete (finalize phase)
 *   - resetTaskToOpen()         — resets a task back to ready (markStuck path)
 *   - markTaskFailed()           — marks a task as failed
 *   - updateTaskStatus() — updates task status directly
 *
 * All operations use the native Postgres task store via ForemanStore.
 * Beads (br CLI) operations have been removed — native tasks are mandatory.
 */

import { execFileSync } from "node:child_process";
import { ForemanStore } from "../lib/store.js";
import { mapRunStatusToTaskStatus, mapRunStatusToNativeTaskStatus } from "../lib/run-status.js";
import type { StateMismatch } from "../lib/run-status.js";
import type { NativeTaskStatus } from "./types.js";
import type { RunStatus } from "./read-models.js";

type Awaitable<T> = T | Promise<T>;

type TaskStatusStore = Pick<ForemanStore, "updateTaskStatus"> & Partial<Pick<ForemanStore, "getRunsByStatuses" | "getTaskById">>;

type StartupTaskStatusStore = {
  getRunsByStatuses(
    statuses: Parameters<ForemanStore["getRunsByStatuses"]>[0],
    projectId?: string,
  ): Awaitable<Awaited<ReturnType<ForemanStore["getRunsByStatuses"]>>>;
  getTaskById?(id: string): Awaitable<ReturnType<ForemanStore["getTaskById"]>>;
  updateTaskStatus?(taskId: string, newStatus: NativeTaskStatus): Awaitable<void>;
};

type LegacyTaskClient = {
  show(id: string): Awaitable<{ status?: string } | null | undefined>;
  update?(id: string, updates: { status: string }): Awaitable<unknown>;
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
 * @param taskId - The task ID to close.
 * @param sender - Human-readable source label (e.g. "refinery", "agent-worker").
 */
export function closeTask(store: TaskStatusStore, taskId: string, sender: string): void {
  try {
    store.updateTaskStatus(taskId, "closed");
    console.error(`[task-backend-ops] Closed task ${taskId} (sender: ${sender})`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: Failed to close task ${taskId}: ${msg.slice(0, 200)}`);
  }
}

/**
 * Reset a task back to ready status in the native task store.
 * Called by markStuck() so the task reappears in the ready queue for retry.
 *
 * @param store - ForemanStore for the project.
 * @param taskId - The task ID to reset.
 * @param sender - Human-readable source label.
 */
export function resetTaskToOpen(store: TaskStatusStore, taskId: string, sender: string): void {
  try {
    store.updateTaskStatus(taskId, "ready");
    console.error(`[task-backend-ops] Reset task ${taskId} to ready (sender: ${sender})`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: Failed to reset task ${taskId}: ${msg.slice(0, 200)}`);
  }
}

/**
 * Mark a task as in cooldown state after a retryable failure.
 *
 * When a phase fails with a retryable error (e.g. rate limit) and retryAfterCooldown
 * is enabled in the workflow YAML, the task is placed in cooldown state instead of
 * being marked failed/stuck. The dispatcher will not re-dispatch until the cooldown
 * period expires.
 *
 * @param store - ForemanStore for the project.
 * @param taskId - The task ID to mark as in cooldown.
 * @param cooldownUntil - ISO timestamp when the cooldown period ends.
 * @param sender - Human-readable source label.
 */
export function markTaskInCooldown(
  store: TaskStatusStore,
  taskId: string,
  cooldownUntil: string,
  sender: string,
): void {
  try {
    store.updateTaskStatus(taskId, "cooldown");
    console.error(`[task-backend-ops] Marked task ${taskId} in cooldown until ${cooldownUntil} (sender: ${sender})`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: Failed to mark task ${taskId} in cooldown: ${msg.slice(0, 200)}`);
  }
}

/**
 * Reset a task from cooldown state back to ready status.
 * Called when the cooldown period has expired and the task is ready to be retried.
 *
 * @param store - ForemanStore for the project.
 * @param taskId - The task ID to reset.
 * @param sender - Human-readable source label.
 */
export function resetCooldownTaskToReady(store: TaskStatusStore, taskId: string, sender: string): void {
  try {
    store.updateTaskStatus(taskId, "ready");
    console.error(`[task-backend-ops] Reset task ${taskId} from cooldown to ready (sender: ${sender})`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: Failed to reset task ${taskId} from cooldown: ${msg.slice(0, 200)}`);
  }
}

/**
 * Mark a task as failed in the native task store.
 *
 * @param store - ForemanStore for the project.
 * @param taskId - The task ID to mark as failed.
 * @param sender - Human-readable source label.
 */
export function markTaskFailed(store: TaskStatusStore, taskId: string, sender: string): void {
  try {
    store.updateTaskStatus(taskId, "failed");
    console.error(`[task-backend-ops] Marked task ${taskId} as failed (sender: ${sender})`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: Failed to mark task ${taskId} as failed: ${msg.slice(0, 200)}`);
  }
}

/**
 * Update a task's status directly in the native task store.
 *
 * @param store - ForemanStore for the project.
 * @param taskId - The task ID.
 * @param status - The new status.
 * @param sender - Human-readable source label.
 */
export function updateTaskStatus(store: TaskStatusStore, taskId: string, status: string, sender: string): void {
  try {
    store.updateTaskStatus(taskId, status);
    console.error(`[task-backend-ops] Updated task ${taskId} status to ${status} (sender: ${sender})`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: Failed to update task ${taskId} status to ${status}: ${msg.slice(0, 200)}`);
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
  const terminalStatuses: Array<"completed" | "merged" | "pr-created" | "conflict" | "test-failed" | "failed" | "stuck" | "cooldown"> = [
    "completed",
    "merged",
    "pr-created",
    "conflict",
    "test-failed",
    "failed",
    "stuck",
    "cooldown",
  ];

  const terminalRuns = await Promise.resolve(store.getRunsByStatuses(terminalStatuses, projectId));

  // Deduplicate by task_id: keep the most recently created run per task
  type RunLike = { id: string; task_id: string; status: RunStatus; created_at: string };
  const latestByTask = new Map<string, RunLike>();
  for (const run of terminalRuns) {
    const existing = latestByTask.get(run.task_id);
    if (!existing || run.created_at > existing.created_at) {
      latestByTask.set(run.task_id, run);
    }
  }

  const mismatches: StateMismatch[] = [];
  const errors: string[] = [];
  let synced = 0;

  for (const run of latestByTask.values()) {
    const expectedTaskStatus = mapRunStatusToNativeTaskStatus(run.status);
    try {
      const task = await store.getTaskById?.(run.task_id);
      if (!task) {
        // Task not found — skip silently (may have been deleted)
        continue;
      }

      if (task.status === "closed") {
        continue;
      }

      if (task.status !== expectedTaskStatus) {
        mismatches.push({
          taskId: run.task_id,
          runId: run.id,
          runStatus: run.status,
          actualTaskStatus: task.status,
          expectedTaskStatus: expectedTaskStatus,
        });

        if (!dryRun) {
          try {
            await Promise.resolve(store.updateTaskStatus?.(run.task_id, expectedTaskStatus));
            synced++;
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            errors.push(`Failed to sync task ${run.task_id}: ${msg}`);
          }
        }
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      errors.push(`Could not check task ${run.task_id}: ${msg}`);
    }
  }

  return { synced, mismatches, errors };
}

// ── Legacy-named native wrappers ──────────────────────────────────────────────
// These exports keep older call sites and tests compiling while still routing
// through the native task store only.

export const enqueueCloseTask = closeTask;
export const enqueueResetTaskToOpen = resetTaskToOpen;
export const enqueueMarkBeadFailed = markTaskFailed;
export const enqueueSetBeadStatus = updateTaskStatus;

export function enqueueAddNotesToBead(_store: TaskStatusStore, _taskId: string, _note: string, _sender: string): void {
  // Deprecated legacy alias retained for older call sites. Native task notes are
  // appended directly by the caller via the active backend adapter.
}

export async function syncBeadStatusOnStartup(
  store: StartupTaskStatusStore,
  taskClient: LegacyTaskClient,
  projectId: string,
  opts?: { dryRun?: boolean; projectPath?: string },
): Promise<SyncResult> {
  const dryRun = opts?.dryRun ?? false;
  const terminalStatuses: Array<"completed" | "merged" | "pr-created" | "conflict" | "test-failed" | "failed" | "stuck" | "cooldown"> = [
    "completed",
    "merged",
    "pr-created",
    "conflict",
    "test-failed",
    "failed",
    "stuck",
    "cooldown",
  ];

  const terminalRuns = await Promise.resolve(store.getRunsByStatuses(terminalStatuses, projectId));
  type RunLike = { id: string; task_id: string; status: RunStatus; created_at: string };
  const latestByTask = new Map<string, RunLike>();
  for (const run of terminalRuns) {
    const existing = latestByTask.get(run.task_id);
    if (!existing || run.created_at > existing.created_at) {
      latestByTask.set(run.task_id, run);
    }
  }

  const mismatches: StateMismatch[] = [];
  const errors: string[] = [];
  let synced = 0;

  for (const run of latestByTask.values()) {
    const expectedTaskStatus = mapRunStatusToTaskStatus(run.status);
    try {
      const task = await Promise.resolve(taskClient.show(run.task_id));
      if (!task) continue;
      const actualTaskStatus = task.status ?? "";
      if (actualTaskStatus !== expectedTaskStatus) {
        mismatches.push({
          taskId: run.task_id,
          runId: run.id,
          runStatus: run.status,
          actualTaskStatus,
          expectedTaskStatus,
        });
        if (!dryRun) {
          try {
            execFileSync("br", ["update", run.task_id, "--status", expectedTaskStatus], {
              cwd: opts?.projectPath,
            });
            synced++;
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            errors.push(`Failed to sync task ${run.task_id}: ${msg}`);
          }
        }
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      if (!/not found/i.test(msg)) {
        errors.push(`Could not check task ${run.task_id}: ${msg}`);
      }
    }
  }

  if (!dryRun && synced > 0) {
    try {
      execFileSync("br", ["sync", "--flush-only"], { cwd: opts?.projectPath });
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      errors.push(`br sync --flush-only failed: ${msg}`);
    }
  }

  return { synced, mismatches, errors };
}

// ── Deprecated Beads Operations (removed) ─────────────────────────────────────
//
// The following Beads-specific operations have been removed:
//   - enqueueCloseTask, enqueueResetTaskToOpen, enqueueMarkBeadFailed,
//     enqueueAddNotesToBead, enqueueAddLabelsToBead, enqueueSetBeadStatus
//   - closeTask, resetTaskToOpen, markBeadFailed, addNotesToBead, addLabelsToBead
//   - syncBeadStatusOnStartup
//
// Use the native task operations above instead:
//   - closeTask (store, taskId, sender)
//   - resetTaskToOpen (store, taskId, sender)
//   - markTaskFailed (store, taskId, sender)
//   - updateTaskStatus (store, taskId, status, sender)
//   - syncTaskStatusOnStartup (store, projectId, opts)
