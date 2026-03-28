import { Command } from "commander";
import { ForemanStore } from "../../lib/store.js";
import type { Run } from "../../lib/store.js";
import type { UpdateOptions } from "../../lib/task-client.js";
import type { StateMismatch } from "../../lib/run-status.js";
export { mapRunStatusToSeedStatus } from "../../lib/run-status.js";
export type { StateMismatch } from "../../lib/run-status.js";
/**
 * Minimal interface capturing the subset of task-client methods used by
 * detectAndFixMismatches. BeadsRustClient satisfies this interface
 * (note: show() is not on ITaskClient, hence this local type).
 */
export interface IShowUpdateClient {
    show(id: string): Promise<{
        status: string;
    }>;
    update(id: string, opts: UpdateOptions): Promise<void>;
}
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
export declare function detectAndFixMismatches(store: Pick<ForemanStore, "getRunsByStatus" | "getActiveRuns">, seeds: IShowUpdateClient, projectId: string, resetSeedIds: ReadonlySet<string>, opts?: {
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
export declare function detectStuckRuns(store: Pick<ForemanStore, "getActiveRuns" | "updateRun" | "logEvent">, projectId: string, opts?: {
    stuckTimeoutMinutes?: number;
    dryRun?: boolean;
}): Promise<StuckDetectionResult>;
export interface ResetSeedResult {
    /** "reset" — seed was updated to open */
    action: "reset" | "skipped-closed" | "already-open" | "not-found" | "error";
    seedId: string;
    previousStatus?: string;
    error?: string;
}
/**
 * Reset a single seed back to "open" status.
 *
 * - ALL non-open seeds are re-opened, including "closed" ones — this ensures
 *   that `foreman reset` always makes a seed retryable regardless of its
 *   previous state.
 * - If the seed is already "open", the update is skipped (idempotent).
 * - If the seed is not found, returns "not-found" without throwing.
 * - In dry-run mode, the `show()` check still runs (read-only) but `update()`
 *   is skipped — the returned `action` accurately reflects what would happen.
 *
 * Note: The `force` parameter is retained for API compatibility but no longer
 * changes behaviour (closed seeds are always reopened).
 */
export declare function resetSeedToOpen(seedId: string, seeds: IShowUpdateClient, opts?: {
    dryRun?: boolean;
    force?: boolean;
}): Promise<ResetSeedResult>;
export declare const resetCommand: Command;
//# sourceMappingURL=reset.d.ts.map