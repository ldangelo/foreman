/**
 * task-backend-ops.ts
 *
 * Backend-aware task lifecycle operations for the pipeline worker.
 *
 * Provides two operations used by agent-worker.ts:
 *   - closeSeed()       — marks a task complete (finalize phase)
 *   - resetSeedToOpen() — resets a task back to open (markStuck path)
 *
 * The active backend is determined by FOREMAN_TASK_BACKEND:
 *   'sd'  — Seeds CLI at ~/.bun/bin/sd  (default)
 *   'br'  — Beads Rust CLI at ~/.local/bin/br
 *
 * CLI calls are made via execFileSync (no shell interpolation).
 * Errors from the CLI subprocess are caught and logged; they must not
 * propagate to callers since a failed close/reset is non-fatal for the
 * pipeline worker itself.
 */

import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { homedir } from "node:os";
import { getTaskBackend } from "../lib/feature-flags.js";
import { PIPELINE_TIMEOUTS } from "../lib/config.js";

// ── Path constants ────────────────────────────────────────────────────────────

function home(): string {
  return homedir();
}

function sdPath(): string {
  return join(home(), ".bun", "bin", "sd");
}

function brPath(): string {
  return join(home(), ".local", "bin", "br");
}

// ── Shared exec options ───────────────────────────────────────────────────────

const EXEC_OPTS = { stdio: "pipe" as const, timeout: PIPELINE_TIMEOUTS.seedClosureMs };

// ── Public API ────────────────────────────────────────────────────────────────

/**
 * Close (complete) a seed/bead in the active task backend.
 *
 * sd:  sd close <seedId> --reason "Completed via pipeline"
 * br:  br close <seedId> --reason "Completed via pipeline"
 *
 * Errors are caught and logged to stderr; the function never throws.
 */
export function closeSeed(seedId: string): void {
  const backend = getTaskBackend();
  const [bin, args] = backend === "br"
    ? [brPath(), ["close", seedId, "--reason", "Completed via pipeline"]]
    : [sdPath(), ["close", seedId, "--reason", "Completed via pipeline"]];

  try {
    execFileSync(bin, args, EXEC_OPTS);
    console.error(`[task-backend-ops] Closed seed ${seedId} via ${backend}`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: ${backend} close failed for ${seedId}: ${msg.slice(0, 200)}`);
  }
}

/**
 * Reset a seed/bead back to open status in the active task backend.
 * Called by markStuck() so the task reappears in the ready queue for retry.
 *
 * sd:  sd update <seedId> --status open
 * br:  br update <seedId> --status open
 *
 * Errors are caught and logged to stderr; the function never throws.
 */
export function resetSeedToOpen(seedId: string): void {
  const backend = getTaskBackend();
  const [bin, args] = backend === "br"
    ? [brPath(), ["update", seedId, "--status", "open"]]
    : [sdPath(), ["update", seedId, "--status", "open"]];

  try {
    execFileSync(bin, args, EXEC_OPTS);
    console.error(`[task-backend-ops] Reset seed ${seedId} to open via ${backend}`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[task-backend-ops] Warning: ${backend} update failed for ${seedId}: ${msg.slice(0, 200)}`);
  }
}
