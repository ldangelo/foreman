/**
 * Shared VCS types for backend-agnostic workspace and operation representations.
 * These types serve as the data contract for all VCS backend implementations
 * (GitBackend, JujutsuBackend) and their consumers throughout Foreman.
 *
 * @module src/lib/vcs/types
 */

/** Replaces Worktree from git.ts. Backend-agnostic workspace representation. */
export interface Workspace {
  /** Absolute filesystem path to the workspace/worktree directory. */
  path: string;
  /** git branch name or jj bookmark name */
  branch: string;
  /** git commit hash or jj change ID */
  head: string;
  /** Always false for jj workspaces; may be true for git bare worktrees. */
  bare: boolean;
}

/** Result of a createWorkspace() operation. */
export interface WorkspaceResult {
  /** Absolute path to the created workspace directory. */
  workspacePath: string;
  /** Branch/bookmark name created for this workspace; format: 'foreman/<seedId>' for both backends. */
  branchName: string;
}

/** Result of a merge operation. */
export interface MergeResult {
  /** True if the merge completed without conflicts. */
  success: boolean;
  /** List of files with conflicts, if any. Omitted when merge succeeds cleanly. */
  conflicts?: string[];
}

/** Result of a rebase operation. */
export interface RebaseResult {
  /** True if the rebase completed successfully. */
  success: boolean;
  /** True if the rebase encountered conflicts that require resolution. */
  hasConflicts: boolean;
  /** List of files with conflicts. Present only when hasConflicts is true. */
  conflictingFiles?: string[];
}

/** Options for delete branch/bookmark operations. */
export interface DeleteBranchOptions {
  /** If true, force-delete even if not fully merged (equivalent to git branch -D). */
  force?: boolean;
  /**
   * The target/base branch to check merge status against.
   * Defaults to the repository's default branch if omitted.
   */
  targetBranch?: string;
}

/** Result of a delete branch/bookmark operation. */
export interface DeleteBranchResult {
  /** True if the branch/bookmark was successfully deleted. */
  deleted: boolean;
  /** True if the branch had been fully merged into the target before deletion. */
  wasFullyMerged: boolean;
}

/** Options for push operations. */
export interface PushOptions {
  /** If true, force-push (overwrite remote history). Use with caution. */
  force?: boolean;
  /**
   * Jujutsu-specific: passes --allow-new flag to allow pushing new bookmarks.
   * GitBackend ignores this field.
   */
  allowNew?: boolean;
}

/** Template variables for backend-specific finalize command generation. */
export interface FinalizeTemplateVars {
  /** The seed/bead ID for this task (e.g. 'bd-deoi'). */
  seedId: string;
  /** Human-readable title of the seed/task. */
  seedTitle: string;
  /** The base branch to rebase onto (e.g. 'dev' or 'main'). */
  baseBranch: string;
  /** Absolute path to the worktree/workspace directory. */
  worktreePath: string;
}

/**
 * Backend-specific finalize commands for prompt rendering.
 * The Finalize agent uses these pre-computed commands in its prompt so it
 * doesn't need to know which VCS backend is in use. All fields are required;
 * use an empty string for commands that are no-ops on a given backend.
 */
export interface FinalizeCommands {
  /** Command to stage all changes (e.g. 'git add -A'). Empty string for backends with auto-staging (jj). */
  stageCommand: string;
  /** Command to commit staged changes with an appropriate message. */
  commitCommand: string;
  /** Command to push the branch/bookmark to the remote. */
  pushCommand: string;
  /** Command to integrate the latest target-branch changes into the bead branch for finalize validation. */
  integrateTargetCommand: string;
  /** Command to verify the branch/bookmark exists on the remote after push. */
  branchVerifyCommand: string;
  /** Command to clean up the workspace after finalization. */
  cleanCommand: string;
  /** Command to restore tracked shared-state files that must never be committed from a workspace. */
  restoreTrackedStateCommand: string;
}

/** VCS configuration read from Foreman's global config YAML (~/.foreman/config.yaml). */
export interface VcsConfig {
  /** Which VCS backend to use. 'auto' detects based on repository contents. */
  backend: 'git' | 'jujutsu' | 'auto';
  /** Git-specific configuration options. */
  git?: {
    /** If true, use git-town for branch management operations. Default: true. */
    useTown?: boolean;
  };
  /** Jujutsu-specific configuration options. */
  jujutsu?: {
    /** Minimum jj version required; validated by 'foreman doctor'. */
    minVersion?: string;
  };
}
