/**
 * git.ts — Backward-compatibility shim for VCS operations.
 *
 * @deprecated This file is a thin shim delegating to `GitBackend` from the
 * `src/lib/vcs/` layer (TRD-011). New code should import from `src/lib/vcs/`
 * directly. These exports exist to avoid breaking existing consumers during
 * the migration period; they will be removed in a future release.
 *
 * See TRD-011 in trd-2026-004-vcs-backend-abstraction for migration details.
 */
import type { WorkflowSetupStep, WorkflowSetupCache } from "./workflow-loader.js";
import type { Workspace, MergeResult as VcsMergeResult, DeleteBranchResult as VcsDeleteBranchResult } from "./vcs/types.js";
/**
 * @deprecated Use `Workspace` from `src/lib/vcs/types.js` instead.
 * Structurally identical to `Workspace`; provided for backward compatibility.
 */
export type Worktree = Workspace;
/**
 * @deprecated Use `MergeResult` from `src/lib/vcs/types.js` instead.
 */
export type MergeResult = VcsMergeResult;
/**
 * @deprecated Use `DeleteBranchResult` from `src/lib/vcs/types.js` instead.
 */
export type DeleteBranchResult = VcsDeleteBranchResult;
/**
 * Detect which package manager to use based on lock files present in a directory.
 * Returns the package manager command ("npm", "yarn", or "pnpm").
 * Priority order: pnpm > yarn > npm (explicit lock-file check for each).
 */
export declare function detectPackageManager(dir: string): "npm" | "yarn" | "pnpm";
/**
 * Install Node.js dependencies in the given directory.
 *
 * - Detects the package manager from lock files.
 * - Skips silently if no `package.json` is present (non-Node repos).
 * - Uses `--prefer-offline` and `--no-audit` for speed when npm is used.
 * - Throws if the installation fails.
 */
export declare function installDependencies(dir: string): Promise<void>;
/**
 * Run workflow setup steps in a worktree directory.
 *
 * Each step's `command` is split on whitespace to form an argv array and
 * executed via execFileAsync with `cwd` set to `dir`.
 */
export declare function runSetupSteps(dir: string, steps: WorkflowSetupStep[]): Promise<void>;
/**
 * Run setup steps with optional caching.
 */
export declare function runSetupWithCache(worktreePath: string, projectRoot: string, steps: WorkflowSetupStep[], cache?: WorkflowSetupCache): Promise<void>;
/**
 * Find the root of the git repository containing `path`.
 *
 * @deprecated Use `GitBackend.getRepoRoot()` from `src/lib/vcs/git-backend.js` instead.
 */
export declare function getRepoRoot(path: string): Promise<string>;
/**
 * Find the main (primary) worktree root from any git worktree.
 *
 * @deprecated Use `GitBackend.getMainRepoRoot()` from `src/lib/vcs/git-backend.js` instead.
 */
export declare function getMainRepoRoot(path: string): Promise<string>;
/**
 * Detect the default/parent branch for a repository.
 *
 * @deprecated Use `GitBackend.detectDefaultBranch()` from `src/lib/vcs/git-backend.js` instead.
 */
export declare function detectDefaultBranch(repoPath: string): Promise<string>;
/**
 * Get the current branch name.
 *
 * @deprecated Use `GitBackend.getCurrentBranch()` from `src/lib/vcs/git-backend.js` instead.
 */
export declare function getCurrentBranch(repoPath: string): Promise<string>;
/**
 * Checkout a branch by name.
 *
 * @deprecated Use `GitBackend.checkoutBranch()` from `src/lib/vcs/git-backend.js` instead.
 */
export declare function checkoutBranch(repoPath: string, branchName: string): Promise<void>;
/**
 * Create a worktree for a seed.
 *
 * - Branch: foreman/<seedId>
 * - Location: <repoPath>/.foreman-worktrees/<seedId>
 * - Base: current branch (auto-detected if not specified)
 *
 * @deprecated Use `GitBackend.createWorkspace()` from `src/lib/vcs/git-backend.js` instead.
 * Note: `createWorkspace()` returns `{ workspacePath, branchName }`. This shim maps
 * `workspacePath` → `worktreePath` for backward compatibility.
 */
export declare function createWorktree(repoPath: string, seedId: string, baseBranch?: string, setupSteps?: WorkflowSetupStep[], setupCache?: WorkflowSetupCache): Promise<{
    worktreePath: string;
    branchName: string;
}>;
/**
 * Remove a worktree and prune stale entries.
 *
 * @deprecated Use `GitBackend.removeWorkspace()` from `src/lib/vcs/git-backend.js` instead.
 */
export declare function removeWorktree(repoPath: string, worktreePath: string): Promise<void>;
/**
 * List all worktrees for the repo.
 *
 * @deprecated Use `GitBackend.listWorkspaces()` from `src/lib/vcs/git-backend.js` instead.
 * The `Worktree` type is a structural alias for `Workspace`; both have identical fields.
 */
export declare function listWorktrees(repoPath: string): Promise<Worktree[]>;
/**
 * Delete a local branch with merge-safety checks.
 *
 * @deprecated Use `GitBackend.deleteBranch()` from `src/lib/vcs/git-backend.js` instead.
 */
export declare function deleteBranch(repoPath: string, branchName: string, options?: {
    force?: boolean;
    targetBranch?: string;
}): Promise<DeleteBranchResult>;
/**
 * Check whether a local branch exists in the repository.
 *
 * @deprecated Use `GitBackend.branchExists()` from `src/lib/vcs/git-backend.js` instead.
 */
export declare function gitBranchExists(repoPath: string, branchName: string): Promise<boolean>;
/**
 * Check whether a branch exists on the origin remote.
 *
 * @deprecated Use `GitBackend.branchExistsOnRemote()` from `src/lib/vcs/git-backend.js` instead.
 */
export declare function branchExistsOnOrigin(repoPath: string, branchName: string): Promise<boolean>;
/**
 * Merge a branch into the target branch.
 * Returns success status and any conflicting file paths.
 *
 * @deprecated Use `GitBackend.merge()` from `src/lib/vcs/git-backend.js` instead.
 */
export declare function mergeWorktree(repoPath: string, branchName: string, targetBranch?: string): Promise<MergeResult>;
//# sourceMappingURL=git.d.ts.map