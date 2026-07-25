import type { InboxTaskSummary } from "../cli/commands/inbox.js";

/**
 * Canonical task view derived from an InboxTaskSummary.
 *
 * Canonical fields (`taskStatus`, `taskPhaseId`, `taskReason`,
 * `taskFailureReason`) are populated by the task projection
 * (/api/v1/tasks/:id) and are the authoritative source for cockpit
 * display. Run-derived fields (`runStatus`, `phase`) are used as
 * fallbacks when canonical fields are unavailable (e.g. older summaries
 * constructed before this field was added, or store backends that don't
 * perform the task fetch).
 */
export interface CanonicalTaskView {
  status: string;
  phase: string;
  reason: string | null;
  activePhase: string;
  showActivePhaseSuffix: boolean;
}

export function canonicalTaskView(summary: InboxTaskSummary): CanonicalTaskView {
  const status = summary.taskStatus ?? summary.runStatus;
  const phase = summary.taskPhaseId ?? summary.phase;
  const reason = summary.taskFailureReason ?? summary.taskReason ?? null;
  const activePhase = summary.phase;
  const showActivePhaseSuffix = Boolean(activePhase && activePhase !== phase && activePhase !== "unknown");
  return { status, phase, reason, activePhase, showActivePhaseSuffix };
}
