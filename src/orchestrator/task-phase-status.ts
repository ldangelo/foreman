import type { NativeTaskStatus } from "./types.js";

/**
 * Workflow phase names are not task statuses.
 * Any successful phase completion only proves the task is still actively running;
 * phase-level detail is stored separately on task notes/run progress.
 */
export function nativeTaskStatusForPhase(_phaseName: string): NativeTaskStatus {
  return "in-progress";
}
