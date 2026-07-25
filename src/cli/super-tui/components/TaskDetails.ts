import { createElement, type ReactElement } from "react";
import { Text } from "ink";
import type { InboxTaskSummary } from "../../commands/inbox.js";
import { Pane, truncate } from "../panes/TaskListPane.js";

const h = createElement;

export interface TaskDetailsProps {
  summary: InboxTaskSummary | undefined;
  compact?: boolean;
  /** Tab context (for renderTaskDetail switch). */
  tab?: "summary" | "messages" | "events" | "logs" | "reports" | "files";
  /** Optional pre-rendered artifact output. */
  renderedDetail?: string;
  limit?: number;
  eventsLimit?: number;
}

/**
 * Single source of truth for the operator-facing task detail pane.
 *
 * Reads ONLY canonical fields from the InboxTaskSummary:
 *   - taskStatus / taskPhaseId / taskReason / taskFailureReason (server-set
 *     fields from /api/v1/tasks/:id)
 *   - runId / worktreePath / projectId (from the run record)
 *   - runStatus / verdict / lastActivityAt (run-level signals)
 *
 * Falls back to run-derived text only when the canonical fetch was unavailable
 * (postgres/store backends without /api/v1/tasks/:id). Never derives from
 * mailbox bodies — that leaked `phase=finalize` into the Status field.
 */
export function TaskDetails({ summary, tab = "summary", compact = false, renderedDetail, limit: _limit = 50, eventsLimit: _eventsLimit = 50 }: TaskDetailsProps): ReactElement {
  if (!summary) {
    return h(Pane, { title: "Details", minHeight: 7 }, h(Text, null, "No task selected."));
  }

  // Canonical task fields (server-set) take precedence over run-derived fields.
  const status = summary.taskStatus ?? summary.runStatus;
  const phase = summary.taskPhaseId ?? summary.phase;
  const reason = summary.taskFailureReason ?? summary.taskReason ?? null;

  // Active phase is what the developer is currently iterating on. The canonical
  // task projection's phase_id is the LAST COMPLETED phase (e.g. "finalize"
  // after a finalize failure). The run's most recent event's phase_id is the
  // currently-active phase (e.g. "developer" while re-running). Show both when
  // they differ so the operator can see the retry is in flight.
  const activePhase = summary.phase;
  const showActivePhaseSuffix = activePhase && activePhase !== phase && activePhase !== "unknown";

  const rows: (string | null)[] = [
    `Run:      ${summary.runId}`,
    `Status:   ${status}${phase && phase !== "unknown" ? ` · Phase: ${phase}` : ""} · Verdict: ${summary.verdict}`,
    showActivePhaseSuffix
      ? `Active:   ${activePhase} (in flight)`
      : null,
    reason ? `Reason:   ${truncate(reason, compact ? 64 : 120)}` : null,
    `Last:     ${truncate(summary.statusText ?? "—", compact ? 64 : 120)}`,
    `Activity: ${summary.lastActivityAt ?? "—"} via ${summary.lastActivitySource}`,
  ];
  return h(Pane, { title: `Details · ${summary.taskId}`, minHeight: 7 },
    ...rows.filter((row): row is string => row !== null).slice(0, compact ? 8 : 14).map((row, index) =>
      h(Text, { key: `${summary.runId}-detail-${index}` }, truncate(row, compact ? 84 : 132))
    ),
  );
}
