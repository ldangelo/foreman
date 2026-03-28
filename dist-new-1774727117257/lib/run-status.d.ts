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
export declare function mapRunStatusToSeedStatus(runStatus: string): string;
//# sourceMappingURL=run-status.d.ts.map