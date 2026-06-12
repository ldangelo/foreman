import type { NativeTaskStatus } from "./types.js";

const DIRECT_NATIVE_PHASE_STATUSES = new Set<NativeTaskStatus>([
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
export function nativeTaskStatusForPhase(phaseName: string): NativeTaskStatus | null {
  if (DIRECT_NATIVE_PHASE_STATUSES.has(phaseName as NativeTaskStatus)) return phaseName as NativeTaskStatus;

  switch (phaseName) {
    case "fix":
    case "implement":
    case "test":
      return "in-progress";
    case "cli-review":
    case "pr-wait":
    case "prepare-pr-review":
    case "pr-review":
    case "merge":
      return null;
    // create-pr: PR has been created, task is now in review/awaiting-merge state.
    // This ensures native task status is updated after PR creation (both explicit
    // create-pr phase and finalize fallback path use onTaskPhaseChange callback).
    case "create-pr":
      return "review";
    default:
      return null;
  }
}
