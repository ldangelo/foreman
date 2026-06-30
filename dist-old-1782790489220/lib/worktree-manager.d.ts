/**
 * WorktreeManager — manages git worktrees at ~/.foreman/worktrees/<project-id>/<bead-id>.
 *
 * Path hierarchy:
 *   ~/.foreman/worktrees/<projectId>/<beadId>
 *
 * Each worktree is a git worktree of the project's repository, checked out
 * on a branch named `foreman/<beadId>`. This keeps per-bead workspaces isolated
 * from the main checkout without polluting the project directory.
 *
 * @module src/lib/worktree-manager
 */
export interface WorktreeInfo {
    projectId: string;
    beadId: string;
    branchName: string;
    path: string;
    exists: boolean;
    created?: boolean;
}
export interface CreateWorktreeOptions {
    projectId: string;
    beadId: string;
    repoPath: string;
    baseBranch?: string;
}
export interface ListWorktreesResult {
    projectId: string;
    worktrees: WorktreeInfo[];
}
export declare class WorktreeManager {
    #private;
    /**
     * The root directory for all Foreman worktrees.
     * Defaults to ~/.foreman/worktrees.
     */
    readonly root: string;
    constructor(options?: {
        root?: string;
    });
    /**
     * Get the worktree directory for a specific project+bead.
     */
    getWorktreePath(projectId: string, beadId: string): string;
    /**
     * Get the worktrees directory for a project.
     */
    getProjectRoot(projectId: string): string;
    /**
     * Create a git worktree for a bead.
     *
     * Branch: foreman/<beadId>
     * Path: ~/.foreman/worktrees/<projectId>/<beadId>
     *
     * If the worktree already exists, rebases onto the base branch.
     * If the branch already exists but has no worktree, attaches a new worktree.
     *
     * @throws Error if creation/rebase fails after cleanup
     */
    createWorktree(options: CreateWorktreeOptions): Promise<WorktreeInfo>;
    /**
     * Remove a worktree and its branch.
     */
    removeWorktree(projectId: string, beadId: string, repoPath: string): Promise<void>;
    /**
     * List all worktrees for a project.
     */
    listWorktrees(projectId: string): WorktreeInfo[];
    /**
     * List all worktrees across all projects.
     */
    listAllWorktrees(): ListWorktreesResult[];
    /**
     * Clean up stale worktree directories that are no longer valid git worktrees.
     * Returns the number of directories removed.
     */
    cleanStaleWorktrees(projectId: string): number;
    private _rebaseWorktree;
}
//# sourceMappingURL=worktree-manager.d.ts.map