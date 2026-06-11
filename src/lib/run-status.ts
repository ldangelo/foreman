/**
 * run-status.ts
 *
 * Shared types and pure functions for mapping Postgres run statuses to br seed
 * statuses (and detecting mismatches between the two systems).
 *
 * This module is placed in src/lib/ so that it can be consumed by both:
 *   - src/cli/commands/reset.ts   (CLI layer)
 *   - src/orchestrator/task-backend-ops.ts  (orchestrator layer)
 *
 * Keeping it here avoids the layer inversion that would occur if the
 * orchestrator imported directly from the CLI commands layer.
 */

// ── Types ────────────────────────────────────────────────────────────────────

import type { RunStatus } from "../orchestrator/read-models.js";
import type { NativeTaskStatus } from "../orchestrator/types.js";

/**
 * Describes a detected mismatch between a run's terminal status in Postgres and
 * the corresponding seed's status in the br backend.
 */
export interface StateMismatch {
  seedId: string;
  runId: string;
  runStatus: RunStatus;
  actualSeedStatus: string;
  expectedSeedStatus: string;
}

// ── Status mapping ───────────────────────────────────────────────────────────

/**
 * Map a Postgres run status to the expected br seed status.
 *
 * Postgres is the source of truth for run state; br is the slave.  This mapping
 * defines the correct seed state given a run's terminal state.
 *
 * Mapping:
 *   pending / running              → in_progress
 *   completed                      → review  (awaiting merge queue)
 *   merged / pr-created            → closed
 *   conflict / test-failed         → blocked (merge failed, needs intervention)
 *   failed                         → failed  (unexpected merge exception)
 *   stuck                          → open    (agent pipeline stuck, safe to retry)
 *   reset                          → open    (safe default: makes task visible again)
 */
export function mapRunStatusToSeedStatus(runStatus: RunStatus): string {
  switch (runStatus) {
    // Active pipeline: agent is still running
    case "pending":
    case "running":
      return "in_progress";
    // Awaiting merge: pipeline finished, branch pushed, waiting in the merge queue
    // (refinery.ts closes the bead only after the branch successfully lands on main).
    // Using 'review' so the bead is visually distinct from actively-running tasks.
    case "completed":
      return "review";
    // Agent pipeline stuck — safe to retry, put back in open queue
    case "stuck":
      return "open";
    // Successfully merged/PR-created — bead is done
    case "merged":
    case "pr-created":
      return "closed";
    // Merge failures — blocked, needs human intervention or retry
    case "conflict":
    case "test-failed":
      return "blocked";
    // Unexpected exception during merge — mark as failed
    case "failed":
      return "failed";
    // Reset — put back in open queue for retry
    case "reset":
      return "open";
  }
}

/**
 * Map a Postgres run status to the expected native task status.
 *
 * Similar to mapRunStatusToSeedStatus but returns NativeTaskStatus values
 * (with hyphen, e.g. "in-progress") suitable for native task store updates.
 *
 * Mapping:
 *   pending / running              → in-progress
 *   completed                      → review
 *   merged / pr-created            → closed
 *   conflict / test-failed         → blocked
 *   failed                         → failed
 *   stuck                          → ready (agent pipeline stuck, safe to retry)
 *   reset                          → ready  (safe default: makes task visible again)
 *
 * NOTE: "open" is NOT a valid NativeTaskStatus — it exists only in the legacy br
 * seed backend. For native tasks, "ready" is the correct status for tasks that
 * should be picked up for retry.
 */
export function mapRunStatusToNativeTaskStatus(runStatus: RunStatus): NativeTaskStatus {
  switch (runStatus) {
    case "pending":
    case "running":
      return "in-progress";
    case "completed":
      return "review";
    case "stuck":
      return "ready";
    case "merged":
    case "pr-created":
      return "closed";
    case "conflict":
    case "test-failed":
      return "blocked";
    case "failed":
      return "failed";
    case "reset":
      return "ready";
  }
}