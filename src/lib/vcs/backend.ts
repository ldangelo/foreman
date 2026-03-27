/**
 * VcsBackend interface — the core abstraction for all VCS operations.
 *
 * This file exists in its own module to avoid circular imports: both
 * git-backend.ts and index.ts import from here, but neither imports the other.
 *
 * @module src/lib/vcs/backend
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
} from './types.js';

/**
 * Backend-agnostic interface for all VCS operations in Foreman.
 *
 * Implementations:
 *   - GitBackend    — wraps git CLI calls (mirrors src/lib/git.ts)
 *   - JujutsuBackend — wraps jj CLI calls
 *
 * All methods that interact with the file system or shell are async.
 * Expected failures (conflicts, missing branches) are encoded in structured
 * return types (MergeResult, RebaseResult). Unexpected errors throw exceptions.
 */
export interface VcsBackend {
  // ── Repository Introspection ──────────────────────────────────────────

  /**
   * Find the root of the VCS repository containing `path`.
   *
   * For git: runs `git rev-parse --show-toplevel`.
   * For jj: runs `jj workspace root`.
   * Returns the absolute path to the repository root.
   */
  getRepoRoot(path: string): Promise<string>;

  /**
   * Find the main (primary) repository root, even when called from a linked
   * worktree or a jj workspace.
   *
   * For git: resolves the common `.git` directory to strip the worktree suffix.
   * For jj: same as getRepoRoot (jj workspaces share a single repo root).
   */
  getMainRepoRoot(path: string): Promise<string>;

  /**
   * Detect the default development branch / bookmark for a repository.
   *
   * For git: checks (in order) git-town.main-branch config, origin/HEAD,
   *          local 'main', local 'master', and falls back to current branch.
   * For jj: returns the main trunk bookmark (typically 'main' or 'master').
   */
  detectDefaultBranch(repoPath: string): Promise<string>;

  /**
   * Get the name of the currently checked-out branch or bookmark.
   *
   * For git: `git rev-parse --abbrev-ref HEAD`.
   * For jj: `jj bookmark list --revisions @`.
   */
  getCurrentBranch(repoPath: string): Promise<string>;

  // ── Branch / Bookmark Operations ─────────────────────────────────────

  /**
   * Checkout an existing branch or create it if it does not exist locally.
   *
   * For git: `git checkout <branchName>` or `git checkout -b <branchName>`.
   * For jj: `jj bookmark set <branchName>` or `jj new -m <branchName>`.
   */
  checkoutBranch(repoPath: string, branchName: string): Promise<void>;

  /**
   * Check whether a local branch / bookmark exists.
   *
   * Returns true if the branch exists locally in the repository.
   */
  branchExists(repoPath: string, branchName: string): Promise<boolean>;

  /**
   * Check whether a branch / bookmark exists on the remote.
   *
   * For git: uses `git ls-remote --heads origin <branchName>`.
   * For jj: uses `jj bookmark list --all` and inspects remote tracking entries.
   */
  branchExistsOnRemote(repoPath: string, branchName: string): Promise<boolean>;

  /**
   * Delete a local branch / bookmark.
   *
   * Options:
   *   - force: delete even if not fully merged (git -D / jj bookmark delete --allow-non-empty)
   *   - targetBranch: the branch to check merge status against; defaults to the default branch
   *
   * Returns whether deletion occurred and whether the branch was fully merged.
   */
  deleteBranch(
    repoPath: string,
    branchName: string,
    opts?: DeleteBranchOptions,
  ): Promise<DeleteBranchResult>;

  // ── Workspace Management ──────────────────────────────────────────────

  /**
   * Create an isolated workspace (git worktree or jj workspace) for a task.
   *
   * The workspace is created on a new branch named `foreman/<seedId>`,
   * branching from `baseBranch` (or the default branch if omitted).
   *
   * If the worktree/workspace already exists it is rebased onto `baseBranch`.
   *
   * @param repoPath   - absolute path to the main repository root
   * @param seedId     - unique identifier for the task (used as the branch suffix)
   * @param baseBranch - the branch to branch from (defaults to default branch)
   * @param setupSteps - optional list of setup commands to run after creation
   * @param setupCache - optional cache descriptor for reproducible setup caching
   */
  createWorkspace(
    repoPath: string,
    seedId: string,
    baseBranch?: string,
    setupSteps?: string[],
    setupCache?: string,
  ): Promise<WorkspaceResult>;

  /**
   * Remove an existing workspace (git worktree prune or jj workspace forget).
   *
   * @param repoPath      - absolute path to the main repository root
   * @param workspacePath - absolute path to the workspace directory to remove
   */
  removeWorkspace(repoPath: string, workspacePath: string): Promise<void>;

