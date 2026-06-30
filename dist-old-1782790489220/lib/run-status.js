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
 *   cooldown                       → open    (task in cooldown, waiting to be retried)
 *   reset                          → open    (safe default: makes task visible again)
 */
export function mapRunStatusToSeedStatus(runStatus) {
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
        // Cooldown — task is waiting for cooldown period to expire before retry
        case "cooldown":
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
 *   cooldown                       → cooldown (task waiting for cooldown period)
 *   reset                          → ready  (safe default: makes task visible again)
 *
 * NOTE: "open" is NOT a valid NativeTaskStatus — it exists only in the legacy br
 * seed backend. For native tasks, "ready" is the correct status for tasks that
 * should be picked up for retry.
 */
// ── Seed retry/reset target status ───────────────────────────────────────────
/**
 * Seed statuses that indicate an interrupted or failed pipeline and should be
 * reset to "ready" so the task can be re-dispatched.
 *
 * Shared by `foreman reset` and `foreman retry` (previously duplicated as
 * RETRY_READY_STATUSES in reset.ts and RETRYABLE_NATIVE_STATUSES in retry.ts).
 */
const RETRYABLE_PIPELINE_SEED_STATUSES = new Set([
    "backlog",
    "ready",
    "in-progress",
    "blocked",
    "conflict",
    "failed",
    "stuck",
    "explorer",
    "developer",
    "qa",
    "reviewer",
    "finalize",
]);
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
export function getSeedRetryTargetStatus(currentStatus, options) {
    const isTerminal = currentStatus === "closed" || currentStatus === "completed" || currentStatus === "merged";
    if (options.command === "reset") {
        if (currentStatus === "open" || currentStatus === "ready") {
            return currentStatus === "ready" ? "ready" : "open";
        }
        if (isTerminal) {
            return null;
        }
        if (RETRYABLE_PIPELINE_SEED_STATUSES.has(currentStatus)) {
            return "ready";
        }
        return "open";
    }
    if (options.backendType === "native") {
        if (isTerminal) {
            return null;
        }
        if (currentStatus === "ready") {
            return "ready";
        }
        if (RETRYABLE_PIPELINE_SEED_STATUSES.has(currentStatus)) {
            return "ready";
        }
        return null;
    }
    // br-style backends (kept for behavioral parity with the original retry.ts)
    if (currentStatus === "open") {
        return "open";
    }
    if (isTerminal) {
        return null;
    }
    if (currentStatus === "in_progress" || currentStatus === "blocked") {
        return "open";
    }
    return null;
}
export function mapRunStatusToNativeTaskStatus(runStatus) {
    switch (runStatus) {
        case "pending":
        case "running":
            return "in-progress";
        case "completed":
            return "review";
        case "stuck":
            return "ready";
        case "cooldown":
            return "cooldown";
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
//# sourceMappingURL=run-status.js.map