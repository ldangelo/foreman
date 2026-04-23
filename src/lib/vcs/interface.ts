/**
 * VcsBackend interface definition.
 *
 * Separated from index.ts to avoid circular dependencies between the interface
 * and its implementations (GitBackend, JujutsuBackend).
 *
 * @module src/lib/vcs/interface
 */

import type {
  Workspace,
  WorkspaceResult,
  MergeResult,
  RebaseResult,
  DeleteBranchOptions,
  DeleteBranchResult,
  PushOptions,
  FinalizeTemplateVars,
  FinalizeCommands,
} from "./types.js";

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

  // ── Repository Introspection ─────────────────────────────────────────

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
   * Get the URL of a remote by name (default: "origin").
   * Returns null if the remote does not exist.
   */
  getRemoteUrl(repoPath: string, remote?: string): Promise<string | null>;

  // ── Branch / Bookmark Operations ────────────────────────────────────

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
  deleteBranch(
    repoPath: string,
    branchName: string,
    options?: DeleteBranchOptions,
  ): Promise<DeleteBranchResult>;

  // ── Workspace / Worktree Operations ─────────────────────────────────

  /**
   * Create a new workspace (git worktree / jj workspace) for a seed.
   *
   * Branch name: `foreman/<seedId>`
   * Location: Foreman's workspace root for the repo (default: external to the repo at
   * `<repoParent>/.foreman-worktrees/<repoName>/<seedId>`)
   */
  createWorkspace(
    repoPath: string,
    seedId: string,
    baseBranch?: string,
  ): Promise<WorkspaceResult>;

  /**
   * Remove a workspace and clean up associated metadata.
   */
  removeWorkspace(repoPath: string, workspacePath: string): Promise<void>;

  /**
   * List all workspaces for the repository.
   */
  listWorkspaces(repoPath: string): Promise<Workspace[]>;

  // ── Staging and Commit Operations ───────────────────────────────────

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

  // ── Rebase and Merge Operations ──────────────────────────────────────

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
  merge(
    repoPath: string,
    sourceBranch: string,
    targetBranch?: string,
  ): Promise<MergeResult>;

  // ── Diff, Status and Conflict Detection ─────────────────────────────

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
   * Get the Unix timestamp (seconds since epoch) of the most recent commit on a ref.
   * For git: equivalent to `git log -1 --format=%ct <ref>`.
   * For jujutsu: returns the commit timestamp for the given revision.
   * Returns null if the ref does not exist or the timestamp cannot be determined.
   */
  getRefCommitTimestamp(repoPath: string, ref: string): Promise<number | null>;

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

  // ── Conflict Resolution Operations ───────────────────────────────────

  /**
   * Merge a source branch into the target without auto-committing.
   * Used by ConflictResolver for Tier 1 merge attempts where we need to
   * detect conflicts before committing.
   *
   * Returns `MergeResult` with success flag and any conflicting files.
   */
  mergeWithoutCommit(
    repoPath: string,
    sourceBranch: string,
    targetBranch: string,
  ): Promise<MergeResult>;

  /**
   * Commit the current staged changes with a custom message.
   * Used after `mergeWithoutCommit()` to complete a merge with a descriptive message.
   */
  commit(workspacePath: string, message: string): Promise<void>;

  /**
   * Commit the current staged changes using the auto-generated merge message.
   * Used after `mergeWithoutCommit()` to complete a merge without editing the message.
   * For jujutsu this falls back to `commit()` with an auto-generated message.
   */
  commitNoEdit(workspacePath: string): Promise<void>;

  /**
   * Abort an in-progress merge, returning to pre-merge state.
   * For git: `git merge --abort`. For jujutsu: `jj op restore` to pre-merge state.
   */
  abortMerge(repoPath: string): Promise<void>;

  /**
   * Stage a specific file (git add <path>).
   * For jujutsu this is a no-op (auto-staged).
   */
  stageFile(workspacePath: string, filePath: string): Promise<void>;

  /**
   * Checkout a file from a specific ref into the working tree.
   * For git: `git checkout <ref> -- <path>`.
   * For jujutsu: `jj file show <ref> -- <path>` written to working tree.
   * The special ref "--theirs" during a rebase means "the version from the
   * branch being rebased onto" — resolved by the backend based on context.
   */
  checkoutFile(workspacePath: string, ref: string, filePath: string): Promise<void>;

  /**
   * Get the content of a file at a specific ref (revision).
   * For git: `git show <ref>:<path>`.
   * For jujutsu: `jj file show <ref> -- <path>`.
   */
  showFile(repoPath: string, ref: string, filePath: string): Promise<string>;

  /**
   * Reset the working tree to a specific ref (hard reset).
   * For git: `git reset --hard <ref>`.
   * For jujutsu: `jj restore --to <ref>` (restores all files to that revision).
   */
  resetHard(workspacePath: string, ref: string): Promise<void>;

  /**
   * Remove a tracked file from the repository.
   * For git: `git rm -f <path>`.
   * For jujutsu: removes the file from the current change.
   */
  removeFile(workspacePath: string, filePath: string): Promise<void>;

  /**
   * Continue an in-progress rebase after resolving conflicts.
   * For git: `git rebase --continue`.
   * For jujutsu: `jj rebase --continue` or similar.
   */
  rebaseContinue(workspacePath: string): Promise<void>;

  /**
   * Remove a file from the staging area (index) without modifying the working tree.
   * For git: `git rm --cached <path>` (unstage a new file).
   * For jujutsu: not applicable (no separate index).
   */
  removeFromIndex(workspacePath: string, filePath: string): Promise<void>;

  /**
   * Get the merge base (common ancestor) of two refs.
   * For git: `git merge-base <ref1> <ref2>`.
   * For jujutsu: `jj log -r <ref1> + <ref2> -T 'parent'`.
   * Returns empty string if merge base cannot be determined.
   */
  getMergeBase(repoPath: string, ref1: string, ref2: string): Promise<string>;

  /**
   * List untracked files in the working tree.
   * For git: `git ls-files --others --exclude-standard`.
   * For jujutsu: uses jj's conflict/working-copy state inspection.
   * Returns an array of file paths relative to the workspace root.
   */
  getUntrackedFiles(workspacePath: string): Promise<string[]>;

  /**
   * Return true when `ancestorRef` is contained in the history of `descendantRef`.
   * Used by finalize runtime enforcement to verify target drift was actually integrated.
   */
  isAncestor(repoPath: string, ancestorRef: string, descendantRef: string): Promise<boolean>;

  // ── Finalize Support ─────────────────────────────────────────────────

  /**
   * Return pre-computed finalize commands for prompt rendering.
   * The Finalize agent embeds these verbatim in shell commands.
   */
  getFinalizeCommands(vars: FinalizeTemplateVars): FinalizeCommands;
}
