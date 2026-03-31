import { basename, dirname, isAbsolute, join, normalize, relative } from "node:path";

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
export function getWorkspaceRoot(repoPath: string): string {
  const repoName = basename(normalize(repoPath));
  const override = process.env.FOREMAN_WORKTREE_ROOT?.trim();
  if (override) {
    const base = isAbsolute(override)
      ? override
      : join(dirname(normalize(repoPath)), override);
    return join(base, repoName);
  }

  return join(dirname(normalize(repoPath)), ".foreman-worktrees", repoName);
}

/** Return the full workspace path for a specific seed. */
export function getWorkspacePath(repoPath: string, seedId: string): string {
  return join(getWorkspaceRoot(repoPath), seedId);
}

/**
 * Infer the project root from a workspace path.
 *
 * Supports both layouts:
 *   legacy:   <repo>/.foreman-worktrees/<seedId>
 *   external: <repo-parent>/.foreman-worktrees/<repo-name>/<seedId>
 */
export function inferProjectPathFromWorkspacePath(workspacePath: string): string {
  const normalized = normalize(workspacePath);
  const workspaceParent = dirname(normalized);
  const maybeWorkspaceRoot = dirname(workspaceParent);

  if (basename(maybeWorkspaceRoot) === ".foreman-worktrees") {
    return join(dirname(maybeWorkspaceRoot), basename(workspaceParent));
  }

  return join(normalized, "..", "..");
}

/**
 * Return the beads JSONL path as it should be referenced from a workspace.
 *
 * - Nested legacy workspaces need a relative path back to the main repo copy.
 * - External workspaces should use their local checkout path `.beads/issues.jsonl`.
 */
export function getBeadsIssuesPathForWorkspace(
  workspacePath: string,
  mainRepoRoot: string,
): string {
  const relWorkspace = relative(mainRepoRoot, workspacePath);
  const isNestedWorkspace = relWorkspace !== "" && !relWorkspace.startsWith("..");

  if (isNestedWorkspace) {
    return relative(workspacePath, join(mainRepoRoot, ".beads", "issues.jsonl"));
  }

  return ".beads/issues.jsonl";
}

/**
 * Build a best-effort restore command that removes tracked Beads state churn
 * from the current workspace before finalize commits.
 */
export function buildTrackedStateRestoreCommand(
  workspacePath: string,
  mainRepoRoot: string,
): string {
  const beadsPath = getBeadsIssuesPathForWorkspace(workspacePath, mainRepoRoot);
  return `git restore --source=HEAD --staged --worktree -- ${beadsPath} 2>/dev/null || git restore --source=HEAD --worktree -- ${beadsPath} 2>/dev/null || true`;
}
