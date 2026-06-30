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
import { GitBackend } from "./vcs/git-backend.js";
import { detectPackageManager, installDependencies, runSetupSteps, runSetupWithCache, } from "./setup.js";
export { detectPackageManager, installDependencies, runSetupSteps, runSetupWithCache, };
// ── VCS Shim Functions — delegate to GitBackend ───────────────────────────────
/**
 * Find the root of the git repository containing `path`.
 *
 * @deprecated Use `GitBackend.getRepoRoot()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function getRepoRoot(path) {
    const backend = new GitBackend(path);
    return backend.getRepoRoot(path);
}
/**
 * Find the main (primary) worktree root from any git worktree.
 *
 * @deprecated Use `GitBackend.getMainRepoRoot()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function getMainRepoRoot(path) {
    const backend = new GitBackend(path);
    return backend.getMainRepoRoot(path);
}
/**
 * Detect the default/parent branch for a repository.
 *
 * @deprecated Use `GitBackend.detectDefaultBranch()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function detectDefaultBranch(repoPath) {
    const backend = new GitBackend(repoPath);
    return backend.detectDefaultBranch(repoPath);
}
/**
 * Get the current branch name.
 *
 * @deprecated Use `GitBackend.getCurrentBranch()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function getCurrentBranch(repoPath) {
    const backend = new GitBackend(repoPath);
    return backend.getCurrentBranch(repoPath);
}
/**
 * Checkout a branch by name.
 *
 * @deprecated Use `GitBackend.checkoutBranch()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function checkoutBranch(repoPath, branchName) {
    const backend = new GitBackend(repoPath);
    return backend.checkoutBranch(repoPath, branchName);
}
/**
 * Create a worktree for a seed.
 *
 * - Branch: foreman/<seedId>
 * - Location: Foreman's workspace root for the repo (default: external to the
 *   repo at <repoParent>/.foreman-worktrees/<repoName>/<seedId>)
 * - Base: current branch (auto-detected if not specified)
 *
 * @deprecated Use `GitBackend.createWorkspace()` from `src/lib/vcs/git-backend.js` instead.
 * Note: `createWorkspace()` returns `{ workspacePath, branchName }`. This shim maps
 * `workspacePath` → `worktreePath` for backward compatibility.
 */
export async function createWorktree(repoPath, seedId, baseBranch, setupSteps, setupCache) {
    const backend = new GitBackend(repoPath);
    const result = await backend.createWorkspace(repoPath, seedId, baseBranch);
    const { workspacePath, branchName } = result;
    // Handle setup steps (not part of GitBackend.createWorkspace)
    if (setupSteps && setupSteps.length > 0) {
        await runSetupWithCache(workspacePath, repoPath, setupSteps, setupCache);
    }
    else {
        await installDependencies(workspacePath);
    }
    // Map workspacePath → worktreePath for old API shape
    return { worktreePath: workspacePath, branchName };
}
/**
 * Remove a worktree and prune stale entries.
 *
 * @deprecated Use `GitBackend.removeWorkspace()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function removeWorktree(repoPath, worktreePath) {
    const backend = new GitBackend(repoPath);
    return backend.removeWorkspace(repoPath, worktreePath);
}
/**
 * List all worktrees for the repo.
 *
 * @deprecated Use `GitBackend.listWorkspaces()` from `src/lib/vcs/git-backend.js` instead.
 * The `Worktree` type is a structural alias for `Workspace`; both have identical fields.
 */
export async function listWorktrees(repoPath) {
    const backend = new GitBackend(repoPath);
    return backend.listWorkspaces(repoPath);
}
/**
 * Delete a local branch with merge-safety checks.
 *
 * @deprecated Use `GitBackend.deleteBranch()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function deleteBranch(repoPath, branchName, options) {
    const backend = new GitBackend(repoPath);
    return backend.deleteBranch(repoPath, branchName, options);
}
/**
 * Check whether a local branch exists in the repository.
 *
 * @deprecated Use `GitBackend.branchExists()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function gitBranchExists(repoPath, branchName) {
    const backend = new GitBackend(repoPath);
    return backend.branchExists(repoPath, branchName);
}
/**
 * Check whether a branch exists on the origin remote.
 *
 * @deprecated Use `GitBackend.branchExistsOnRemote()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function branchExistsOnOrigin(repoPath, branchName) {
    const backend = new GitBackend(repoPath);
    return backend.branchExistsOnRemote(repoPath, branchName);
}
/**
 * Merge a branch into the target branch.
 * Returns success status and any conflicting file paths.
 *
 * @deprecated Use `GitBackend.merge()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function mergeWorktree(repoPath, branchName, targetBranch) {
    const backend = new GitBackend(repoPath);
    return backend.merge(repoPath, branchName, targetBranch);
}
//# sourceMappingURL=git.js.map