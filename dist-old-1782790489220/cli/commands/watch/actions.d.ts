/**
 * Approve a backlog task, moving it to ready status.
 * Called when the operator presses 'a' on a selected task.
 *
 * @param taskId      - The task ID to approve
 * @param projectPath - Path to the project that owns this task
 * @returns true on success, false on failure
 */
export declare function approveTask(taskId: string, projectPath: string): Promise<boolean>;
/**
 * Retry a failed/stuck/conflict task, moving it back to backlog.
 * Called when the operator presses 'r' on a selected task.
 *
 * @param taskId      - The task ID to retry
 * @param projectPath - Path to the project that owns this task
 * @returns true on success, false on failure
 */
export declare function retryTask(taskId: string, projectPath: string): Promise<boolean>;
//# sourceMappingURL=actions.d.ts.map