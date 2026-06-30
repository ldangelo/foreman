const DIRECT_NATIVE_PHASE_STATUSES = new Set([
    "explorer",
    "developer",
    "qa",
    "reviewer",
    "finalize",
]);
/**
 * Map workflow phase names to native task statuses.
 *
 * Workflow configs include helper/builtin phases such as `fix`, `cli-review`,
 * `create-pr`, and `pr-wait` that are not valid native task statuses. Returning
 * null means the task status should be left unchanged; task notes/run progress
 * still provide phase-level detail.
 */
export function nativeTaskStatusForPhase(phaseName) {
    if (DIRECT_NATIVE_PHASE_STATUSES.has(phaseName))
        return phaseName;
    switch (phaseName) {
        case "fix":
        case "implement":
        case "test":
            return "in-progress";
        case "cli-review":
        case "create-pr":
        case "pr-wait":
        case "prepare-pr-review":
        case "pr-review":
        case "merge":
            return null;
        default:
            return null;
    }
}
//# sourceMappingURL=task-phase-status.js.map