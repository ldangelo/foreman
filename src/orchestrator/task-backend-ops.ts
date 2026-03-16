/**
 * task-backend-ops.ts
 *
 * Task lifecycle operations for the pipeline worker using the br backend.
 *
 * Provides two operations used by agent-worker.ts:
 *   - closeSeed()       — marks a task complete (finalize phase)
 *   - resetSeedToOpen() — resets a task back to open (markStuck path)
 *
 * TRD-024: sd backend removed. Always uses Beads Rust CLI at ~/.local/bin/br.
 *
 * CLI calls are made via execFileSync (no shell interpolation).
 * Errors from the CLI subprocess are caught and logged; they must not
 * propagate to callers since a failed close/reset is non-fatal for the
 * pipeline worker itself.
 */

import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { homedir } from "node:os";
import { PIPELINE_TIMEOUTS } from "../lib/config.js";

// ── Path constants ────────────────────────────────────────────────────────────

function brPath(): string {
  return join(homedir(), ".local", "bin", "br");
}

// ── Shared exec options ───────────────────────────────────────────────────────

const EXEC_OPTS = { stdio: "pipe" as const, timeout: PIPELINE_TIMEOUTS.seedClosureMs };

// ── Public API ────────────────────────────────────────────────────────────────

/**
 * Close (complete) a bead in the br backend.
 *
 * br close <seedId> --reason "Completed via pipeline"
 *
 * TRD-024: sd backend removed. Always uses br.
 * Errors are caught and logged to stderr; the function never throws.
 */
export function closeSeed(seedId: string): void {
  const bin = brPath();
  const args = ["close", seedId, "--reason", "Completed via pipeline"];

  try {
    execFileSync(bin, args, EXEC_OPTS);
    console.error(`[task-backend-ops] Closed seed ${seedId} via br`);
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
 *
 * TRD-024: sd backend removed. Always uses br.
 * Errors are caught and logged to stderr; the function never throws.
 */
export function resetSeedToOpen(seedId: string): void {
  const bin = brPath();
  const args = ["update", seedId, "--status", "open"];

  try {
    execFileSync(bin, args, EXEC_OPTS);
    console.error(`[task-backend-ops] Reset seed ${seedId} to open via br`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: br update failed for ${seedId}: ${msg.slice(0, 200)}`);
  }
}
