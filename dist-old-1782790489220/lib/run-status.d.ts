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
import type { RunStatus } from "../orchestrator/read-models.js";
import type { NativeTaskStatus } from "../orchestrator/types.js";
import type { TaskClientBackend } from "./task-client-factory.js";
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
 *   cooldown                       → open    (task in cooldown, waiting to be retried)
 *   reset                          → open    (safe default: makes task visible again)
 */
export declare function mapRunStatusToSeedStatus(runStatus: RunStatus): string;
/** Mode selector for {@link getSeedRetryTargetStatus}. */
export type SeedRetryTargetOptions = {
    command: "reset";
} | {
    command: "retry";
    backendType: TaskClientBackend;
};
/**
 * Map a seed's current status to the status it should be reset to so the task
 * becomes retryable, or `null` if it must be left unchanged (terminal).
 *
 * Two modes preserve the historical per-command semantics:
 *
 * - `{ command: "reset" }` (foreman reset): backend-agnostic. Unknown statuses
 *   fall back to "open" (the br-style retryable status).
 * - `{ command: "retry", backendType }` (foreman retry): for the "native"
 *   backend unknown statuses fall back to `null`; for br-style backends only
 *   "open"/"in_progress"/"blocked" are retryable (→ "open").
 */
export declare function getSeedRetryTargetStatus(currentStatus: string, options: SeedRetryTargetOptions): "open" | "ready" | null;
export declare function mapRunStatusToNativeTaskStatus(runStatus: RunStatus): NativeTaskStatus;
//# sourceMappingURL=run-status.d.ts.map