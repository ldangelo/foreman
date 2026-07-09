import { Box, Text } from "ink";
import { createElement, type ReactElement } from "react";
import type { InboxTaskSummary } from "../../commands/inbox.js";

const h = createElement;

export function truncate(value: string, maxLength: number): string {
  if (maxLength <= 0) return "";
  if (value.length <= maxLength) return value;
  if (maxLength === 1) return "…";
  return `${value.slice(0, maxLength - 1)}…`;
}

export function compactId(value: string | null | undefined, length = 8): string {
  if (!value) return "—";
  return value.length <= length ? value : value.slice(0, length);
}

export function statusColor(summary: InboxTaskSummary): string {
  if (summary.verdict === "pass") return "green";
  if (summary.verdict === "fail" || summary.attention) return "red";
  if (summary.verdict === "retrying" || summary.verdict === "blocked") return "yellow";
  return "cyan";
}

export function Pane({ title, children, minHeight, flexGrow = 1, width }: { title: string; children?: React.ReactNode; minHeight?: number; flexGrow?: number; width?: number | string }): ReactElement {
  return h(Box, {
    borderStyle: "round",
    borderColor: "gray",
    flexDirection: "column",
    flexGrow,
    width,
    minHeight,
    paddingX: 1,
  },
    h(Text, { bold: true, color: "cyan" }, title),
    h(Box, { flexDirection: "column" }, children),
  );
}

function timestampMs(value: unknown): number {
  if (typeof value === "string" || typeof value === "number" || value instanceof Date) {
    const ms = new Date(value).getTime();
    return Number.isFinite(ms) ? ms : 0;
  }
  return 0;
}

function relativeTime(iso: string | null): string {
  if (!iso) return "—";
  const ms = timestampMs(iso);
  if (ms <= 0) return "—";
  const deltaSeconds = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  if (deltaSeconds < 60) return `${deltaSeconds}s`;
  const deltaMinutes = Math.floor(deltaSeconds / 60);
  if (deltaMinutes < 60) return `${deltaMinutes}m`;
  const deltaHours = Math.floor(deltaMinutes / 60);
  if (deltaHours < 48) return `${deltaHours}h`;
  return `${Math.floor(deltaHours / 24)}d`;
}

export function TaskListPane({ summaries, selectedIndex, compact }: { summaries: InboxTaskSummary[]; selectedIndex: number; compact: boolean }): ReactElement {
  const visibleCount = compact ? 8 : 18;
  const start = Math.max(0, Math.min(Math.max(0, selectedIndex - Math.floor(visibleCount / 2)), Math.max(0, summaries.length - visibleCount)));
  const visible = summaries.slice(start, start + visibleCount);
  return h(Pane, { title: "Tasks", width: compact ? undefined : 42, flexGrow: compact ? 1 : 0 },
    ...visible.map((summary, offset) => {
      const index = start + offset;
      const selected = index === selectedIndex;
      const marker = selected ? "›" : " ";
      const status = compact ? compactId(summary.runStatus, 9) : summary.runStatus;
      const titleWidth = compact ? 18 : 22;
      return h(Text, {
        key: summary.runId,
        color: selected ? "black" : statusColor(summary),
        backgroundColor: selected ? statusColor(summary) : undefined,
        bold: selected,
      }, `${marker} ${truncate(summary.taskId, titleWidth)} ${status} ${truncate(summary.phase, 10)} ${relativeTime(summary.lastActivityAt)}`);
    }),
    start > 0 ? h(Text, { dimColor: true }, `  … ${start} earlier`) : h(Text, { dimColor: true }, " "),
    start + visible.length < summaries.length
      ? h(Text, { dimColor: true }, `  … ${summaries.length - start - visible.length} more`)
      : h(Text, { dimColor: true }, " "),
  );
}
