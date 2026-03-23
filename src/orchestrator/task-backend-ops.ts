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

import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { homedir } from "node:os";
import { PIPELINE_TIMEOUTS } from "../lib/config.js";
import type { ForemanStore } from "../lib/store.js";
import type { ITaskClient } from "../lib/task-client.js";
import { mapRunStatusToSeedStatus } from "../lib/run-status.js";
import type { StateMismatch } from "../lib/run-status.js";

// ── Path constants ────────────────────────────────────────────────────────────

function brPath(): string {
  return join(homedir(), ".local", "bin", "br");
}

// ── Shared exec options ───────────────────────────────────────────────────────

function execOpts(projectPath?: string): { stdio: "pipe"; timeout: number; cwd?: string } {
  return {
    stdio: "pipe" as const,
    timeout: PIPELINE_TIMEOUTS.beadClosureMs,
    ...(projectPath ? { cwd: projectPath } : {}),
  };
}

// ── Public API ────────────────────────────────────────────────────────────────

/**
 * Close (complete) a bead in the br backend.
 *
 * br close <seedId> --reason "Completed via pipeline"
 * br sync --flush-only  (persists the change to .beads/beads.jsonl)
 *
 * TRD-024: sd backend removed. Always uses br.
 * Errors are caught and logged to stderr; the function never throws.
 * The flush step is non-fatal: if it fails the close is still in br's memory
 * and may be recovered by syncBeadStatusOnStartup on the next restart.
 *
 * @param projectPath - The project root directory that contains .beads/.
 *   Must be provided so br auto-discovers the correct database when called
 *   from a worktree that has no .beads/ of its own.
 */
