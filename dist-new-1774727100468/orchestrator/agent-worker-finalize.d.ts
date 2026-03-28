/**
 * Finalize helper for agent-worker.
 *
 * Extracted as a separate module so it can be unit-tested independently
 * of the agent-worker process lifecycle (which calls main() on import).
 *
 * Responsibilities:
 *  1. Type-check the worktree (tsc --noEmit, non-fatal)
 *  2. Commit all changes with the seed title/ID as the commit message
 *  3. Push the branch to origin
 *  4. Enqueue branch for merge (seed will be closed by refinery after merge)
 *
 * Returns a FinalizeResult: { success, retryable }.
 */
import type { VcsBackend } from "../lib/vcs/index.js";
export interface FinalizeConfig {
    /** Run ID (used when enqueuing to the merge queue). */
    runId: string;
    /** Seed identifier, e.g. "bd-ytzv". */
    seedId: string;
    /** Human-readable seed title — used as the git commit message. */
    seedTitle: string;
    /** Absolute path to the git worktree directory. */
    worktreePath: string;
    /**
     * Absolute path to the project root (contains .beads/).
     * Used as cwd for br commands. Defaults to worktreePath/../..
     * when not provided.
     */
    projectPath?: string;
}
/**
 * Result returned by finalize().
 *
 * - `success`: true when the git push succeeded (seed was closed / enqueued).
 * - `retryable`: when success=false, indicates whether the caller should reset
 *   the seed to "open" for re-dispatch.  Set to false for deterministic failures
 *   (e.g. diverged history that could not be rebased) to prevent an infinite
 *   re-dispatch loop (see bd-zwtr).
 */
export interface FinalizeResult {
    success: boolean;
    retryable: boolean;
}
/**
 * Rotate an existing report file so previous reports are preserved for
 * debugging.  Non-fatal — any rename error is silently swallowed.
 */
export declare function rotateReport(worktreePath: string, filename: string): void;
/**
 * Run VCS finalization: stage, commit, push, and enqueue for merge.
 *
 * Uses VcsBackend for all VCS operations — no direct execFileSync git calls.
 *
 * @returns `{ success: true, retryable: true }` when the push succeeded;
 *          `{ success: false, retryable: true }` for transient push failures;
 *          `{ success: false, retryable: false }` for deterministic failures
 *          (e.g. diverged history that could not be rebased via pull --rebase).
 */
export declare function finalize(config: FinalizeConfig, logFile: string, vcs: VcsBackend): Promise<FinalizeResult>;
//# sourceMappingURL=agent-worker-finalize.d.ts.map