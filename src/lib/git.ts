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
import {
  detectPackageManager,
  installDependencies,
  runSetupSteps,
  runSetupWithCache,
} from "./setup.js";

import type { WorkflowSetupStep, WorkflowSetupCache } from "./workflow-loader.js";
import type { Workspace, MergeResult as VcsMergeResult, DeleteBranchResult as VcsDeleteBranchResult } from "./vcs/types.js";

export {
  detectPackageManager,
  installDependencies,
  runSetupSteps,
  runSetupWithCache,
};

// ── Backward-Compat Type Re-exports ──────────────────────────────────────────

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

// ── VCS Shim Functions — delegate to GitBackend ───────────────────────────────

/**
 * Find the root of the git repository containing `path`.
 *
 * @deprecated Use `GitBackend.getRepoRoot()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function getRepoRoot(path: string): Promise<string> {
  const backend = new GitBackend(path);
  return backend.getRepoRoot(path);
}

/**
 * Find the main (primary) worktree root from any git worktree.
 *
 * @deprecated Use `GitBackend.getMainRepoRoot()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function getMainRepoRoot(path: string): Promise<string> {
  const backend = new GitBackend(path);
  return backend.getMainRepoRoot(path);
}

/**
 * Detect the default/parent branch for a repository.
 *
 * @deprecated Use `GitBackend.detectDefaultBranch()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function detectDefaultBranch(repoPath: string): Promise<string> {
  const backend = new GitBackend(repoPath);
  return backend.detectDefaultBranch(repoPath);
}

/**
 * Get the current branch name.
 *
 * @deprecated Use `GitBackend.getCurrentBranch()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function getCurrentBranch(repoPath: string): Promise<string> {
  const backend = new GitBackend(repoPath);
  return backend.getCurrentBranch(repoPath);
}

/**
 * Checkout a branch by name.
 *
 * @deprecated Use `GitBackend.checkoutBranch()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function checkoutBranch(repoPath: string, branchName: string): Promise<void> {
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
export async function createWorktree(
  repoPath: string,
  seedId: string,
  baseBranch?: string,
  setupSteps?: WorkflowSetupStep[],
  setupCache?: WorkflowSetupCache,
): Promise<{ worktreePath: string; branchName: string }> {
  const backend = new GitBackend(repoPath);
  const result = await backend.createWorkspace(repoPath, seedId, baseBranch);
  const { workspacePath, branchName } = result;

  // Handle setup steps (not part of GitBackend.createWorkspace)
  if (setupSteps && setupSteps.length > 0) {
    await runSetupWithCache(workspacePath, repoPath, setupSteps, setupCache);
  } else {
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
export async function removeWorktree(
  repoPath: string,
  worktreePath: string,
): Promise<void> {
  const backend = new GitBackend(repoPath);
  return backend.removeWorkspace(repoPath, worktreePath);
}

/**
 * List all worktrees for the repo.
 *
 * @deprecated Use `GitBackend.listWorkspaces()` from `src/lib/vcs/git-backend.js` instead.
 * The `Worktree` type is a structural alias for `Workspace`; both have identical fields.
 */
export async function listWorktrees(repoPath: string): Promise<Worktree[]> {
  const backend = new GitBackend(repoPath);
  return backend.listWorkspaces(repoPath);
}

/**
 * Delete a local branch with merge-safety checks.
 *
 * @deprecated Use `GitBackend.deleteBranch()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function deleteBranch(
  repoPath: string,
  branchName: string,
  options?: { force?: boolean; targetBranch?: string },
): Promise<DeleteBranchResult> {
  const backend = new GitBackend(repoPath);
  return backend.deleteBranch(repoPath, branchName, options);
}

/**
 * Check whether a local branch exists in the repository.
 *
 * @deprecated Use `GitBackend.branchExists()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function gitBranchExists(
  repoPath: string,
  branchName: string,
): Promise<boolean> {
  const backend = new GitBackend(repoPath);
  return backend.branchExists(repoPath, branchName);
}

/**
 * Check whether a branch exists on the origin remote.
 *
 * @deprecated Use `GitBackend.branchExistsOnRemote()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function branchExistsOnOrigin(
  repoPath: string,
  branchName: string,
): Promise<boolean> {
  const backend = new GitBackend(repoPath);
  return backend.branchExistsOnRemote(repoPath, branchName);
}

/**
 * Merge a branch into the target branch.
 * Returns success status and any conflicting file paths.
 *
 * @deprecated Use `GitBackend.merge()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function mergeWorktree(
  repoPath: string,
  branchName: string,
  targetBranch?: string,
): Promise<MergeResult> {
  const backend = new GitBackend(repoPath);
  return backend.merge(repoPath, branchName, targetBranch);
}
