/**
 * GitBackend — Git-specific VCS backend implementation.
 *
 * Implements the `VcsBackend` interface using standard `git` CLI commands.
 * Extracted from src/lib/git.ts into a class-based, backend-agnostic design.
 *
 * @module src/lib/vcs/git-backend
 */
import type { Workspace, WorkspaceResult, MergeResult, RebaseResult, DeleteBranchOptions, DeleteBranchResult, PushOptions, FinalizeTemplateVars, FinalizeCommands } from "./types.js";
import type { VcsBackend } from "./interface.js";
/**
 * GitBackend encapsulates git-specific VCS operations for a given project path.
 *
 * Constructor receives the project root path; all methods operate relative to it
 * unless given an explicit path argument (for worktree-aware operations).
 */
export declare class GitBackend implements VcsBackend {
    readonly name: "git";
    readonly projectPath: string;
    constructor(projectPath: string);
    /**
     * Execute a git command in the given working directory.
     * Returns trimmed stdout on success; throws with a formatted error on failure.
     */
    private git;
    /**
     * Find the root of the git repository containing `path`.
     *
     * Returns the worktree root for linked worktrees.
     * Use `getMainRepoRoot()` to always get the primary project root.
     */
    getRepoRoot(path: string): Promise<string>;
    /**
     * Find the main (primary) worktree root from any git worktree.
     *
     * `git rev-parse --show-toplevel` returns the *current* worktree root,
     * which for a linked worktree is the worktree directory itself — not the
     * main project root.  This function resolves the common `.git` directory
     * and strips the trailing `/.git` to always return the main project root.
     */
    getMainRepoRoot(path: string): Promise<string>;
    /**
     * Detect the default/parent branch for a repository.
     *
     * Resolution order:
     * 1. `git config get git-town.main-branch` — respect user's explicit development trunk config
     * 2. `git symbolic-ref refs/remotes/origin/HEAD --short` → strips "origin/" prefix
     *    (e.g. "origin/main" → "main"). Works when the remote has been fetched.
     * 3. Check whether "main" exists as a local branch.
     * 4. Check whether "master" exists as a local branch.
     * 5. Fall back to the current branch (`getCurrentBranch()`).
     */
    detectDefaultBranch(repoPath: string): Promise<string>;
    /**
     * Get the current branch name.
     */
    getCurrentBranch(repoPath: string): Promise<string>;
    /**
     * Checkout a branch by name.
     */
    checkoutBranch(repoPath: string, branchName: string): Promise<void>;
    /**
     * Return true if the given local branch exists.
     */
    branchExists(repoPath: string, branchName: string): Promise<boolean>;
    /**
     * Return true if the branch exists on the origin remote.
     */
    branchExistsOnRemote(repoPath: string, branchName: string): Promise<boolean>;
    /**
     * Delete a local branch with merge-safety checks.
     *
     * - If fully merged into targetBranch → uses `git branch -D` (after verifying via merge-base).
     * - If NOT merged and `force: true` → force-deletes.
     * - If NOT merged and `force: false` (default) → skips.
     * - If branch doesn't exist → returns `{ deleted: false, wasFullyMerged: true }`.
     */
    deleteBranch(repoPath: string, branchName: string, options?: DeleteBranchOptions): Promise<DeleteBranchResult>;
    /**
     * Create a git worktree for a seed.
     *
     * - Branch: foreman/<seedId>
     * - Location: <repoPath>/.foreman-worktrees/<seedId>
     * - Base: baseBranch or current branch
     *
     * If the worktree already exists, rebases onto the base branch.
     */
    createWorkspace(repoPath: string, seedId: string, baseBranch?: string): Promise<WorkspaceResult>;
    /**
     * Remove a git worktree and prune stale metadata.
     */
    removeWorkspace(repoPath: string, workspacePath: string): Promise<void>;
    /**
     * List all git worktrees for the repo.
     */
    listWorkspaces(repoPath: string): Promise<Workspace[]>;
    /**
     * Stage all changes (git add -A).
     */
    stageAll(workspacePath: string): Promise<void>;
    /**
     * Commit staged changes with the given message.
     */
    commit(workspacePath: string, message: string): Promise<void>;
    /**
     * Push the branch to origin.
     */
    push(workspacePath: string, branchName: string, options?: PushOptions): Promise<void>;
    /**
     * Pull/fast-forward the current branch from origin.
     */
    pull(workspacePath: string, branchName: string): Promise<void>;
    /**
     * Rebase the current branch onto `onto`.
     */
    rebase(workspacePath: string, onto: string): Promise<RebaseResult>;
    /**
     * Abort an in-progress rebase.
     */
    abortRebase(workspacePath: string): Promise<void>;
    /**
     * Merge a source branch into a target branch using --no-ff.
     * Stashes any uncommitted changes before merging.
     */
    merge(repoPath: string, sourceBranch: string, targetBranch?: string): Promise<MergeResult>;
    /**
     * Get the current HEAD commit hash.
     */
    getHeadId(workspacePath: string): Promise<string>;
    /**
     * Resolve an arbitrary ref (branch name, remote ref, tag, etc.) to its commit hash.
     * Equivalent to `git rev-parse <ref>`.
     * Throws if the ref does not exist.
     */
    resolveRef(repoPath: string, ref: string): Promise<string>;
    /**
     * Fetch updates from origin (no merge).
     */
    fetch(repoPath: string): Promise<void>;
    /**
     * Get a unified diff between two refs.
     */
    diff(repoPath: string, from: string, to: string): Promise<string>;
    /**
     * Get a list of file paths changed between two refs (three-dot semantics).
     * Equivalent to `git diff --name-only <from>...<to>`.
     * Returns an empty array if no files changed or refs do not exist.
     */
    getChangedFiles(repoPath: string, from: string, to: string): Promise<string[]>;
    /**
     * Get the Unix timestamp (seconds since epoch) of the most recent commit on a ref.
     * Equivalent to `git log -1 --format=%ct <ref>`.
     * Returns null if the ref does not exist or the timestamp cannot be determined.
     */
    getRefCommitTimestamp(repoPath: string, ref: string): Promise<number | null>;
    /**
     * List files modified (staged or unstaged) in the workspace.
     */
    getModifiedFiles(workspacePath: string): Promise<string[]>;
    /**
     * List files with unresolved merge/rebase conflicts.
     */
    getConflictingFiles(workspacePath: string): Promise<string[]>;
    /**
     * Get working tree status (porcelain format).
     */
    status(workspacePath: string): Promise<string>;
    /**
     * Discard all unstaged changes and untracked files.
     */
    cleanWorkingTree(workspacePath: string): Promise<void>;
    /**
     * Return pre-computed git finalize commands for prompt rendering.
     */
    getFinalizeCommands(vars: FinalizeTemplateVars): FinalizeCommands;
}
//# sourceMappingURL=git-backend.d.ts.map