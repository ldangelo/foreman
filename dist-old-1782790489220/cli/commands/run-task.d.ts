/**
 * `foreman run task` — Direct workflow execution for a specific task.
 *
 * This command bypasses state-gating and executes the specified workflow
 * for a given task regardless of its current state (failed, closed,
 * in-progress, backlog, etc.).
 *
 * Usage: foreman run task <task-id> <workflow-path> [options]
 *
 * This separates scheduling/orchestration decisions from deterministic
 * workflow execution, making tasks directly runnable for debugging,
 * recovery, testing, and manual operation.
 *
 * @module src/cli/commands/run-task
 */
import { Command } from "commander";
/**
 * Build the deprecation warning for the retired `--skip-explore` /
 * `--skip-review` flags.
 *
 * These flags were never consumed by the workflow YAML-driven pipeline — phase
 * shape is defined entirely by the workflow YAML. They are kept as hidden
 * no-ops for backwards compatibility.
 *
 * The suggested replacement is context-aware: `foreman run` selects workflows
 * via the `--workflow <name>` flag, while `foreman run task` takes the
 * workflow as a positional argument.
 *
 * @param context - Which command emitted the warning: "run" (default) or "task".
 * @returns The one-line warning text, or null when neither flag is set.
 */
export declare function skipFlagsDeprecationWarning(opts: {
    skipExplore?: boolean;
    skipReview?: boolean;
}, context?: "run" | "task"): string | null;
/**
 * Execute a workflow directly for a specific task, bypassing state-gating.
 *
 * Key behaviors:
 * - Runs the specified workflow for the given task regardless of task state
 * - Uses normal task metadata, workspace/run records, logs, reports, mail
 * - Does NOT require the task to be ready/backlog/etc.
 * - Maintains worktree locking for safety
 */
export declare function runTaskAction(taskId: string, workflowPath: string, opts: {
    model?: string;
    /** @deprecated No effect — phase shape is defined by the workflow YAML. */
    skipExplore?: boolean;
    /** @deprecated No effect — phase shape is defined by the workflow YAML. */
    skipReview?: boolean;
    dryRun?: boolean;
    watch?: boolean;
    targetBranch?: string;
    runId?: string;
    project?: string;
    projectPath?: string;
}): Promise<number>;
export declare const runTaskCommand: Command;
//# sourceMappingURL=run-task.d.ts.map