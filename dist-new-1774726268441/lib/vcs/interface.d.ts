/**
 * VcsBackend interface definition.
 *
 * Separated from index.ts to avoid circular dependencies between the interface
 * and its implementations (GitBackend, JujutsuBackend).
 *
 * @module src/lib/vcs/interface
 */
import type { Workspace, WorkspaceResult, MergeResult, RebaseResult, DeleteBranchOptions, DeleteBranchResult, PushOptions, FinalizeTemplateVars, FinalizeCommands } from "./types.js";
/**
 * Backend-agnostic interface for all VCS operations used by Foreman.
 *
 * Both `GitBackend` and `JujutsuBackend` implement this interface so that
 * orchestration code (Dispatcher, Refinery, ConflictResolver, finalize prompt
 * rendering) is decoupled from the concrete VCS tool.
 */
export interface VcsBackend {
    /** Name identifier for this backend (e.g. 'git' or 'jujutsu'). */
    readonly name: 'git' | 'jujutsu';
    /**
     * Find the root of the VCS repository containing `path`.
     * For git: returns `git rev-parse --show-toplevel`.
     * For jujutsu: returns the workspace root.
     */
    getRepoRoot(path: string): Promise<string>;
    /**
     * Find the main (primary) repository root from any workspace/worktree.
     * For linked git worktrees this traverses up via `--git-common-dir`.
     * For jujutsu colocated repos this is the same as `getRepoRoot`.
     */
    getMainRepoRoot(path: string): Promise<string>;
    /**
     * Detect the default/trunk branch for the repository.
     * Resolution order varies by backend (git-town config, origin/HEAD, main, master…).
     */
    detectDefaultBranch(repoPath: string): Promise<string>;
    /**
     * Get the name of the currently checked-out branch/bookmark.
     */
    getCurrentBranch(repoPath: string): Promise<string>;
    /**
     * Checkout (switch to) a branch or bookmark by name.
     */
    checkoutBranch(repoPath: string, branchName: string): Promise<void>;
    /**
     * Return true if the given branch/bookmark exists locally.
     */
    branchExists(repoPath: string, branchName: string): Promise<boolean>;
    /**
     * Return true if the branch/bookmark exists on the remote origin.
     */
    branchExistsOnRemote(repoPath: string, branchName: string): Promise<boolean>;
    /**
     * Delete a local branch/bookmark with optional merge-safety checks.
     */
    deleteBranch(repoPath: string, branchName: string, options?: DeleteBranchOptions): Promise<DeleteBranchResult>;
    /**
     * Create a new workspace (git worktree / jj workspace) for a seed.
     *
     * Branch name: `foreman/<seedId>`
     * Location: `<repoPath>/.foreman-worktrees/<seedId>`
     */
    createWorkspace(repoPath: string, seedId: string, baseBranch?: string): Promise<WorkspaceResult>;
    /**
     * Remove a workspace and clean up associated metadata.
     */
    removeWorkspace(repoPath: string, workspacePath: string): Promise<void>;
    /**
     * List all workspaces for the repository.
     */
    listWorkspaces(repoPath: string): Promise<Workspace[]>;
    /**
     * Stage all changes in the workspace.
     * For jujutsu this is a no-op (auto-staged), but the command is still
     * returned by `getFinalizeCommands()` as an empty string.
     */
    stageAll(workspacePath: string): Promise<void>;
    /**
     * Commit staged changes with the given message.
     */
    commit(workspacePath: string, message: string): Promise<void>;
    /**
     * Push the branch/bookmark to the remote.
     */
    push(workspacePath: string, branchName: string, options?: PushOptions): Promise<void>;
    /**
     * Pull/fetch and fast-forward the current branch from the remote.
     */
    pull(workspacePath: string, branchName: string): Promise<void>;
    /**
     * Rebase the workspace onto the given target branch/bookmark.
     * Returns a `RebaseResult` indicating success or conflicts.
     */
    rebase(workspacePath: string, onto: string): Promise<RebaseResult>;
    /**
     * Abort an in-progress rebase, returning the workspace to pre-rebase state.
     */
    abortRebase(workspacePath: string): Promise<void>;
    /**
     * Merge a source branch/bookmark into a target branch.
     * Returns `MergeResult` with success flag and any conflicting files.
     */
    merge(repoPath: string, sourceBranch: string, targetBranch?: string): Promise<MergeResult>;
    /**
     * Get the current HEAD commit hash (git) or change ID (jj).
     */
    getHeadId(workspacePath: string): Promise<string>;
    /**
     * Resolve an arbitrary ref (branch name, remote ref, etc.) to its commit hash.
     * For git: equivalent to `git rev-parse <ref>`.
     * For jujutsu: resolves a revision expression to its change ID.
     * Throws if the ref does not exist.
     */
    resolveRef(repoPath: string, ref: string): Promise<string>;
    /**
     * Fetch updates from the remote (does not merge/rebase).
     */
    fetch(repoPath: string): Promise<void>;
    /**
     * Get a unified diff between two refs.
     */
    diff(repoPath: string, from: string, to: string): Promise<string>;
    /**
     * Get a list of file paths changed between two refs (three-dot semantics).
     * For git: equivalent to `git diff --name-only <from>...<to>`.
     * For jujutsu: lists files changed between two revisions.
     * Returns an empty array if no files have changed or refs do not exist.
     */
    getChangedFiles(repoPath: string, from: string, to: string): Promise<string[]>;
    /**
     * List files modified (staged or unstaged) in the workspace.
     */
    getModifiedFiles(workspacePath: string): Promise<string[]>;
    /**
     * List files that currently have merge/rebase conflicts.
     */
    getConflictingFiles(workspacePath: string): Promise<string[]>;
    /**
     * Get the working tree status as a string (equivalent to git status --porcelain).
     */
    status(workspacePath: string): Promise<string>;
    /**
     * Discard all unstaged changes and remove untracked files.
     */
    cleanWorkingTree(workspacePath: string): Promise<void>;
    /**
     * Return pre-computed finalize commands for prompt rendering.
     * The Finalize agent embeds these verbatim in shell commands.
     */
    getFinalizeCommands(vars: FinalizeTemplateVars): FinalizeCommands;
}
//# sourceMappingURL=interface.d.ts.map