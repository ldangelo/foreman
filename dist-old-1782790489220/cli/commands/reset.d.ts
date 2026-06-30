import { Command } from "commander";
import type { Run } from "../../lib/store.js";
import type { ITaskClient } from "../../lib/task-client.js";
import type { StateMismatch } from "../../lib/run-status.js";
export { mapRunStatusToSeedStatus } from "../../lib/run-status.js";
export type { StateMismatch } from "../../lib/run-status.js";
/**
 * Minimal interface capturing the subset of task-client methods used by
 * detectAndFixMismatches.
 */
export type IShowUpdateClient = Pick<ITaskClient, "show" | "update"> & {
    resetToReady?: ITaskClient["resetToReady"];
};
interface ResetRunStore {
    getRunsByStatus(status: Run["status"], projectId: string): Promise<Run[]>;
    getActiveRuns(projectId: string): Promise<Run[]>;
    getRunsForSeed(seedId: string, projectId: string): Promise<Run[]>;
    updateRun(runId: string, updates: Partial<Pick<Run, "status" | "completed_at">>): Promise<void>;
    logEvent(projectId: string, eventType: "stuck", data: Record<string, unknown>, runId?: string): Promise<void>;
}
interface ResetMergeQueue {
    list(): Promise<Array<{
        id: number;
        seed_id: string;
        status: string;
    }>>;
    remove(id: number): Promise<void>;
    missingFromQueue(): Promise<Array<{
        run_id: string;
        seed_id: string;
    }>>;
}
/** Minimal VCS surface used by the orphan-worktree sweep. */
export interface OrphanSweepVcs {
    removeWorkspace(repoPath: string, workspacePath: string): Promise<void>;
    deleteBranch(repoPath: string, branchName: string, options?: {
        force?: boolean;
    }): Promise<{
        deleted: boolean;
    }>;
}
export interface OrphanSweepResult {
    worktreesRemoved: number;
    branchesDeleted: number;
}
/**
 * Remove orphaned worktree directories under the project's workspace root.
 *
 * A directory is an orphan when it does NOT belong to a truly active run
 * (status `pending` or `running`). "failed" and "stuck" are terminal states —
 * their agents have stopped, so their worktrees are safe to remove.
 *
 * IMPORTANT: the active keep-set is read from the SAME store the rest of the
 * reset flow uses (the async {@link ResetRunStore} — Postgres-backed for
 * registered projects). Reading the local synchronous store here would make
 * live Postgres-backed active runs invisible to the keep-set and cause their
 * worktrees to be destroyed as "orphans".
 */
export declare function cleanOrphanWorktrees(store: Pick<ResetRunStore, "getRunsByStatus">, vcs: OrphanSweepVcs, projectPath: string, worktreesDir: string, projectId: string, opts?: {
    readdir?: (dir: string) => string[];
    logger?: (msg: string) => void;
}): Promise<OrphanSweepResult>;
/**
 * Signature for an injected async execFile function.
 * Matches node:child_process.promisify(execFile) but can be swapped in tests.
 */
export type ExecFileAsyncFn = (cmd: string, args: string[], options?: {
    cwd?: string;
}) => Promise<{
    stdout: string;
    stderr: string;
}>;
export interface PullRequestCleanupResult {
    action: "closed" | "none" | "dry-run";
    prUrl?: string;
    reason?: string;
}
export declare function closeForemanPullRequest(projectPath: string, branchName: string, opts?: {
    dryRun?: boolean;
    execFileAsync?: ExecFileAsyncFn;
}): Promise<PullRequestCleanupResult>;
/**
 * Result of stale-branch analysis for a single completed run.
 *
 * - "close"  — branch is merged into target; bead should be closed.
 * - "reset"  — branch not merged; bead should be reset to open for retry.
 * - "skip"   — skipped (active MQ entry, active run, or already in reset set).
 * - "error"  — an error occurred; see `error` field.
 */
export interface StaleBranchResult {
    seedId: string;
    runId: string;
    branchName: string;
    action: "close" | "reset" | "skip" | "error";
    reason: string;
    error?: string;
}
/** Aggregate output from `detectAndHandleStaleBranches()`. */
export interface StaleBranchDetectionOutput {
    results: StaleBranchResult[];
    closed: number;
    reset: number;
    errors: string[];
}
/**
 * Count commits in `branchName` that are NOT in `targetBranch`.
 * Returns 0 if the branch doesn't exist or on any error.
 */