export async function closeSeed(seedId: string, projectPath?: string): Promise<void> {
  const bin = brPath();
  const args = ["close", seedId, "--reason", "Completed via pipeline"];

  try {
    execFileSync(bin, args, execOpts(projectPath));
    console.error(`[task-backend-ops] Closed seed ${seedId} via br`);

    // Flush changes to .beads/beads.jsonl so the close survives a process restart.
    // Uses execFileSync (not execBr) to avoid the auto-appended --json flag.
    try {
      execFileSync(bin, ["sync", "--flush-only"], execOpts(projectPath));
      console.error(`[task-backend-ops] Flushed JSONL for seed ${seedId}`);
    } catch (flushErr: unknown) {
      const msg = flushErr instanceof Error ? flushErr.message : String(flushErr);
      console.error(`[task-backend-ops] Warning: br sync --flush-only failed for ${seedId}: ${msg.slice(0, 200)}`);
    }
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: br close failed for ${seedId}: ${msg.slice(0, 200)}`);
  }
}

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
export async function resetSeedToOpen(seedId: string, projectPath?: string): Promise<void> {
  const bin = brPath();
  const args = ["update", seedId, "--status", "open"];

  try {
    execFileSync(bin, args, execOpts(projectPath));
    console.error(`[task-backend-ops] Reset seed ${seedId} to open via br`);

    // Flush changes to .beads/beads.jsonl so the reset survives a process restart.
    // Uses execFileSync (not execBr) to avoid the auto-appended --json flag.
    try {
      execFileSync(bin, ["sync", "--flush-only"], execOpts(projectPath));
      console.error(`[task-backend-ops] Flushed JSONL for reset seed ${seedId}`);
    } catch (flushErr: unknown) {
      const msg = flushErr instanceof Error ? flushErr.message : String(flushErr);
      console.error(`[task-backend-ops] Warning: br sync --flush-only failed for ${seedId}: ${msg.slice(0, 200)}`);
    }
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: br update failed for ${seedId}: ${msg.slice(0, 200)}`);
  }
}

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
export function addNotesToBead(seedId: string, notes: string, projectPath?: string): void {
  if (!notes) return;
  const bin = brPath();
  // Truncate to avoid excessive note lengths in the br backend
  const truncated = notes.length > 2000 ? notes.slice(0, 2000) + "…" : notes;
  const args = ["update", seedId, "--notes", truncated];

  try {
    execFileSync(bin, args, execOpts(projectPath));
    console.error(`[task-backend-ops] Added notes to seed ${seedId} via br`);

    // Flush changes to .beads/beads.jsonl so the note survives a process restart.
    try {
      execFileSync(bin, ["sync", "--flush-only"], execOpts(projectPath));
      console.error(`[task-backend-ops] Flushed JSONL for notes on seed ${seedId}`);
    } catch (flushErr: unknown) {
      const msg = flushErr instanceof Error ? flushErr.message : String(flushErr);
      console.error(`[task-backend-ops] Warning: br sync --flush-only failed for ${seedId}: ${msg.slice(0, 200)}`);
    }
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: br update --notes failed for ${seedId}: ${msg.slice(0, 200)}`);
  }
}

/**
 * Mark a bead as permanently failed in the br backend.
 * Called by markStuck() for permanent (non-transient) failures so the task
 * does NOT reappear in the ready queue but is visible as failed.
 *
 * br update <seedId> --status failed
 * br sync --flush-only  (persists the change to .beads/beads.jsonl)
 *
 * TRD-024: sd backend removed. Always uses br.
 * Errors are caught and logged to stderr; the function never throws.
 *
 * @param projectPath - The project root directory that contains .beads/.
 *   Must be provided so br auto-discovers the correct database when called
 *   from a worktree that has no .beads/ of its own.
 */
export async function markBeadFailed(seedId: string, projectPath?: string): Promise<void> {
  const bin = brPath();
  const args = ["update", seedId, "--status", "failed"];

  try {
    execFileSync(bin, args, execOpts(projectPath));
    console.error(`[task-backend-ops] Marked seed ${seedId} as failed via br`);

    // Flush changes to .beads/beads.jsonl so the status survives a process restart.
    try {
      execFileSync(bin, ["sync", "--flush-only"], execOpts(projectPath));
      console.error(`[task-backend-ops] Flushed JSONL for failed seed ${seedId}`);
    } catch (flushErr: unknown) {
      const msg = flushErr instanceof Error ? flushErr.message : String(flushErr);
      console.error(`[task-backend-ops] Warning: br sync --flush-only failed for ${seedId}: ${msg.slice(0, 200)}`);
    }
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: br update --status failed failed for ${seedId}: ${msg.slice(0, 200)}`);
  }
}

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
export function addLabelsToBead(seedId: string, labels: string[], projectPath?: string): void {
  if (labels.length === 0) return;
  const bin = brPath();
  // Use --add-label (not --set-labels) to preserve existing labels like workflow:smoke.
  const args = ["update", seedId, ...labels.flatMap((l) => ["--add-label", l])];

  try {
    execFileSync(bin, args, execOpts(projectPath));
    console.error(`[task-backend-ops] Added labels [${labels.join(", ")}] to seed ${seedId} via br`);

    // Flush changes to .beads/beads.jsonl so the label update survives a process restart.
    // Uses execFileSync (not execBr) to avoid the auto-appended --json flag.
    try {
      execFileSync(bin, ["sync", "--flush-only"], execOpts(projectPath));
      console.error(`[task-backend-ops] Flushed JSONL for label update on seed ${seedId}`);
    } catch (flushErr: unknown) {
      const msg = flushErr instanceof Error ? flushErr.message : String(flushErr);
      console.error(`[task-backend-ops] Warning: br sync --flush-only failed for ${seedId}: ${msg.slice(0, 200)}`);
    }
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: br update --labels failed for ${seedId}: ${msg.slice(0, 200)}`);
  }
}

// ── Startup Sync ────────────────────────────────────────────────────────────

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
export async function syncBeadStatusOnStartup(
  store: Pick<ForemanStore, "getRunsByStatuses">,
  taskClient: Pick<ITaskClient, "show">,
  projectId: string,
  opts?: { dryRun?: boolean; projectPath?: string },
): Promise<SyncResult> {
  const dryRun = opts?.dryRun ?? false;
  const projectPath = opts?.projectPath;

  // All terminal statuses — broader than detectAndFixMismatches which excludes failed/stuck
  const terminalStatuses: Array<"completed" | "merged" | "pr-created" | "conflict" | "test-failed" | "failed" | "stuck"> = [
    "completed",
    "merged",
    "pr-created",
    "conflict",
    "test-failed",
    "failed",
    "stuck",
  ];

  const terminalRuns = store.getRunsByStatuses(terminalStatuses, projectId);

  // Deduplicate by seed_id: keep the most recently created run per seed
  type RunLike = { id: string; seed_id: string; status: string; created_at: string };
  const latestBySeed = new Map<string, RunLike>();
  for (const run of terminalRuns) {
    const existing = latestBySeed.get(run.seed_id);
    if (!existing || run.created_at > existing.created_at) {
      latestBySeed.set(run.seed_id, run);
    }
  }

  const mismatches: StateMismatch[] = [];
  const errors: string[] = [];
  let synced = 0;

  for (const run of latestBySeed.values()) {
    const expectedSeedStatus = mapRunStatusToSeedStatus(run.status);
    try {
      const seedDetail = await taskClient.show(run.seed_id);

      if (seedDetail.status !== expectedSeedStatus) {
        mismatches.push({
          seedId: run.seed_id,
          runId: run.id,
          runStatus: run.status,
          actualSeedStatus: seedDetail.status,
          expectedSeedStatus,
        });

        if (!dryRun) {
          try {
            // Use execFileSync directly (not taskClient.update / execBr) so the br
            // dirty flag is set. execBr auto-appends --json which bypasses the dirty
            // flag, causing the subsequent sync --flush-only to be a silent no-op.
            execFileSync(brPath(), ["update", run.seed_id, "--status", expectedSeedStatus], execOpts(projectPath));
            synced++;
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            errors.push(`Failed to sync seed ${run.seed_id}: ${msg}`);
          }
        }
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      if (!msg.includes("not found") && !msg.includes("Issue not found")) {
        errors.push(`Could not check seed ${run.seed_id}: ${msg}`);
      }
      // Seed not found — skip silently (may have been deleted from br)
    }
  }

  // Flush .beads/beads.jsonl to persist all updates.
  // Uses execFileSync (not execBr) to avoid the auto-appended --json flag
  // which bypasses br's dirty-flag mechanism and causes silent no-ops.
  if (!dryRun && synced > 0) {
    try {
      execFileSync(brPath(), ["sync", "--flush-only"], execOpts(projectPath));
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      errors.push(`br sync --flush-only failed: ${msg}`);
    }
  }

  return { synced, mismatches, errors };
}
