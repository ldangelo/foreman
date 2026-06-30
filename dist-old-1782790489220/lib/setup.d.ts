import type { WorkflowSetupStep, WorkflowSetupCache } from "./workflow-loader.js";
import type { WorkspaceHooks } from "../orchestrator/types.js";
/**
 * Result of a hook execution.
 */
export interface HookResult {
    success: boolean;
    output: string;
    timedOut: boolean;
}
/**
 * Run a workspace lifecycle hook command.
 *
 * Executes the given shell command in the workspace directory with the
 * specified environment variables and timeout.
 *
 * @param hookCmd - Shell command to execute (e.g., "git clone https://github.com/org/repo.git")
 * @param workspacePath - Working directory for the hook
 * @param env - Additional environment variables to pass (FOREMAN_WORKSPACE_PATH etc.)
 * @param timeoutMs - Timeout in milliseconds (default: 60000)
 * @param label - Descriptive label for logging (e.g., "afterCreate", "beforeRun")
 * @returns Promise<HookResult> with success flag, combined stdout/stderr, and timedOut flag
 *
 * Hook commands run through the platform shell so quoted arguments,
 * environment expansion, pipes, redirection, and command chaining behave like
 * the examples in project config.
 */
export declare function runHook(hookCmd: string, workspacePath: string, env: Record<string, string>, timeoutMs?: number, label?: string): Promise<HookResult>;
/**
 * Run workspace lifecycle hooks for a given stage.
 *
 * @param hooks - WorkspaceHooks configuration
 * @param stage - One of: afterCreate, beforeRun, afterRun, beforeRemove
 * @param workspacePath - Working directory for the hooks
 * @param env - Environment variables to pass to hooks
 * @returns Promise that resolves when all hooks for the stage complete
 * @throws Error if afterCreate or beforeRun hooks fail (fatal stages)
 */
export declare function runWorkspaceHook(hooks: WorkspaceHooks, stage: keyof Pick<WorkspaceHooks, "afterCreate" | "beforeRun" | "afterRun" | "beforeRemove">, workspacePath: string, env: Record<string, string>): Promise<void>;
/**
 * Detect which package manager to use based on lock files present in a directory.
 * Priority order: pnpm > yarn > npm.
 */
export declare function detectPackageManager(dir: string): "npm" | "yarn" | "pnpm";
/**
 * Install Node.js dependencies in the given directory.
 */
export declare function installDependencies(dir: string): Promise<void>;
/**
 * Run workflow setup steps in a workspace directory.
 */
export declare function runSetupSteps(dir: string, steps: WorkflowSetupStep[]): Promise<void>;
/**
 * Run setup steps with optional caching.
 */
export declare function runSetupWithCache(worktreePath: string, projectRoot: string, steps: WorkflowSetupStep[], cache?: WorkflowSetupCache): Promise<void>;
//# sourceMappingURL=setup.d.ts.map