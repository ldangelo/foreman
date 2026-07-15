import { Box, Text } from "ink";
import { createElement, type ReactElement } from "react";
import type { InboxTaskSummary } from "../../commands/inbox.js";
import { Pane, statusColor, truncate } from "./TaskListPane.js";


const h = createElement;
const BOARD_STATUSES = [
  "backlog",
  "ready",
  "in_progress",
  "needs_attention",
  "closed",
] as const;
type BoardStatus = (typeof BOARD_STATUSES)[number];

function boardColumnForTaskStatus(status: string): BoardStatus {
  const normalized = status.replace(/-/g, "_");
  if (["open", "todo"].includes(normalized)) return "backlog";
  if (["pending", "ready"].includes(normalized)) return "ready";
  if (["running", "in_progress", "cooldown", "explorer", "developer", "qa", "reviewer", "finalize"].includes(normalized)) return "in_progress";
  if (["failed", "stuck", "conflict", "blocked", "review", "test_failed"].includes(normalized)) return "needs_attention";
  if (["merged", "completed", "done", "closed", "reset", "pr_created"].includes(normalized)) return "closed";
  return "needs_attention";
}

const STATUS_LABELS: Record<BoardStatus, string> = {
  backlog: "Backlog",
  ready: "Ready",
  in_progress: "In Progress",
  needs_attention: "Needs Attention",
  closed: "Closed",
};

function boardColumn(summary: InboxTaskSummary): BoardStatus {
  if (summary.attention || summary.verdict === "fail" || summary.verdict === "blocked") return "needs_attention";
  // Tasks without runs (backlog) should go to the backlog column
  if (!summary.run) return "backlog";
  return boardColumnForTaskStatus(summary.runStatus);
}

export function BoardPane({ summaries, selected, compact }: { summaries: InboxTaskSummary[]; selected: InboxTaskSummary | undefined; compact: boolean }): ReactElement {
  const columns = new Map<BoardStatus, InboxTaskSummary[]>();
  for (const status of BOARD_STATUSES) columns.set(status, []);
  for (const summary of summaries) {
    columns.get(boardColumn(summary))?.push(summary);
  }
  for (const status of BOARD_STATUSES) {
    columns.set(status, [...(columns.get(status) ?? [])].sort((a, b) => Date.parse(b.lastActivityAt ?? "") - Date.parse(a.lastActivityAt ?? "")));
  }

  const selectedColumn = selected ? boardColumn(selected) : null;
  const visibleStatuses = compact && selectedColumn ? [selectedColumn] : BOARD_STATUSES;
  const maxCards = compact ? 8 : 5;

  return h(Pane, { title: "Board", minHeight: compact ? 7 : 14 },
    h(Box, { flexDirection: compact ? "column" : "row" },
      ...visibleStatuses.map((status) => {
        const tasks = columns.get(status) ?? [];
        return h(Box, { key: status, flexDirection: "column", flexGrow: 1, paddingRight: compact ? 0 : 1 },
          h(Text, { bold: true, color: status === selectedColumn ? "cyan" : "white" }, `${STATUS_LABELS[status]} (${tasks.length})`),
          ...tasks.slice(0, maxCards).map((task) => {
            const isSelected = selected?.runId === task.runId;
            return h(Text, {
              key: task.runId,
              color: isSelected ? "black" : statusColor(task),
              backgroundColor: isSelected ? statusColor(task) : undefined,
              bold: isSelected,
            }, `${isSelected ? "›" : " "} ${truncate(task.taskId, compact ? 24 : 18)} ${truncate(task.phase, 10)}`);
          }),
          tasks.length > maxCards ? h(Text, { dimColor: true }, `… ${tasks.length - maxCards} more`) : h(Text, { dimColor: true }, " "),
        );
      }),
    ),
    selected ? h(Text, { dimColor: true }, `Selected board context: ${selected.taskId} is in ${selectedColumn ?? "unknown"}.`) : h(Text, { dimColor: true }, "No task selected."),
  );
}
