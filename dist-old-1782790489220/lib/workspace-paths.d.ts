/**
 * Resolve the directory that stores Foreman workspaces for a repository.
 *
 * Default layout keeps workspaces outside the repository root to avoid parent
 * repo state writes (for example .beads/issues.jsonl) dirtying active agent
 * workspaces:
 *   <repo-parent>/.foreman-worktrees/<repo-name>/<seedId>
 *
 * FOREMAN_WORKTREE_ROOT may override the parent directory used to hold all
 * project workspaces. When set, Foreman appends the repo basename so multiple
 * projects do not collide under the same root.
 */
export declare function getWorkspaceRoot(repoPath: string): string;
/** Return the full workspace path for a specific seed. */
export declare function getWorkspacePath(repoPath: string, seedId: string): string;
/**
 * Infer the project root from a workspace path.
 *
 * Supports both layouts:
 *   legacy:   <repo>/.foreman-worktrees/<seedId>
 *   external: <repo-parent>/.foreman-worktrees/<repo-name>/<seedId>
 */
export declare function inferProjectPathFromWorkspacePath(workspacePath: string): string;
/**
 * Return the beads JSONL path as it should be referenced from a workspace.
 *
 * - Nested legacy workspaces need a relative path back to the main repo copy.
 * - External workspaces should use their local checkout path `.beads/issues.jsonl`.
 */
export declare function getBeadsIssuesPathForWorkspace(workspacePath: string, mainRepoRoot: string): string;
/**
 * Build a best-effort restore command that removes workspace-only state and
 * diagnostic artifacts before finalize commits. The `node_modules` pattern is
 * deliberately listed without a trailing slash because setup-cache uses a
 * symlink, and Git's `node_modules/` ignore pattern does not ignore symlinks.
 */
export declare function buildTrackedStateRestoreCommand(workspacePath: string, mainRepoRoot: string): string;
//# sourceMappingURL=workspace-paths.d.ts.map