/**
 * JujutsuBackend — Jujutsu (jj) VCS backend implementation.
 *
 * Implements the `VcsBackend` interface using the `jj` CLI.
 * Assumes a **colocated** Jujutsu repository (`.jj/` + `.git/` both present),
 * which is the only mode supported by Foreman.
 *
 * Key differences from GitBackend:
 * - Workspaces use `jj workspace add` / `jj workspace forget`.
 * - Branches are called "bookmarks" in jj (`jj bookmark`).
 * - Staging is automatic — `stageAll()` is a no-op.
 * - Commits use `jj describe -m` + `jj new`.
 * - Push requires `--allow-new` for first push of a new bookmark.
 * - Rebase uses `jj rebase -d <destination>`.
 *
 * @module src/lib/vcs/jujutsu-backend
 */
import type { Workspace, WorkspaceResult, MergeResult, RebaseResult, DeleteBranchOptions, DeleteBranchResult, PushOptions, FinalizeTemplateVars, FinalizeCommands } from "./types.js";
import type { VcsBackend } from "./interface.js";
/**
 * JujutsuBackend encapsulates jj-specific VCS operations for a Foreman project.
 *
 * Foreman assumes a colocated jj repository so that git-based tooling
 * (GitHub Actions, gh CLI, etc.) continues to work alongside jj.
 */
