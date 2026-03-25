import type { WorkflowSetupStep, WorkflowSetupCache } from "./workflow-loader.js";
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
 *
 * Steps with `failFatal !== false` (i.e. default true) throw on non-zero exit.
 * Steps with `failFatal === false` log a warning and continue.
 */
export declare function runSetupSteps(dir: string, steps: WorkflowSetupStep[]): Promise<void>;
/**
 * Run setup steps with optional caching.
 *
 * If `cache` is configured in the workflow YAML:
 *   1. Try to restore from cache (symlink). If hit → skip setup steps.
 *   2. If miss → run setup steps → populate cache for next time.
 *
 * If no `cache` → just run setup steps normally.
 */
export declare function runSetupWithCache(worktreePath: string, projectRoot: string, steps: WorkflowSetupStep[], cache?: WorkflowSetupCache): Promise<void>;
export interface Worktree {
    path: string;
    branch: string;
    head: string;
    bare: boolean;
}
export interface MergeResult {
    success: boolean;
    conflicts?: string[];
}
export interface DeleteBranchResult {
    deleted: boolean;
    wasFullyMerged: boolean;
}
/**
 * Find the root of the git repository containing `path`.
 */
export declare function getRepoRoot(path: string): Promise<string>;
/**
 * Find the main (primary) worktree root from any git worktree.
 *
 * `git rev-parse --show-toplevel` returns the *current* worktree root,
 * which for a linked worktree is the worktree directory itself — not the
 * main project root.  This function resolves the common `.git` directory
 * and strips the trailing `/.git` to always return the main project root.
 */
export declare function getMainRepoRoot(path: string): Promise<string>;
/**
 * Detect the default/parent branch for a repository.
 *
 * Resolution order:
 * 1. `git symbolic-ref refs/remotes/origin/HEAD --short` → strips "origin/" prefix
 *    (e.g. "origin/main" → "main"). Works when the remote has been fetched.
 * 2. Check whether "main" exists as a local branch.
 * 3. Check whether "master" exists as a local branch.
 * 4. Fall back to the current branch.
 */
export declare function detectDefaultBranch(repoPath: string): Promise<string>;
/**
 * Get the current branch name.
 */
export declare function getCurrentBranch(repoPath: string): Promise<string>;
/**
 * Checkout a branch by name.
 * Throws if the branch does not exist or the checkout fails.
 */
export declare function checkoutBranch(repoPath: string, branchName: string): Promise<void>;
/**
 * Create a worktree for a seed.
 *
 * - Branch: foreman/<seedId>
 * - Location: <repoPath>/.foreman-worktrees/<seedId>
 * - Base: current branch (auto-detected if not specified)
 */
export declare function createWorktree(repoPath: string, seedId: string, baseBranch?: string, setupSteps?: WorkflowSetupStep[], setupCache?: WorkflowSetupCache): Promise<{
    worktreePath: string;
    branchName: string;
}>;
/**
 * Remove a worktree and prune stale entries.
 *
 * After removing the worktree, runs `git worktree prune` to delete any stale
 * `.git/worktrees/<name>` metadata left behind. The prune step is non-fatal —
 * if it fails, a warning is logged but the function still resolves successfully.
 */
export declare function removeWorktree(repoPath: string, worktreePath: string): Promise<void>;
/**
 * List all worktrees for the repo.
 */
export declare function listWorktrees(repoPath: string): Promise<Worktree[]>;
/**
 * Delete a local branch with merge-safety checks.
 *
 * - If the branch is fully merged into targetBranch (default "main"), uses `git branch -d` (safe delete).
 * - If NOT merged and `force: true`, uses `git branch -D` (force delete).
 * - If NOT merged and `force: false` (default), skips deletion and returns `{ deleted: false, wasFullyMerged: false }`.
 * - If the branch does not exist, returns `{ deleted: false, wasFullyMerged: true }` (already gone).
 */
export declare function deleteBranch(repoPath: string, branchName: string, options?: {
    force?: boolean;
    targetBranch?: string;
}): Promise<DeleteBranchResult>;
/**
 * Check whether a local branch exists in the repository.
 *
 * Uses `git show-ref --verify --quiet refs/heads/<branchName>`.
 * Returns `false` if the branch does not exist or any error occurs.
 */
export declare function gitBranchExists(repoPath: string, branchName: string): Promise<boolean>;
/**
 * Check whether a branch exists on the origin remote.
 *
 * Uses `git rev-parse origin/<branchName>` against local remote-tracking refs.
 * Returns `false` if there is no remote, the branch doesn't exist on origin,
 * or any other error occurs (fail-safe: unknown → don't delete).
 */
export declare function branchExistsOnOrigin(repoPath: string, branchName: string): Promise<boolean>;
/**
 * Merge a branch into the target branch.
 * Returns success status and any conflicting file paths.
 */
export declare function mergeWorktree(repoPath: string, branchName: string, targetBranch?: string): Promise<MergeResult>;
//# sourceMappingURL=git.d.ts.map