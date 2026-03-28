import type { ForemanStore } from "../lib/store.js";
import type { BeadGraph } from "../lib/beads.js";
import type { UpdateOptions } from "../lib/task-client.js";
import type { MergeReport, PrReport } from "./types.js";
import type { VcsBackend } from "../lib/vcs/index.js";
/**
 * Minimal interface for the task-tracking client used by Refinery.
 *
 * This covers the two methods Refinery calls:
 *   - show(id): fetch issue detail for PR title/body generation
 *   - getGraph(): optional; used to order merges by dependency graph
 *
 * BeadsRustClient satisfies this interface.
 * BeadsRustClient does not implement getGraph(); the try/catch in
 * orderByDependencies will fall back to insertion order in that case.
 */
export interface IRefineryTaskClient {
    show(id: string): Promise<{
        title?: string;
        description?: string | null;
        status: string;
        labels?: string[];
    }>;
    getGraph?(): Promise<BeadGraph>;
    update?(id: string, opts: UpdateOptions): Promise<void>;
}
export declare class Refinery {
    private store;
    private seeds;
    private projectPath;
    private conflictResolver;
    private vcsBackend;
    constructor(store: ForemanStore, seeds: IRefineryTaskClient, projectPath: string, vcsBackend?: VcsBackend);
    /**
     * Scan the committed diff between branchName and targetBranch for conflict markers.
     * Only looks at committed content (git diff), never at uncommitted working-tree files.
     * Uncommitted conflict markers (e.g. from a failed agent rebase) are intentionally ignored —
     * they don't exist in the branch that will be merged.
     * Returns a list of files containing markers (relative to repo root), or an empty array if clean.
     */
    private scanForConflictMarkers;
    /**
     * Check if a file path is a report/non-code file that can be auto-resolved.
     * Delegates to ConflictResolver.isReportFile().
     */
    private isReportFile;
    /**
     * During a rebase conflict, check if all conflicts are report files.
     * If so, auto-resolve them and continue rebase (looping until done).
     * If real code conflicts exist, abort rebase and return false.
     * Returns true if rebase completed successfully.
     * Delegates to ConflictResolver.autoResolveRebaseConflicts().
     */
    private autoResolveRebaseConflicts;
    /**
     * Detect uncommitted changes in `.seeds/` and `.foreman/` and commit them
     * so that merge operations start from a clean state for state files.
     * No-op when there are no dirty state files.
     */
    private autoCommitStateFiles;
    /**
     * Remove report files from the working tree before merging so they can't
     * conflict. Commits the removal if any tracked files were removed.
     * Delegates to ConflictResolver.removeReportFiles().
     */
    private removeReportFiles;
    /**
     * Archive report files after a successful merge.
     * Moves report files from the working tree into .foreman/reports/<name>-<seedId>.md
     * and creates a follow-up commit. Called after vcsBackend.merge() succeeds so we
     * don't need to checkout branches or deal with dirty working trees.
     * Delegates to ConflictResolver.archiveReportsPostMerge().
     */
    private archiveReportsPostMerge;
    /**
     * Fire-and-forget helper to send a mail message via the store.
     * Never throws — failures are silently ignored (mail is optional infrastructure).
     */
    private sendMail;
    /**
     * Attempt to add a note to a bead explaining what went wrong.
     * Non-fatal — a failure to annotate the bead must not mask the original error.
     */
    private addFailureNote;
    /**
     * After a successful merge of `mergedBranch` into `targetBranch`, find all
     * stacked branches (seeds whose worktree was branched from `mergedBranch`)
     * and rebase them onto `targetBranch` so they pick up the latest code.
     *
     * Non-fatal: failures are logged as warnings; they do not abort the merge.
     */
    private rebaseStackedBranches;
    /**
     * Push a conflicting branch and create a PR for manual resolution.
     * Returns the CreatedPr info, or null if PR creation fails.
     */
    private createPrForConflict;
    /**
     * Get all completed runs that are ready to merge, optionally filtered to a single seed.
     *
     * When a seedId filter is active (i.e. `foreman merge --seed <id>`), we also
     * include runs in terminal failure states ("test-failed", "conflict", "failed")
     * so that a previously-failed merge can be retried without the user having to
     * manually reset the run's status back to "completed".
     *
     * Without a seedId filter we only return "completed" runs to avoid accidentally
     * re-attempting bulk merges of runs that failed for unrelated reasons.
     */
    getCompletedRuns(projectId?: string, seedId?: string): import("../lib/store.js").Run[];
    /**
     * Order runs by seed dependency graph so that dependencies merge before dependents.
     * Falls back to insertion order if dependency info is unavailable.
     */
    orderByDependencies(runs: import("../lib/store.js").Run[]): Promise<import("../lib/store.js").Run[]>;
    /**
     * Find all completed (unmerged) runs and attempt to merge them into the target branch.
     * Optionally run tests after each merge. Merges in dependency order.
     *
     * Report files (QA_REPORT.md, REVIEW.md, TASK.md, AGENTS.md, etc.) are removed
     * before each merge to prevent conflicts, then archived to .foreman/reports/ after.
     * Only real code conflicts are reported as failures.
     */
    mergeCompleted(opts?: {
        targetBranch?: string;
        runTests?: boolean;
        testCommand?: string;
        projectId?: string;
        seedId?: string;
    }): Promise<MergeReport>;
    /**
     * Resolve a conflicting run.
     * - 'theirs': re-attempt merge with -X theirs strategy
     * - 'abort': abandon the merge, mark run as failed
     */
    resolveConflict(runId: string, strategy: "theirs" | "abort", opts?: {
        targetBranch?: string;
        runTests?: boolean;
        testCommand?: string;
    }): Promise<boolean>;
    /**
     * Find all completed runs and create PRs for their branches.
     * Pushes branches to origin and uses `gh pr create`.
     *
     * MQ-T058d Investigation: Why `gh pr create` instead of `git town propose`
     * -------------------------------------------------------------------------
     * git town propose (v22.6.0) was investigated for PR creation. Findings:
     *   1. It DOES support --title and --body flags.
     *   2. However, it opens a browser window (`open https://github.com/...`)
     *      rather than creating the PR via the GitHub API.
     *   3. No PR URL is returned in stdout -- only a GitHub compare URL is
     *      opened in the system browser.
     *   4. It also runs `git fetch`, `git stash`, and `git push` as side-effects,
     *      which conflicts with our explicit push step above.
     *
     * Since Foreman agents run non-interactively (see CLAUDE.md critical
     * constraints: "agents hang on interactive prompts"), and we need the PR URL
     * returned for event logging, `gh pr create` remains the correct choice for
     * both normal-flow and conflict PRs.
     *
     * Conflict PRs (ConflictResolver.handleFallback) also use `gh pr create`
     * because they require structured titles with "[Conflict]" prefix and
     * detailed resolution metadata in the body.
     */
    createPRs(opts?: {
        baseBranch?: string;
        draft?: boolean;
        projectId?: string;
    }): Promise<PrReport>;
}
export interface DryRunEntry {
    seedId: string;
    branchName: string;
    diffStat: string;
    hasConflicts: boolean;
    estimatedTier?: number;
    error?: string;
}
/**
 * Preview what merging branches into the target would look like.
 * Reads `git diff --stat` and detects conflicts via `git merge-tree`.
 * No git state is modified.
 *
 * @param projectPath   Repository root
 * @param targetBranch  Branch to merge into (e.g. "main")
 * @param branches      List of branches to check
 * @param filterSeedId  If set, only process this seed
 * @param conflictPatterns  Optional map of file -> resolution tier for estimated tier column
 */
export declare function dryRunMerge(projectPath: string, targetBranch: string, branches: Array<{
    branchName: string;
    seedId: string;
}>, filterSeedId?: string, conflictPatterns?: Map<string, number>): Promise<DryRunEntry[]>;
export interface BeadPreservationResult {
    preserved: boolean;
    error?: string;
}
/**
 * Preserve `.seeds/` changes from a branch before it is deleted.
 * Extracts `.seeds/` changes via `git diff`, writes a temp patch file,
 * applies it to the current index, and commits with a descriptive message.
 *
 * Error code MQ-019 on patch failure.
 *
 * @param projectPath   Repository root
 * @param branchName    Source branch containing seed changes
 * @param targetBranch  Target branch to apply changes to
 */
export declare function preserveBeadChanges(projectPath: string, branchName: string, targetBranch: string): Promise<BeadPreservationResult>;
//# sourceMappingURL=refinery.d.ts.map