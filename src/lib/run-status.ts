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
 *   pending / running              → in_progress
 *   completed                      → review  (awaiting merge queue)
 *   merged / pr-created            → closed
 *   conflict / test-failed         → blocked (merge failed, needs intervention)
 *   failed                         → failed  (unexpected merge exception)
 *   stuck                          → open    (agent pipeline stuck, safe to retry)
 *   (unknown)                      → open    (safe default: makes task visible again)
 */
export function mapRunStatusToSeedStatus(runStatus: string): string {
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
    default:
      return "open";
  }
}

/**
 * Map a SQLite run status to the native Foreman task status.
 *
 * Native tasks use a slightly different vocabulary than br seeds:
 * - active work remains `in-progress`
 * - a successfully finished pipeline becomes `review` until merge queue lands it
 * - merge success closes the task
 * - merge conflicts/test failures become `blocked`
 * - unexpected merge exceptions become `failed`
 * - stuck runs return to `ready` so the task is no longer shown as actively running
 */
export function mapRunStatusToNativeTaskStatus(runStatus: string): string {
  switch (runStatus) {
    case "pending":
    case "running":
      return "in-progress";
    case "completed":
      return "review";
    case "merged":
    case "pr-created":
      return "closed";
    case "conflict":
    case "test-failed":
      return "blocked";
    case "failed":
      return "failed";
    case "stuck":
      return "ready";
    default:
      return "ready";
  }
}
