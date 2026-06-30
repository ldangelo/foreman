/**
 * JujutsuBackend — Jujutsu (jj) VCS backend implementation.
 *
 * Implements the `VcsBackend` interface using the `jj` CLI.
 * Supports Jujutsu repositories in both colocated and non-colocated layouts.
 *
 * Key differences from GitBackend:
 * - Workspaces use `jj workspace add` / `jj workspace forget`.
 * - Branches are called "bookmarks" in jj (`jj bookmark`).
 * - Staging is automatic — `stageAll()` is a no-op.
 * - Commits use `jj describe -m` (no trailing `jj new`).
 * - Pushes use `jj git push --bookmark`; `allowNew` retries old `--allow-new` syntax when needed.
 * - Rebase uses `jj rebase -d <destination>`.
 *
 * @module src/lib/vcs/jujutsu-backend
 */
import type { Workspace, WorkspaceResult, MergeResult, RebaseResult, DeleteBranchOptions, DeleteBranchResult, PushOptions, FinalizeTemplateVars, FinalizeCommands } from "./types.js";
import type { VcsBackend } from "./interface.js";
/**
 * JujutsuBackend encapsulates jj-specific VCS operations for a Foreman project.
 *
 * Foreman prefers colocated jj repositories when git-native tooling is needed,
 * but repository introspection should also work for non-colocated jj repos.
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
     * Used for operations that still need git metadata when it exists.
     */
    private git;
    /**
     * Find the root of the jj repository containing `path`.
     * Uses `jj root`, which works in both colocated and non-colocated repos.
     */
    getRepoRoot(path: string): Promise<string>;
    /**
     * Find the main (primary) repository root from any workspace.
     * For jj this is the same as the workspace root regardless of repository layout.
     */
    getMainRepoRoot(path: string): Promise<string>;
    /**
     * Detect the default/trunk branch for the repository.
     *
     * Resolution order:
     * 1. Respect `git-town.main-branch` when configured.
     * 2. Respect `origin/HEAD` when available.
     * 3. Look for a `main` bookmark.
     * 4. Look for a `master` bookmark.
     * 5. Look for a `dev` bookmark.
     * 6. Fall back to the current bookmark.
     */
    detectDefaultBranch(repoPath: string): Promise<string>;
    private getBookmarksAtRevision;
    /**
     * Get the name of the currently active bookmark.
     * Uses `jj log --no-graph -r @ -T 'bookmarks'` to find the current bookmark.
     * If the working copy is an unbookmarked child revision, falls back to the
     * parent revision's bookmark before finally falling back to the short change ID.
     */
    getCurrentBranch(repoPath: string): Promise<string>;
    /**
     * Get the URL of a remote by name.
     * For jujutsu, this delegates to the underlying git repository.
     */
    getRemoteUrl(repoPath: string, remote?: string): Promise<string | null>;
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
   * Creates a workspace in Foreman's external workspace root and sets up
   * a bookmark `foreman/<seedId>` pointing to the new workspace's revision.
   * When `baseBranch` is provided, the new workspace is created directly from
   * that branch/revision instead of inheriting the controller workspace parent.
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
     *
     * Does NOT call `jj new` afterwards. The `jj new` convention is for
     * interactive workflows where the user wants a fresh working revision.
     * In Foreman's agent pipeline, each workspace commits once and pushes;
     * the extra `jj new` would create an empty revision that gets exported
     * as an empty git commit and pollutes the branch history.
     */
    commit(workspacePath: string, message: string): Promise<void>;
    /**
     * Commit with auto-generated message.
     * Jujutsu always uses auto-messages, so this uses a default message.
     */
    commitNoEdit(workspacePath: string): Promise<void>;
    /**
     * Push a bookmark to origin using `jj git push`.
     *
     * Newer jj releases automatically track/create remote bookmarks when pushing
     * with `--bookmark`, while older releases required `--allow-new`. When
     * `options.allowNew` is set, try the legacy flag first and fall back to the
     * modern syntax if the local jj binary rejects it.
     */
    push(workspacePath: string, branchName: string, options?: PushOptions): Promise<void>;
    /**
     * Pull/fetch from origin and update the bookmark.
     */
    pull(workspacePath: string, branchName: string): Promise<void>;
    saveWorktreeState(_workspacePath: string): Promise<boolean>;
    restoreWorktreeState(_workspacePath: string): Promise<void>;
    /**
     * Rebase the current workspace onto a destination bookmark.
     * Uses `jj rebase -d <onto>`.
     */
    rebase(workspacePath: string, onto: string): Promise<RebaseResult>;
    rebaseBranch(repoPath: string, branchName: string, onto: string): Promise<RebaseResult>;
    restackBranch(repoPath: string, branchName: string, _oldBase: string, newBase: string): Promise<RebaseResult>;
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
    mergeWithStrategy(repoPath: string, sourceBranch: string, targetBranch: string, strategy: "theirs"): Promise<MergeResult>;
    rollbackFailedMerge(workspacePath: string, beforeRef: string): Promise<void>;
    /**
     * Get the current change ID (jj's equivalent of a commit hash).
     * When the working copy is an unbookmarked empty child revision, prefer the
     * parent revision's change ID so callers reason about the effective branch tip
     * rather than the ephemeral scratch commit jj may create on top.
     */
    getHeadId(workspacePath: string): Promise<string>;
    /**
     * Resolve an arbitrary revision expression to its change ID.
     * Equivalent to `jj log -r <ref> -T commit_id`.
     * Throws if the ref does not exist.
     */
    resolveRef(repoPath: string, ref: string): Promise<string>;
    isAncestor(repoPath: string, ancestorRef: string, descendantRef: string): Promise<boolean>;
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
     * Merge without auto-committing.
     * Jujutsu always auto-commits merges, so this delegates to `merge()`.
     * The conflict detection behavior is the same; the difference in commit
     * behavior is a jujutsu limitation for this interface method.
     */
    mergeWithoutCommit(repoPath: string, sourceBranch: string, targetBranch: string): Promise<MergeResult>;
    /**
     * Abort an in-progress merge.
     * Jujutsu doesn't track merge state the same way as git.
     * Uses `jj op restore @-` to restore to the pre-merge working copy state.
     */
    abortMerge(workspacePath: string): Promise<void>;
    /**
     * Stage a specific file.
     * Jujutsu auto-stages all changes, so this is a no-op.
     */
    stageFile(_workspacePath: string, _filePath: string): Promise<void>;
    stageFiles(_workspacePath: string, _filePaths: string[]): Promise<void>;
    /**
     * Checkout a file from a specific ref into the working tree.
     * Uses `jj file show <ref> -- <path>` written to the working copy.
     * The special ref "--theirs" during rebase resolves to the "other" parent.
     */
    checkoutFile(workspacePath: string, ref: string, filePath: string): Promise<void>;
    /**
     * Get the content of a file at a specific ref.
     */
    showFile(repoPath: string, ref: string, filePath: string): Promise<string>;
    /**
     * Reset the working tree to a specific ref (hard reset).
     * Jujutsu equivalent: restore all files to the target revision.
     */
    resetHard(workspacePath: string, ref: string): Promise<void>;
    /**
     * Remove a tracked file from the repository.
     */
    removeFile(workspacePath: string, filePath: string): Promise<void>;
    /**
     * Continue an in-progress rebase after resolving conflicts.
     */
    rebaseContinue(workspacePath: string): Promise<void>;
    /**
     * Remove a file from the staging area.
     * Jujutsu doesn't have a separate index, so this is a no-op.
     */
    removeFromIndex(_workspacePath: string, _filePath: string): Promise<void>;
    /**
     * Apply a patch file via colocated git metadata.
     */
    applyPatchToIndex(workspacePath: string, patchFilePath: string): Promise<void>;
    /**
     * Get the merge base of two refs.
     * Uses jj's parent traversal to find the common ancestor.
     */
    getMergeBase(repoPath: string, ref1: string, ref2: string): Promise<string>;
    /**
     * List untracked files in the working tree.
     * For jj, untracked files are files that exist in the working tree but are
     * not part of the current revision's tree. We compare the working tree
     * contents against what jj knows about.
     */
    getUntrackedFiles(workspacePath: string): Promise<string[]>;
    /**
     * Return pre-computed jj finalize commands for prompt rendering.
     */
    getFinalizeCommands(vars: FinalizeTemplateVars): FinalizeCommands;
}
//# sourceMappingURL=jujutsu-backend.d.ts.map