export declare function countCommitsAhead(projectPath: string, targetBranch: string, branchName: string, execFn?: ExecFileAsyncFn): Promise<number>;
/**
 * Check whether `branchName` is an ancestor of `targetBranch`
 * (i.e., all of the branch's commits are reachable from the target).
 * Returns false on any error.
 */
export declare function isBranchMergedIntoTarget(projectPath: string, targetBranch: string, branchName: string, execFn?: ExecFileAsyncFn): Promise<boolean>;
/**
 * Detect and handle completed runs whose branches are stale or already merged.
 *
 * For each "completed" run (bead in "review" status):
 * - If an active MQ entry (pending/merging) exists → skip (merge is in progress).
 * - If the branch is merged into the target branch → action "close" (work landed).
 * - If the branch is NOT merged (has commits ahead or is simply stale) → action
 *   "reset" (work needs to be re-tried).
 *
 * Seeds in `skipSeedIds` (already being reset by the main loop) are skipped.
 * Seeds with active (pending/running) dispatched runs are also skipped.
 *
 * When `dryRun` is false:
 * - "close" → update bead to "closed", mark run as "reset"
 * - "reset" → update bead to "open",   mark run as "reset"
 * In both cases the MQ entry for the seed is removed so the run is not
 * re-processed by the refinery.
 */
export declare function detectAndHandleStaleBranches(store: Pick<ResetRunStore, "getRunsByStatus" | "getActiveRuns" | "updateRun">, seeds: IShowUpdateClient, mergeQueue: ResetMergeQueue, projectPath: string, projectId: string, skipSeedIds: ReadonlySet<string>, opts?: {
    dryRun?: boolean;
    execFileAsync?: ExecFileAsyncFn;
}): Promise<StaleBranchDetectionOutput>;
export interface MismatchResult {
    mismatches: StateMismatch[];
    fixed: number;
    errors: string[];
}
/**
 * Detect and fix seed/run state mismatches.
 *
 * Checks all terminal runs (completed, merged, etc.) for seeds that are still
 * stuck in "in_progress". Seeds that are already included in the `resetSeedIds`
 * set are skipped — those will be handled by the main reset loop.
 *
 * Seeds with active (pending/running) runs are skipped to avoid the race
 * condition where auto-dispatch has just marked a seed as in_progress but the
 * reset sees the old terminal run and incorrectly overwrites the status.
 *
 * For each mismatch found, the seed status is updated to the expected value
 * (unless dryRun is true).
 */
export declare function detectAndFixMismatches(store: Pick<ResetRunStore, "getRunsByStatus" | "getActiveRuns">, seeds: IShowUpdateClient, projectId: string, resetSeedIds: ReadonlySet<string>, opts?: {
    dryRun?: boolean;
}): Promise<MismatchResult>;
export interface StuckDetectionResult {
    /** Runs newly identified as stuck during detection. */
    stuck: Run[];
    /** Any errors that occurred during detection (non-fatal). */
    errors: string[];
}
/**
 * Detect stuck active runs by:
 *  1. Timeout check — if elapsed time > stuckTimeoutMinutes, the run is stuck.
 *
 * Updates the store for each newly-detected stuck run and returns the list.
 * Runs that are already in "stuck" status are not re-detected here (they will
 * be picked up by the main reset loop).
 */
export declare function detectStuckRuns(store: Pick<ResetRunStore, "getActiveRuns" | "updateRun" | "logEvent">, projectId: string, opts?: {
    stuckTimeoutMinutes?: number;
    dryRun?: boolean;
}): Promise<StuckDetectionResult>;
export interface ResetSeedResult {
    /** "reset" — seed was updated to open */
    action: "reset" | "skipped-closed" | "already-open" | "not-found" | "error";
    seedId: string;
    previousStatus?: string;
    targetStatus?: string;
    error?: string;
}
export declare function resetSeedToOpen(seedId: string, seeds: IShowUpdateClient, opts?: {
    dryRun?: boolean;
    force?: boolean;
}): Promise<ResetSeedResult>;
export declare const resetCommand: Command;
export declare function getWorkerPid(run: Run): number | null;
//# sourceMappingURL=reset.d.ts.map