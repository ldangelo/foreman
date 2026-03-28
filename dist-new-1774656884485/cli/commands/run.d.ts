import { Command } from "commander";
import { BvClient } from "../../lib/bv.js";
import type { ITaskClient } from "../../lib/task-client.js";
export { autoMerge } from "../../orchestrator/auto-merge.js";
export type { AutoMergeOpts, AutoMergeResult } from "../../orchestrator/auto-merge.js";
/**
 * Result returned by createTaskClients.
 * Contains the task client to pass to Dispatcher and an optional BvClient.
 */
export interface TaskClientResult {
    taskClient: ITaskClient;
    bvClient: BvClient | null;
}
/**
 * Instantiate the br task-tracking client(s).
 *
 * TRD-024: sd backend removed. Always returns a BeadsRustClient after verifying
 * the binary exists, plus a BvClient for graph-aware triage.
 *
 * Throws if the br binary cannot be found.
 */
export declare function createTaskClients(projectPath: string): Promise<TaskClientResult>;
/**
 * Check whether any in-progress beads have a `branch:` label that differs
 * from the current git branch.
 *
 * Edge cases handled:
 * - No in-progress beads: no prompt, return false (continue normally)
 * - Label matches current branch: no prompt, return false (continue normally)
 * - No branch: label on bead: no prompt, return false (backward compat)
 * - Label differs: show prompt, switch branch (return false) or exit (return true)
 *
 * Returns true if the caller should abort (user declined to switch).
 */
export declare function checkBranchMismatch(taskClient: ITaskClient, projectPath: string): Promise<boolean>;
export declare const runCommand: Command;
//# sourceMappingURL=run.d.ts.map