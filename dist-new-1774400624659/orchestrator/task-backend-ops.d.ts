/**
 * task-backend-ops.ts
 *
 * Task lifecycle operations for the pipeline worker using the br backend.
 *
 * Provides operations used by agent-worker.ts and the run command:
 *   - closeSeed()               — marks a task complete (finalize phase)
 *   - resetSeedToOpen()         — resets a task back to open (markStuck path)
 *   - addLabelsToBead()         — appends phase-tracking labels after each pipeline phase
 *   - syncBeadStatusOnStartup() — reconciles br seed status from SQLite on startup
 *
 * TRD-024: sd backend removed. Always uses Beads Rust CLI at ~/.local/bin/br.
 *
 * CLI calls are made via execFileSync (no shell interpolation) for all
 * subprocess operations to avoid auto-appending --json (which execBr does)
 * and to ensure the br dirty flag is set correctly on each call.
 * Errors from the CLI subprocess are caught and logged; they must not
 * propagate to callers since a failed close/reset is non-fatal for the
 * pipeline worker itself.
 */
import type { ForemanStore } from "../lib/store.js";
import type { ITaskClient } from "../lib/task-client.js";
import type { StateMismatch } from "../lib/run-status.js";
/**
 * Enqueue a "close seed" operation for deferred sequential execution by the dispatcher.
 *
 * @param store - ForemanStore for the project (shared SQLite DB).
 * @param seedId - The bead/seed ID to close.
 * @param sender - Human-readable source label (e.g. "refinery", "agent-worker").
 */
export declare function enqueueCloseSeed(store: ForemanStore, seedId: string, sender: string): void;
/**
 * Enqueue a "reset seed to open" operation for deferred sequential execution by the dispatcher.
 *
 * @param store - ForemanStore for the project (shared SQLite DB).
 * @param seedId - The bead/seed ID to reset.
 * @param sender - Human-readable source label.
 */
export declare function enqueueResetSeedToOpen(store: ForemanStore, seedId: string, sender: string): void;
/**
 * Enqueue a "mark bead failed" operation for deferred sequential execution by the dispatcher.
 *
 * @param store - ForemanStore for the project (shared SQLite DB).
 * @param seedId - The bead/seed ID to mark as failed.
 * @param sender - Human-readable source label.
 */
export declare function enqueueMarkBeadFailed(store: ForemanStore, seedId: string, sender: string): void;
/**
 * Enqueue an "add notes to bead" operation for deferred sequential execution by the dispatcher.
 * Does nothing when notes is empty (consistent with addNotesToBead).
 *
 * @param store - ForemanStore for the project (shared SQLite DB).
 * @param seedId - The bead/seed ID.
 * @param notes - Note text to add.
 * @param sender - Human-readable source label.
 */
export declare function enqueueAddNotesToBead(store: ForemanStore, seedId: string, notes: string, sender: string): void;
/**
 * Enqueue an "add labels to bead" operation for deferred sequential execution by the dispatcher.
 * Does nothing when labels array is empty (consistent with addLabelsToBead).
 *
 * @param store - ForemanStore for the project (shared SQLite DB).
 * @param seedId - The bead/seed ID.
 * @param labels - Array of label strings to add.
 * @param sender - Human-readable source label.
 */
export declare function enqueueAddLabelsToBead(store: ForemanStore, seedId: string, labels: string[], sender: string): void;
/**
 * Close (complete) a bead in the br backend.
 *
 * Uses "br update --status closed" instead of "br close" because
 * br close --force doesn't persist to JSONL export (beads_rust#204).
 *
 * @param projectPath - The project root directory that contains .beads/.
 */
export declare function closeSeed(seedId: string, projectPath?: string): Promise<void>;
/**
 * Reset a bead back to open status in the br backend.
 * Called by markStuck() so the task reappears in the ready queue for retry.
 *
 * br update <seedId> --status open
 * br sync --flush-only  (persists the change to .beads/beads.jsonl)
 *
 * TRD-024: sd backend removed. Always uses br.
 * Errors are caught and logged to stderr; the function never throws.
 * The flush step is non-fatal: if it fails the update is still in br's memory
 * and may be recovered by syncBeadStatusOnStartup on the next restart.
 *
 * @param projectPath - The project root directory that contains .beads/.
 *   Must be provided so br auto-discovers the correct database when called
 *   from a worktree that has no .beads/ of its own.
 */
export declare function resetSeedToOpen(seedId: string, projectPath?: string): Promise<void>;
/**
 * Mark a bead as failed in the br backend.
 *
 * br update <seedId> --status failed
 *
 * Errors are caught and logged to stderr; the function never throws.
 */
export declare function markBeadFailed(seedId: string, projectPath?: string): Promise<void>;
/**
 * Add a note/comment to a bead in the br backend.
 * Used by markStuck() to explain why a bead was reset to open.
 *
 * br update <seedId> --notes "<notes>"
 *
 * Errors are caught and logged to stderr; the function never throws.
 * Does nothing when notes is empty.
 *
 * @param seedId - The bead/seed ID
 * @param notes - The note/comment text to add
 * @param projectPath - The project root directory that contains .beads/.
 */
export declare function addNotesToBead(seedId: string, notes: string, projectPath?: string): void;
/**
 * Add labels to a bead in the br backend.
 * Called after each pipeline phase completes to track phase progress.
 *
 * br update <seedId> --labels <label1>,<label2>,...
 * br sync --flush-only  (persists the change to .beads/beads.jsonl)
 *
 * Errors are caught and logged to stderr; the function never throws.
 * The flush step is non-fatal: if it fails the label update is still in br's
 * memory and may be recovered by syncBeadStatusOnStartup on the next restart.
 *
 * @param projectPath - The project root directory that contains .beads/.
 *   Must be provided so br auto-discovers the correct database when called
 *   from a worktree that has no .beads/ of its own.
 */
export declare function addLabelsToBead(seedId: string, labels: string[], projectPath?: string): void;
export interface SyncResult {
    /** Number of seeds whose status was successfully updated in br. */
    synced: number;
    /** All mismatches detected (includes both fixed and unfixed in dryRun mode). */
    mismatches: StateMismatch[];
    /** Non-fatal errors encountered during the sync (per-seed failures). */
    errors: string[];
}
/**
 * Sync bead status from SQLite to br on foreman startup.
 *
 * Queries all terminal runs from SQLite and reconciles the expected seed
 * status (derived from run status) with the actual status stored in br.
 * This corrects "drift" that can occur when foreman was interrupted before
 * a br update completed.
 *
 * Covers all terminal run statuses:
 *   merged, pr-created           → closed
 *   completed                    → in_progress (waiting for merge queue)
 *   failed, stuck, conflict, test-failed → open
 *
 * Non-fatal: individual seed errors are collected and returned; startup
 * is not aborted. After all updates, calls `br sync --flush-only` to
 * persist changes to .beads/beads.jsonl.
 *
 * @param store       - SQLite store to query runs from.
 * @param taskClient  - br client providing show() method for status queries.
 * @param projectId   - Project ID to scope the run query.
 * @param opts.dryRun       - Detect mismatches but do not fix them.
 * @param opts.projectPath  - Project root for br cwd (required so br finds .beads/).
 */
export declare function syncBeadStatusOnStartup(store: Pick<ForemanStore, "getRunsByStatuses">, taskClient: Pick<ITaskClient, "show">, projectId: string, opts?: {
    dryRun?: boolean;
    projectPath?: string;
}): Promise<SyncResult>;
//# sourceMappingURL=task-backend-ops.d.ts.map