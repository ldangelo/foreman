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
import type { StateMismatch } from "../lib/run-status.js";
import type { NativeTaskStatus } from "./types.js";
type Awaitable<T> = T | Promise<T>;
type TaskStatusStore = Pick<ForemanStore, "updateTaskStatus"> & Partial<Pick<ForemanStore, "getRunsByStatuses" | "getTaskById">>;
type StartupTaskStatusStore = {
    getRunsByStatuses(statuses: Parameters<ForemanStore["getRunsByStatuses"]>[0], projectId?: string): Awaitable<Awaited<ReturnType<ForemanStore["getRunsByStatuses"]>>>;
    getTaskById?(id: string): Awaitable<ReturnType<ForemanStore["getTaskById"]>>;
    updateTaskStatus?(taskId: string, newStatus: NativeTaskStatus): Awaitable<void>;
};
type LegacyTaskClient = {
    show(id: string): Awaitable<{
        status?: string;
    } | null | undefined>;
    update?(id: string, updates: {
        status: string;
    }): Awaitable<unknown>;
};
/**
 * Close a task in the native task store.
 *
 * @param store - ForemanStore for the project.
 * @param seedId - The task ID to close.
 * @param sender - Human-readable source label (e.g. "refinery", "agent-worker").
 */
export declare function closeSeed(store: TaskStatusStore, seedId: string, sender: string): void;
/**
 * Reset a task back to ready status in the native task store.
 * Called by markStuck() so the task reappears in the ready queue for retry.
 *
 * @param store - ForemanStore for the project.
 * @param seedId - The task ID to reset.
 * @param sender - Human-readable source label.
 */
export declare function resetSeedToOpen(store: TaskStatusStore, seedId: string, sender: string): void;
/**
 * Mark a task as in cooldown state after a retryable failure.
 *
 * When a phase fails with a retryable error (e.g. rate limit) and retryAfterCooldown
 * is enabled in the workflow YAML, the task is placed in cooldown state instead of
 * being marked failed/stuck. The dispatcher will not re-dispatch until the cooldown
 * period expires.
 *
 * @param store - ForemanStore for the project.
 * @param seedId - The task ID to mark as in cooldown.
 * @param cooldownUntil - ISO timestamp when the cooldown period ends.
 * @param sender - Human-readable source label.
 */
export declare function markTaskInCooldown(store: TaskStatusStore, seedId: string, cooldownUntil: string, sender: string): void;
/**
 * Reset a task from cooldown state back to ready status.
 * Called when the cooldown period has expired and the task is ready to be retried.
 *
 * @param store - ForemanStore for the project.
 * @param seedId - The task ID to reset.
 * @param sender - Human-readable source label.
 */
export declare function resetCooldownTaskToReady(store: TaskStatusStore, seedId: string, sender: string): void;
/**
 * Mark a task as failed in the native task store.
 *
 * @param store - ForemanStore for the project.
 * @param seedId - The task ID to mark as failed.
 * @param sender - Human-readable source label.
 */
export declare function markSeedFailed(store: TaskStatusStore, seedId: string, sender: string): void;
/**
 * Update a task's status directly in the native task store.
 *
 * @param store - ForemanStore for the project.
 * @param seedId - The task ID.
 * @param status - The new status.
 * @param sender - Human-readable source label.
 */
export declare function updateSeedStatus(store: TaskStatusStore, seedId: string, status: string, sender: string): void;
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
export declare function syncTaskStatusOnStartup(store: StartupTaskStatusStore, projectId: string, opts?: {
    dryRun?: boolean;
}): Promise<SyncResult>;
export declare const enqueueCloseSeed: typeof closeSeed;
export declare const enqueueResetSeedToOpen: typeof resetSeedToOpen;
export declare const enqueueMarkBeadFailed: typeof markSeedFailed;
export declare const enqueueSetBeadStatus: typeof updateSeedStatus;
export declare function enqueueAddNotesToBead(_store: TaskStatusStore, _seedId: string, _note: string, _sender: string): void;
export declare function syncBeadStatusOnStartup(store: StartupTaskStatusStore, taskClient: LegacyTaskClient, projectId: string, opts?: {
    dryRun?: boolean;
    projectPath?: string;
}): Promise<SyncResult>;
export {};
//# sourceMappingURL=task-backend-ops.d.ts.map