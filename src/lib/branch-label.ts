/**
 * branch-label.ts — Utilities for managing branch: labels on beads.
 *
 * Foreman uses `branch:<name>` labels on beads to track which git branch
 * the work should merge into. This enables the git-town workflow:
 *
 *   git town hack installer && foreman run
 *
 * All dispatched beads get `branch:installer` added automatically, and the
 * refinery merges them into `installer` rather than the default main/dev branch.
 */

// ── Label extraction ─────────────────────────────────────────────────────────

/**
 * Extract the branch name from a `branch:<name>` label in the list.
 * Returns the branch name, or undefined if no such label exists.
 *
 * If multiple branch: labels exist (shouldn't happen), returns the first one.
 */
export function isValidBranchLabel(branch: string | undefined): branch is string {
  if (!branch) return false;
  const trimmed = branch.trim();
  if (!trimmed) return false;
  // Detached HEAD is not a real merge target and should never be persisted
  // as a branch: label or used by refinery as a target branch.
  if (trimmed === "HEAD") return false;
  return true;
}

export function extractBranchLabel(labels: string[] | undefined): string | undefined {
  if (!labels || labels.length === 0) return undefined;
  const label = labels.find((l) => l.startsWith("branch:"));
  if (!label) return undefined;
  const branch = label.slice("branch:".length).trim();
  return isValidBranchLabel(branch) ? branch : undefined;
}

/**
 * Check whether the given branch is a "default" branch (main, master, dev).
 * When on a default branch, beads are NOT labeled — this preserves backward
 * compatibility with existing projects that always merge to main/dev.
 *
 * Returns true if the branch should NOT be labeled (i.e. it is the default).
 */
export function isDefaultBranch(branch: string, defaultBranch: string): boolean {
  // Exact match with the configured default
  if (branch === defaultBranch) return true;
  // Also treat well-known integration branches as defaults
  const knownDefaults = new Set(["main", "master", "dev", "develop", "trunk"]);
  return knownDefaults.has(branch);
}

/**
 * Return the updated labels array for a bead after applying the branch label.
 *
 * - Removes any existing `branch:*` labels (to avoid duplicates).
 * - Appends `branch:<branchName>`.
 */
export function applyBranchLabel(
  existingLabels: string[] | undefined,
  branchName: string,
): string[] {
  const filtered = (existingLabels ?? []).filter((l) => !l.startsWith("branch:"));
  if (!isValidBranchLabel(branchName)) return filtered;
  // br enforces a 50-character limit per label. Skip the label entirely if it
  // would exceed the limit — a truncated branch name would cause the refinery
  // to target a non-existent branch. The explicit targetBranch threading in
  // dispatch/auto-merge handles merge targeting for long branch names.
  const label = `branch:${branchName}`;
  if (label.length > 50) return filtered;
  return [...filtered, label];
}