  /**
   * List all workspaces associated with the repository.
   *
   * For git: returns all linked worktrees (git worktree list --porcelain).
   * For jj: returns all workspace entries (jj workspace list).
   */
  listWorkspaces(repoPath: string): Promise<Workspace[]>;

  // ── Commit & Sync ─────────────────────────────────────────────────────

  /**
   * Stage all changes in the workspace.
   *
   * For git: `git add -A`.
   * For jj: no-op (jj tracks changes automatically).
   */
  stageAll(workspacePath: string): Promise<void>;

  /**
   * Commit staged changes with the given message.
   *
   * Returns the new commit hash (git) or change ID (jj).
   */
  commit(workspacePath: string, message: string): Promise<string>;

  /**
   * Get the current HEAD commit hash or jj change ID for the workspace.
   */
  getHeadId(workspacePath: string): Promise<string>;

  /**
   * Push the current branch / bookmark to the remote.
   *
   * @param opts.force    - force-push (overwrite remote history)
   * @param opts.allowNew - jj-specific: pass --allow-new for new bookmarks
   */
  push(
    workspacePath: string,
    branchName: string,
    opts?: PushOptions,
  ): Promise<void>;

  /**
   * Pull (fetch + merge) the latest changes for the given branch.
   */
  pull(workspacePath: string, branchName: string): Promise<void>;

  /**
   * Fetch all refs from the remote without merging.
   */
  fetch(workspacePath: string): Promise<void>;

  /**
   * Rebase the current workspace branch onto `onto`.
   *
   * For git: `git rebase origin/<onto>` (after fetching).
   * For jj: `jj rebase -d <onto>`.
   *
   * Returns a structured result; does NOT throw on conflict — the caller
   * must check `result.hasConflicts` and call abortRebase() if needed.
   */
  rebase(workspacePath: string, onto: string): Promise<RebaseResult>;

  /**
   * Abort an in-progress rebase and restore the workspace to its pre-rebase state.
   *
   * For git: `git rebase --abort`.
   * For jj: abandons the conflicting commits.
   */
  abortRebase(workspacePath: string): Promise<void>;

  // ── Merge Operations ──────────────────────────────────────────────────

  /**
   * Merge a branch into `targetBranch` (or the default branch if omitted).
   *
   * Implements the stash-checkout-merge-restore pattern to handle dirty
   * working trees in git. For jj, uses `jj merge`.
   *
   * Returns a structured result with the list of conflicting files on failure.
   * Does NOT throw on conflict — the caller must check `result.success`.
   *
   * @param repoPath     - main repo root (not a worktree path)
   * @param branchName   - the source branch to merge in
   * @param targetBranch - the branch to merge into (defaults to default branch)
   */
  merge(
    repoPath: string,
    branchName: string,
    targetBranch?: string,
  ): Promise<MergeResult>;

  // ── Diff, Conflict & Status ───────────────────────────────────────────

  /**
   * Return the list of files in conflict during an active rebase or merge.
   *
   * For git: parses `git diff --name-only --diff-filter=U`.
   * For jj: parses `jj resolve --list`.
   */
  getConflictingFiles(workspacePath: string): Promise<string[]>;

  /**
   * Return the diff output between two refs.
   *
   * @param from - base ref (commit SHA, branch name, jj change ID)
   * @param to   - target ref; defaults to the working copy if omitted
   */
  diff(repoPath: string, from: string, to: string): Promise<string>;

  /**
   * Return the list of files modified relative to `base`.
   *
   * For git: `git diff --name-only <base>`.
   * For jj: `jj diff --summary -r <base>`.
   */
  getModifiedFiles(workspacePath: string, base: string): Promise<string[]>;

  /**
   * Discard all uncommitted changes and restore the workspace to HEAD.
   *
   * For git: `git checkout -- . && git clean -fd`.
   * For jj: `jj restore`.
   */
  cleanWorkingTree(workspacePath: string): Promise<void>;

  /**
   * Return a human-readable status summary of the workspace.
   *
   * For git: `git status --short`.
   * For jj: `jj status`.
   */
  status(workspacePath: string): Promise<string>;

  // ── Finalize Command Generation ───────────────────────────────────────

  /**
   * Generate the backend-specific shell commands for the Finalize phase.
   *
   * The returned commands are injected into the finalize prompt template so
   * the Finalize agent can execute them without knowing which VCS is in use.
   * All 6 fields are required; use an empty string for no-op commands.
   *
   * @param vars - template variables (seedId, seedTitle, baseBranch, worktreePath)
   */
  getFinalizeCommands(vars: FinalizeTemplateVars): FinalizeCommands;
}