export declare class JujutsuBackend implements VcsBackend {
    readonly name: "jujutsu";
    readonly projectPath: string;
    constructor(projectPath: string);
    /**
     * Execute a jj command in the given working directory.
     * Returns trimmed stdout on success; throws with a formatted error on failure.
     */
    private jj;
    /**
     * Execute a git command in the given working directory.
     * Used for operations that still need git in colocated mode
     * (e.g. getRepoRoot, getMainRepoRoot).
     */
    private git;
    /**
     * Find the root of the jj repository containing `path`.
     * In colocated mode this delegates to git rev-parse since both .jj and .git exist.
     */
    getRepoRoot(path: string): Promise<string>;
    /**
     * Find the main (primary) repository root from any workspace.
     * In colocated mode, delegates to git rev-parse --git-common-dir.
     */
    getMainRepoRoot(path: string): Promise<string>;
    /**
     * Detect the default/trunk branch for the repository.
     *
     * Resolution order:
     * 1. Look for a 'main' bookmark.
     * 2. Look for a 'master' bookmark.
     * 3. Fall back to the current bookmark.
     */
    detectDefaultBranch(repoPath: string): Promise<string>;
    /**
     * Get the name of the currently active bookmark.
     * Uses `jj log --no-graph -r @ -T 'bookmarks'` to find the current bookmark.
     * Falls back to the short change ID if no bookmark is set.
     */
    getCurrentBranch(repoPath: string): Promise<string>;
    /**
     * Checkout (switch to) a bookmark by name.
     * In jj this is `jj edit <bookmark>`.
     *
     * Attempts to track the remote bookmark first (for remote-backed branches),
     * but gracefully ignores failures when the bookmark only exists locally.
     */
    checkoutBranch(repoPath: string, branchName: string): Promise<void>;
    /**
     * Return true if the given bookmark exists locally.
     */
    branchExists(repoPath: string, branchName: string): Promise<boolean>;
    /**
     * Return true if the bookmark exists on the origin remote.
     */
    branchExistsOnRemote(repoPath: string, branchName: string): Promise<boolean>;
    /**
     * Delete a bookmark with optional merge-safety checks.
     * Uses `jj bookmark delete <name>`.
     */
    deleteBranch(repoPath: string, branchName: string, options?: DeleteBranchOptions): Promise<DeleteBranchResult>;
    /**
     * Create a jj workspace for a seed.
     *
     * Creates a workspace at `.foreman-worktrees/<seedId>` and sets up
     * a bookmark `foreman/<seedId>` pointing to the new workspace's revision.
     *
     * Handles existing workspaces by rebasing onto the base branch.
     */
    createWorkspace(repoPath: string, seedId: string, baseBranch?: string): Promise<WorkspaceResult>;
    /**
     * Remove a jj workspace and its associated metadata.
     */
    removeWorkspace(repoPath: string, workspacePath: string): Promise<void>;
    /**
     * List all jj workspaces for the repo.
     */
    listWorkspaces(repoPath: string): Promise<Workspace[]>;
    /**
     * No-op: jj auto-stages all changes.
     */
    stageAll(_workspacePath: string): Promise<void>;
    /**
     * Commit the current revision with a message using `jj describe -m`.
     * Creates a new empty revision on top with `jj new`.
     */
    commit(workspacePath: string, message: string): Promise<void>;
    /**
     * Push a bookmark to origin using `jj git push`.
     * Passes `--allow-new` when `options.allowNew` is true (required for new bookmarks).
     */
    push(workspacePath: string, branchName: string, options?: PushOptions): Promise<void>;
    /**
     * Pull/fetch from origin and update the bookmark.
     */
    pull(workspacePath: string, branchName: string): Promise<void>;
    /**
     * Rebase the current workspace onto a destination bookmark.
     * Uses `jj rebase -d <onto>`.
     */
    rebase(workspacePath: string, onto: string): Promise<RebaseResult>;
    /**
     * Abandon the last commit to undo a failed rebase.
     * jj doesn't have a "rebase --abort" but we can restore via `jj undo`.
     */
    abortRebase(workspacePath: string): Promise<void>;
    /**
     * Merge a source bookmark into a target bookmark.
     * In jj this creates a new commit that has both as parents via `jj new`.
     */
    merge(repoPath: string, sourceBranch: string, targetBranch?: string): Promise<MergeResult>;
    /**
     * Get the current change ID (jj's equivalent of a commit hash).
     * Returns the short (12-char) change ID for consistency with how callers
     * typically use commit/change IDs (e.g., as labels or references).
     */
    getHeadId(workspacePath: string): Promise<string>;
    /**
     * Resolve an arbitrary revision expression to its change ID.
     * Equivalent to `jj log -r <ref> -T commit_id`.
     * Throws if the ref does not exist.
     */
    resolveRef(repoPath: string, ref: string): Promise<string>;
    /**
     * Fetch updates from origin via `jj git fetch`.
     */
    fetch(repoPath: string): Promise<void>;
    /**
     * Get a diff between two revisions/bookmarks.
     */
    diff(repoPath: string, from: string, to: string): Promise<string>;
    /**
     * Get a list of file paths changed between two revisions.
     * Uses `jj diff --summary --from <from> --to <to>` and extracts filenames.
     * Returns an empty array if no files changed or revisions do not exist.
     */
    getChangedFiles(repoPath: string, from: string, to: string): Promise<string[]>;
    /**
     * Get the commit timestamp for a given ref (bookmark).
     * Returns a Unix timestamp in seconds, or null if not found.
     */
    getRefCommitTimestamp(repoPath: string, ref: string): Promise<number | null>;
    /**
     * List modified files in the current revision.
     */
    getModifiedFiles(workspacePath: string): Promise<string[]>;
    /**
     * List files with conflicts in the current revision.
     * jj marks conflict files with a `C` prefix in `jj resolve --list`.
     */
    getConflictingFiles(workspacePath: string): Promise<string[]>;
    /**
     * Get working status (jj status output).
     */
    status(workspacePath: string): Promise<string>;
    /**
     * Restore all files to their state in the parent revision and remove untracked files.
     *
     * Equivalent to `git checkout -- . && git clean -fd` — restores tracked files
     * to parent-revision state AND removes any new untracked files from the working tree.
     */
    cleanWorkingTree(workspacePath: string): Promise<void>;
    /**
     * Return pre-computed jj finalize commands for prompt rendering.
     */
    getFinalizeCommands(vars: FinalizeTemplateVars): FinalizeCommands;
}
//# sourceMappingURL=jujutsu-backend.d.ts.map