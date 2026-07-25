import type { InboxTaskSummary } from "../cli/commands/inbox.js";

/**
 * Canonical task view derived from an InboxTaskSummary.
 *
 * Canonical fields (`taskStatus`, `taskPhaseId`, `taskReason`,
 * `taskFailureReason`) are populated by the task projection
 * (/api/v1/tasks/:id) and are the authoritative source for cockpit
 * display. Run-derived fields (`runStatus`, `phase`) are used as
 * fallbacks when canonical fields are unavailable (undefined, null,
 * or blank).
 */
export interface CanonicalTaskView {
  status: string;
  phase: string;
  reason: string | null;
  activePhase: string;
  showActivePhaseSuffix: boolean;
}

/** Returns true when `v` is a non-blank string. */
function isPresent(v: unknown): v is string {
  return typeof v === "string" && v.length > 0;
}

export function canonicalTaskView(summary: InboxTaskSummary): CanonicalTaskView {
  const status = isPresent(summary.taskStatus) ? summary.taskStatus : summary.runStatus;
  const phase = isPresent(summary.taskPhaseId) ? summary.taskPhaseId : summary.phase;
  const reason = isPresent(summary.taskFailureReason)
    ? summary.taskFailureReason
    : isPresent(summary.taskReason)
    ? summary.taskReason
    : null;
  const activePhase = summary.phase;
  const showActivePhaseSuffix = Boolean(activePhase && activePhase !== phase && activePhase !== "unknown");
  return { status, phase, reason, activePhase, showActivePhaseSuffix };
}
