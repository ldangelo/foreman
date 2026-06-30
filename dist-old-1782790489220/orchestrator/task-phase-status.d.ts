import type { NativeTaskStatus } from "./types.js";
/**
 * Map workflow phase names to native task statuses.
 *
 * Workflow configs include helper/builtin phases such as `fix`, `cli-review`,
 * `create-pr`, and `pr-wait` that are not valid native task statuses. Returning
 * null means the task status should be left unchanged; task notes/run progress
 * still provide phase-level detail.
 */
export declare function nativeTaskStatusForPhase(phaseName: string): NativeTaskStatus | null;
//# sourceMappingURL=task-phase-status.d.ts.map