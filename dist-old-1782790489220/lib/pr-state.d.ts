/**
 * PR State Service — fetch and summarize GitHub PR state for a task.
 *
 * Provides a unified view of the current PR state by:
 * 1. Determining the branch name for a task (from branch field or foreman/<seedId>)
 * 2. Fetching the PR state from GitHub via `gh pr view`
 * 3. Getting the current branch HEAD SHA
 * 4. Comparing to detect staleness (merged PR but branch head changed)
 *
 * @module src/lib/pr-state
 */
export type PrStateStatus = "none" | "open" | "merged" | "closed" | "error";
export interface PrState {
    /** Current PR state: none (no PR), open, merged, closed, or error */
    status: PrStateStatus;
    /** GitHub PR URL if a PR exists, null otherwise */
    url: string | null;
    /** PR number if a PR exists, null otherwise */
    number: number | null;
    /** PR head SHA at the time of PR creation/merge */
    headSha: string | null;
    /** Current branch HEAD SHA (null if branch doesn't exist locally) */
    currentHeadSha: string | null;
    /** True if PR was merged but branch head has since changed (stale) */
    isStale: boolean;
    /** Error message if status is "error" */
    error: string | null;
    /** Human-readable summary suitable for display */
    summary: string;
}
export interface GetPrStateOptions {
    /** Project path for running git/gh commands */
    projectPath: string;
    /** Branch name to check (e.g., "foreman/task-abc123"). Defaults to "foreman/<seedId>" */
    branchName?: string;
    /** Seed/task ID. Used to construct default branch name if branchName not provided */
    seedId?: string;
}
/**
 * Get the current GitHub PR state for a branch.
 *
 * This function:
 * 1. Resolves the branch name
 * 2. Fetches PR info from GitHub via `gh pr view --json`
 * 3. Gets the current branch HEAD SHA via `git rev-parse`
 * 4. Determines if the PR is stale (merged but head changed)
 *
 * @param options - Options including projectPath, branchName, and seedId
 * @returns PrState object with current PR state and staleness info
 */
export declare function getPrState(options: GetPrStateOptions): Promise<PrState>;
/**
 * Get PR states for multiple tasks efficiently.
 *
 * @param tasks - Array of task objects with id, branch, and seedId fields
 * @param projectPath - Project path for running git/gh commands
 * @returns Map of taskId -> PrState
 */
export declare function getPrStatesForTasks(tasks: Array<{
    id: string;
    branch?: string | null;
    run_id?: string | null;
}>, projectPath: string): Promise<Map<string, PrState>>;
//# sourceMappingURL=pr-state.d.ts.map