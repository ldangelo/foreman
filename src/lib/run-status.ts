/**
 * run-status.ts
 *
 * Shared types and pure functions for mapping SQLite run statuses to br seed
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

/**
 * Describes a detected mismatch between a run's terminal status in SQLite and
 * the corresponding seed's status in the br backend.
 */
export interface StateMismatch {
  seedId: string;
  runId: string;
  runStatus: string;
  actualSeedStatus: string;
  expectedSeedStatus: string;
}

// ── Status mapping ───────────────────────────────────────────────────────────

/**
 * Map a SQLite run status to the expected br seed status.
 *
 * SQLite is the source of truth for run state; br is the slave.  This mapping
 * defines the correct seed state given a run's terminal state.
 *
 * Mapping:
 *   pending / running        → in_progress
 *   completed / merged / pr-created → closed
 *   failed / stuck / conflict / test-failed → open
 *   (unknown)                → open   (safe default: makes task visible again)
 */
export function mapRunStatusToSeedStatus(runStatus: string): string {
  switch (runStatus) {
    case "pending":
    case "running":
      return "in_progress";
    case "completed":
      return "closed";
    case "failed":
    case "stuck":
      return "open";
    case "merged":
    case "pr-created":
      return "closed";
    case "conflict":
    case "test-failed":
      return "open";
    default:
      return "open";
  }
}
