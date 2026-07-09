import { Box, Text } from "ink";
import { createElement, type ReactElement } from "react";
import type { InboxTaskSummary } from "../../commands/inbox.js";
import { buildInboxTimeline, type InboxTimelineItem } from "../../inbox/timeline.js";
import type { SuperTuiTab } from "../model.js";
import { Pane, truncate } from "./TaskListPane.js";

const h = createElement;

const TONE_COLOR: Record<InboxTimelineItem["tone"], string> = {
  neutral: "white",
  muted: "gray",
  info: "cyan",
  success: "green",
  warning: "yellow",
  danger: "red",
};

const TAB_LABELS: Record<SuperTuiTab, string> = {
  summary: "Summary",
  messages: "Messages",
  events: "Events",
  logs: "Logs",
  reports: "Reports",
  files: "Files",
};

function formatTimestamp(iso: string | null): string {
  if (!iso) return "—";
  const date = new Date(iso);
  if (!Number.isFinite(date.getTime())) return "—";
  const pad = (value: number): string => String(value).padStart(2, "0");
  return `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function tabTimelineItems(summary: InboxTaskSummary, tab: SuperTuiTab, limit: number, eventsLimit: number): InboxTimelineItem[] {
  if (tab === "messages") return buildInboxTimeline(summary).filter((item) => item.kind === "message").slice(0, limit);
  if (tab === "events") return buildInboxTimeline(summary).filter((item) => item.kind === "event").slice(0, eventsLimit);
  return buildInboxTimeline(summary, { limit: limit + eventsLimit });
}

export function InboxPane({ summary, tab, limit, eventsLimit, compact }: { summary: InboxTaskSummary | undefined; tab: SuperTuiTab; limit: number; eventsLimit: number; compact: boolean }): ReactElement {
  if (!summary) {
    return h(Pane, { title: "Inbox", minHeight: compact ? 5 : 10 }, h(Text, null, "No task selected."));
  }
  const items = tabTimelineItems(summary, tab, limit, eventsLimit);
  const title = tab === "summary" || tab === "logs" || tab === "reports" || tab === "files" ? "Inbox timeline" : TAB_LABELS[tab];
  const maxItems = compact ? 8 : 14;

  if (items.length === 0) {
    return h(Pane, { title, minHeight: compact ? 5 : 10 },
      h(Text, null, `No ${tab === "summary" ? "timeline activity" : TAB_LABELS[tab].toLowerCase()} found for this run.`),
      h(Text, { dimColor: true }, "Use i/s/b to switch views and m/e/l/r/f for detail tabs."),
    );
  }

  return h(Pane, { title, minHeight: compact ? 7 : 14 },
    ...items.slice(0, maxItems).map((item) => h(Box, { key: item.id, flexDirection: "column" },
      h(Text, null,
        h(Text, { color: TONE_COLOR[item.tone], bold: true }, item.kind === "message" ? "✉" : "◆"),
        ` ${formatTimestamp(item.createdAt)} ${truncate(item.phase ?? "unknown", 12)} `,
        h(Text, { color: TONE_COLOR[item.tone] }, truncate(item.label, compact ? 38 : 72)),
      ),
      h(Text, { dimColor: true }, `  ${truncate(item.actor ?? "system", 18)} → ${truncate(item.target ?? "foreman", 18)}${item.detail ? ` · ${truncate(item.detail, compact ? 44 : 88)}` : ""}`),
    )),
    items.length > maxItems ? h(Text, { dimColor: true }, `… ${items.length - maxItems} more timeline items`) : h(Text, { dimColor: true }, " "),
  );
}
