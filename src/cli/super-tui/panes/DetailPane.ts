import { Text } from "ink";
import { createElement, type ReactElement, useState, useEffect } from "react";
import type { InboxTaskSummary } from "../../commands/inbox.js";
import type { SuperTuiTab } from "../model.js";
import { Pane, truncate } from "./TaskListPane.js";

const h = createElement;

export type RenderSuperTuiTaskDetail = (summary: InboxTaskSummary, options: { messages: boolean; events: boolean; logs?: boolean; reports?: boolean; files?: boolean; limit: number; eventsLimit: number }) => string | Promise<string>;

interface DetailPaneProps {
  summary: InboxTaskSummary | undefined;
  tab: SuperTuiTab;
  limit: number;
  eventsLimit: number;
  renderTaskDetail?: RenderSuperTuiTaskDetail;
  compact: boolean;
}

function DetailPaneInner({ summary, tab, limit, eventsLimit, renderTaskDetail, compact, renderedDetail }: DetailPaneProps & { renderedDetail?: string }): ReactElement {
  if (!summary) return h(Pane, { title: "Details", minHeight: 7 }, h(Text, null, "No task selected."));
  const rows = [
    `Run: ${summary.runId}`,
    `State: ${summary.runStatus} · Phase: ${summary.phase} · Verdict: ${summary.verdict}`,
    `Activity: ${summary.lastActivityAt ?? "—"} via ${summary.lastActivitySource}`,
    `Status: ${summary.statusText}`,
  ];
  if (summary.attentionReason) rows.push(`Attention: ${summary.attentionReason}`);
  if (summary.projectId) rows.push(`Project: ${summary.projectId}`);
  if (summary.worktreePath) rows.push(`Worktree: ${summary.worktreePath}`);

  if (renderTaskDetail && (tab === "logs" || tab === "reports" || tab === "files")) {
    const output = renderedDetail;
    if (output) {
      rows.push(...output.split("\n").slice(0, compact ? 6 : 10));
    }
  }

  return h(Pane, { title: `Details · ${summary.taskId}`, minHeight: 7 },
    ...rows.slice(0, compact ? 8 : 14).map((row, index) => h(Text, { key: `${summary.runId}-detail-${index}` }, truncate(row, compact ? 84 : 132))),
  );
}

export function DetailPane({ summary, tab, limit, eventsLimit, renderTaskDetail, compact }: DetailPaneProps): ReactElement {
  const [renderedDetail, setRenderedDetail] = useState<string | undefined>(undefined);

  useEffect(() => {
    if (!renderTaskDetail || !(tab === "logs" || tab === "reports" || tab === "files")) {
      setRenderedDetail(undefined);
      return;
    }
    const result = renderTaskDetail(summary!, {
      messages: false,
      events: false,
      logs: tab === "logs",
      reports: tab === "reports",
      files: tab === "files",
      limit,
      eventsLimit,
    });
    if (result instanceof Promise) {
      result.then((output) => {
        setRenderedDetail(output);
      }).catch(() => {
        setRenderedDetail(undefined);
      });
    } else {
      setRenderedDetail(result);
    }
  }, [summary, tab, limit, eventsLimit, renderTaskDetail]);

  return h(DetailPaneInner, { summary, tab, limit, eventsLimit, renderTaskDetail, compact, renderedDetail });
}
