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
/**
 * Extract the branch name from a `branch:<name>` label in the list.
 * Returns the branch name, or undefined if no such label exists.
 *
 * If multiple branch: labels exist (shouldn't happen), returns the first one.
 */
export declare function extractBranchLabel(labels: string[] | undefined): string | undefined;
/**
 * Check whether the given branch is a "default" branch (main, master, dev).
 * When on a default branch, beads are NOT labeled — this preserves backward
 * compatibility with existing projects that always merge to main/dev.
 *
 * Returns true if the branch should NOT be labeled (i.e. it is the default).
 */
export declare function isDefaultBranch(branch: string, defaultBranch: string): boolean;
/**
 * Return the updated labels array for a bead after applying the branch label.
 *
 * - Removes any existing `branch:*` labels (to avoid duplicates).
 * - Appends `branch:<branchName>`.
 */
export declare function applyBranchLabel(existingLabels: string[] | undefined, branchName: string): string[];
//# sourceMappingURL=branch-label.d.ts.map