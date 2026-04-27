/**
 * actions.ts — Operator actions for the unified watch display.
 *
 * Implements:
 * - approveTask: backlog → ready
 * - retryTask: failed/stuck/conflict → backlog
 *
 * Reuses logic from dashboard.ts (which now implements these actions
 * via daemon-backed task APIs).
 */
import { approveTask as approveDashboard, retryTask as retryDashboard } from "../dashboard.js";

/**
 * Approve a backlog task, moving it to ready status.
 * Called when the operator presses 'a' on a selected task.
 *
 * @param taskId      - The task ID to approve
 * @param projectPath - Path to the project that owns this task
 * @returns true on success, false on failure
 */
export async function approveTask(taskId: string, projectPath: string): Promise<boolean> {
  try {
    await approveDashboard(taskId, projectPath);
    return true;
  } catch (err) {
    return false;
  }
}

/**
 * Retry a failed/stuck/conflict task, moving it back to backlog.
 * Called when the operator presses 'r' on a selected task.
 *
 * @param taskId      - The task ID to retry
 * @param projectPath - Path to the project that owns this task
 * @returns true on success, false on failure
 */
export async function retryTask(taskId: string, projectPath: string): Promise<boolean> {
  try {
    await retryDashboard(taskId, projectPath);
    return true;
  } catch (err) {
    return false;
  }
}
