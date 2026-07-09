import { Box, Text, useApp, useInput } from "ink";
import { createElement, useEffect, useMemo, useState, type ReactElement, type ReactNode } from "react";
import type { InboxTaskSummary } from "../commands/inbox.js";
import { buildInboxTimeline, type InboxTimelineItem } from "./timeline.js";

type InboxDashboardTab = "summary" | "messages" | "events" | "logs" | "reports" | "files";

interface RenderTaskDetailOptions {
  messages: boolean;
  events: boolean;
  logs?: boolean;
  reports?: boolean;
  files?: boolean;
  limit: number;
  eventsLimit: number;
}

export interface InboxDashboardAction {
  id: string;
  label: string;
  shortcut: string;
  description: string;
  command: string;
}

export interface InboxDashboardProps {
  summaries: InboxTaskSummary[];
  projectLabel: string;
  limit: number;
  eventsLimit: number;
  renderTaskDetail?: (summary: InboxTaskSummary, options: RenderTaskDetailOptions) => string;
  loadSummaries?: () => Promise<InboxTaskSummary[]>;
  refreshIntervalMs?: number;
}

interface PaneProps {
  title: string;
  children?: ReactNode;
  minHeight?: number;
  flexGrow?: number;
  width?: number | string;
}

const h = createElement;

const TAB_LABELS: Record<InboxDashboardTab, string> = {
  summary: "Summary",
  messages: "Messages",
  events: "Events",
  logs: "Logs",
  reports: "Reports",
  files: "Files",
};

const TAB_HINTS: Record<InboxDashboardTab, string> = {
  summary: "s summary",
  messages: "m timeline",
  events: "e events",
  logs: "l logs",
  reports: "r reports",
  files: "f files",
};

const TONE_COLOR: Record<InboxTimelineItem["tone"], string> = {
  neutral: "white",
  muted: "gray",
  info: "cyan",
  success: "green",
  warning: "yellow",
  danger: "red",
};

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

function formatTimestamp(iso: string | null): string {
  if (!iso) return "—";
  const date = new Date(iso);
  if (!Number.isFinite(date.getTime())) return "—";
  const pad = (value: number): string => String(value).padStart(2, "0");
  return `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function truncate(value: string, maxLength: number): string {
  if (maxLength <= 0) return "";
  if (value.length <= maxLength) return value;
  if (maxLength === 1) return "…";
  return `${value.slice(0, maxLength - 1)}…`;
}

function compactId(value: string | null, length = 8): string {
  if (!value) return "—";
  return value.length <= length ? value : value.slice(0, length);
}

function shellArg(value: string): string {
  return /^[A-Za-z0-9._/-]+$/.test(value) ? value : `'${value.replace(/'/g, "'\\''")}'`;
}

export function selectedIndexForRun(summaries: InboxTaskSummary[], selectedRunId: string | null): number {
  if (summaries.length === 0) return -1;
  if (!selectedRunId) return 0;
  const index = summaries.findIndex((summary) => summary.runId === selectedRunId);
  return index >= 0 ? index : 0;
}

export function buildInboxDashboardActions(summary: InboxTaskSummary, projectLabel: string): InboxDashboardAction[] {
  const taskId = shellArg(summary.taskId);
  const runId = shellArg(summary.runId);
  const project = shellArg(projectLabel);
  return [
    {
      id: "drilldown",
      label: "Open drilldown",
      shortcut: "d",
      description: "Show task mail, lifecycle events, logs, reports, and files.",
      command: `foreman inbox task ${taskId} --project ${project} --logs --reports --files`,
    },
    {
      id: "logs",
      label: "Tail logs",
      shortcut: "l",
      description: "Follow the selected task logs outside the cockpit.",
      command: `foreman logs ${taskId} --project ${project} --follow`,
    },
    {
      id: "task",
      label: "Show task",
      shortcut: "t",
      description: "Print the selected task record and current run summary.",
      command: `foreman task show ${taskId} --project ${project}`,
    },
    {
      id: "run",
      label: "Open run detail",
      shortcut: "r",
      description: "Open the selected run drilldown directly.",
      command: `foreman inbox run ${runId} --project ${project} --logs --reports --files`,
    },
  ];
}

function statusColor(summary: InboxTaskSummary): string {
  if (summary.verdict === "pass") return "green";
  if (summary.verdict === "fail" || summary.attention) return "red";
  if (summary.verdict === "retrying" || summary.verdict === "blocked") return "yellow";
  return "cyan";
}

function dashboardTimeline(summary: InboxTaskSummary, limit: number, eventsLimit: number): InboxTimelineItem[] {
  return buildInboxTimeline(summary, { limit: limit + eventsLimit });
}

function tabTimelineItems(summary: InboxTaskSummary, tab: InboxDashboardTab, limit: number, eventsLimit: number): InboxTimelineItem[] {
  if (tab === "messages") {
    return buildInboxTimeline(summary).filter((item) => item.kind === "message").slice(0, limit);
  }
  if (tab === "events") {
    return buildInboxTimeline(summary).filter((item) => item.kind === "event").slice(0, eventsLimit);
  }
  return dashboardTimeline(summary, limit, eventsLimit);
}

function Pane({ title, children, minHeight, flexGrow = 1, width }: PaneProps): ReactElement {
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

function HeaderBar({ projectLabel, summaries, selected, tab, refreshStatus }: { projectLabel: string; summaries: InboxTaskSummary[]; selected: InboxTaskSummary | undefined; tab: InboxDashboardTab; refreshStatus: string }): ReactElement {
  const attentionCount = summaries.filter((summary) => summary.attention).length;
  const activeCount = summaries.filter((summary) => ["pending", "running", "in_progress", "cooldown"].includes(summary.runStatus)).length;
  const selectedLabel = selected ? `${selected.taskId} / ${compactId(selected.runId, 10)}` : "none";

  return h(Box, { borderStyle: "single", borderColor: "cyan", paddingX: 1 },
    h(Text, null,
      h(Text, { bold: true }, "FOREMAN INBOX"),
      `  project=${projectLabel}  tasks=${summaries.length} active=${activeCount} attention=${attentionCount}  selected=${selectedLabel}  mode=${TAB_LABELS[tab]}  ${refreshStatus}`,
    ),
  );
}

function FooterBar({ tab, paletteOpen, actionNotice }: { tab: InboxDashboardTab; paletteOpen: boolean; actionNotice: string | null }): ReactElement {
  const paletteHint = paletteOpen ? "Esc close palette · Enter show command" : "a/: actions";
  const notice = actionNotice ? ` · ${actionNotice}` : "";
  return h(Box, { borderStyle: "single", borderColor: "gray", paddingX: 1 },
    h(Text, { dimColor: true }, `j/k select · ↑/↓ select · Enter toggle · ${TAB_HINTS[tab]} · s/m/e/l/r/f tabs · ${paletteHint} · q/Esc quit${notice}`),
  );
}


function EmptyState({ projectLabel }: { projectLabel: string }): ReactElement {
  return h(Box, { flexDirection: "column" },
    h(HeaderBar, { projectLabel, summaries: [], selected: undefined, tab: "summary", refreshStatus: "static" }),
    h(Pane, { title: "Inbox", minHeight: 7 },
      h(Text, { bold: true }, "No active or attention tasks found."),
      h(Text, null, "Try `foreman inbox --scope all` to include terminal runs, or start a Foreman task to populate this cockpit."),
      h(Text, { dimColor: true }, "Shortcuts: j/k select · s/m/e/l/r/f tabs · a/: actions · q/Esc quit"),
    ),
    h(FooterBar, { tab: "summary", paletteOpen: false, actionNotice: null }),
  );
}

function TaskListPane({ summaries, selectedIndex, compact }: { summaries: InboxTaskSummary[]; selectedIndex: number; compact: boolean }): ReactElement {
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

function TimelinePane({ items, tab, compact }: { items: InboxTimelineItem[]; tab: InboxDashboardTab; compact: boolean }): ReactElement {
  const title = tab === "summary" || tab === "logs" || tab === "reports" || tab === "files" ? "Timeline" : TAB_LABELS[tab];
  const maxItems = compact ? 8 : 14;
  if (items.length === 0) {
    return h(Pane, { title, minHeight: compact ? 5 : 10 },
      h(Text, null, `No ${tab === "summary" ? "timeline activity" : TAB_LABELS[tab].toLowerCase()} found for this run.`),
      h(Text, { dimColor: true }, "Use s/m/e/l/r/f tabs to switch views."),
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
    items.length > maxItems
      ? h(Text, { dimColor: true }, `… ${items.length - maxItems} more timeline items`)
      : h(Text, { dimColor: true }, " "),
  );
}

function TextOutputPane({ title, output, compact }: { title: string; output: string; compact: boolean }): ReactElement {
  const maxLines = compact ? 10 : 16;
  const lines = output.split("\n").slice(0, maxLines);
  return h(Pane, { title, minHeight: compact ? 7 : 14 },
    ...lines.map((line, index) => h(Text, { key: `${title}-${index}` }, truncate(line, compact ? 84 : 132))),
  );
}

function ActionPalette({ actions, selectedActionIndex, actionNotice }: { actions: InboxDashboardAction[]; selectedActionIndex: number; actionNotice: string | null }): ReactElement {
  return h(Pane, { title: "Actions", minHeight: 8 },
    h(Text, { bold: true }, "Command palette"),
    h(Text, { dimColor: true }, "Enter shows the command to run manually. Destructive actions are not executed from this cockpit."),
    ...actions.map((action, index) => {
      const selected = index === selectedActionIndex;
      return h(Text, {
        key: action.id,
        color: selected ? "black" : "white",
        backgroundColor: selected ? "cyan" : undefined,
        bold: selected,
      }, `${selected ? "›" : " "} ${action.shortcut} ${action.label}: ${action.description}`);
    }),
    actionNotice ? h(Text, { color: "yellow" }, actionNotice) : h(Text, { dimColor: true }, " "),
  );
}

function DetailPane({ summary, tab }: { summary: InboxTaskSummary; tab: InboxDashboardTab }): ReactElement {
  const rows = [
    `Run: ${summary.runId}`,
    `State: ${summary.runStatus} · Phase: ${summary.phase} · Verdict: ${summary.verdict}`,
    `Activity: ${relativeTime(summary.lastActivityAt)} via ${summary.lastActivitySource}`,
    `Status: ${summary.statusText}`,
  ];

  if (summary.attentionReason) rows.push(`Attention: ${summary.attentionReason}`);
  if (summary.projectId) rows.push(`Project: ${summary.projectId}`);
  if (summary.worktreePath) rows.push(`Worktree: ${summary.worktreePath}`);
  if (tab === "logs") rows.push("Logs: showing compact log summary in the main pane.");
  if (tab === "reports") rows.push("Reports: showing report directory/files in the main pane.");
  if (tab === "files") rows.push(summary.worktreePath ? "Files: showing worktree status in the main pane." : "Files: no worktree path recorded.");

  return h(Pane, { title: `Details · ${summary.taskId}`, minHeight: 7 },
    ...rows.slice(0, 8).map((row, index) => h(Text, { key: `${summary.runId}-detail-${index}` }, truncate(row, 120))),
  );
}

export function InboxDashboard({ summaries: initialSummaries, projectLabel, limit, eventsLimit, renderTaskDetail, loadSummaries, refreshIntervalMs = 2000 }: InboxDashboardProps): ReactElement {
  const { exit } = useApp();
  const [summaries, setSummaries] = useState(initialSummaries);
  const [selectedRunId, setSelectedRunId] = useState(initialSummaries[0]?.runId ?? null);
  const [tab, setTab] = useState<InboxDashboardTab>("summary");
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [selectedActionIndex, setSelectedActionIndex] = useState(0);
  const [actionNotice, setActionNotice] = useState<string | null>(null);
  const [lastRefreshAt, setLastRefreshAt] = useState<Date | null>(null);
  const [refreshError, setRefreshError] = useState<string | null>(null);
  const compact = (process.stdout.columns || 100) < 90;
  const selectedIndex = selectedIndexForRun(summaries, selectedRunId);
  const selected = selectedIndex >= 0 ? summaries[selectedIndex] : undefined;
  const actions = selected ? buildInboxDashboardActions(selected, projectLabel) : [];
  const refreshStatus = refreshError
    ? `refresh error: ${truncate(refreshError, 48)}`
    : loadSummaries
      ? `refresh=live${lastRefreshAt ? ` · refreshed ${lastRefreshAt.toLocaleTimeString()}` : ""}`
      : "refresh=static";

  useEffect(() => {
    setSummaries(initialSummaries);
    setSelectedRunId((current) => current && initialSummaries.some((summary) => summary.runId === current) ? current : initialSummaries[0]?.runId ?? null);
  }, [initialSummaries]);

  useEffect(() => {
    if (!loadSummaries) return undefined;
    let active = true;
    let inFlight = false;
    const refresh = async (): Promise<void> => {
      if (inFlight) return;
      inFlight = true;
      try {
        const next = await loadSummaries();
        if (!active) return;
        setSummaries(next);
        setSelectedRunId((current) => current && next.some((summary) => summary.runId === current) ? current : next[0]?.runId ?? null);
        setLastRefreshAt(new Date());
        setRefreshError(null);
      } catch (err: unknown) {
        if (active) setRefreshError(err instanceof Error ? err.message : String(err));
      } finally {
        inFlight = false;
      }
    };
    const interval = setInterval(() => { void refresh(); }, refreshIntervalMs);
    return () => {
      active = false;
      clearInterval(interval);
    };
  }, [loadSummaries, refreshIntervalMs]);

  useInput((input, key) => {
    if (paletteOpen) {
      if (key.escape) {
        setPaletteOpen(false);
        return;
      }
      if (key.upArrow || input === "k") {
        setSelectedActionIndex((index) => Math.max(0, index - 1));
        return;
      }
      if (key.downArrow || input === "j") {
        setSelectedActionIndex((index) => Math.min(Math.max(0, actions.length - 1), index + 1));
        return;
      }
      if (key.return) {
        const action = actions[selectedActionIndex];
        if (action) setActionNotice(`Run manually: ${action.command}`);
        return;
      }
    }

    if (input === "q" || key.escape) exit();
    if (input === "a" || input === ":") {
      setPaletteOpen(true);
      setSelectedActionIndex(0);
      setActionNotice(null);
      return;
    }
    if (key.upArrow || input === "k") {
      const nextIndex = Math.max(0, selectedIndex - 1);
      setSelectedRunId(summaries[nextIndex]?.runId ?? null);
    }
    if (key.downArrow || input === "j") {
      const nextIndex = Math.min(Math.max(0, summaries.length - 1), selectedIndex + 1);
      setSelectedRunId(summaries[nextIndex]?.runId ?? null);
    }
    if (input === "s") setTab("summary");
    if (input === "m") setTab("messages");
    if (input === "e") setTab("events");
    if (input === "l") setTab("logs");
    if (input === "r") setTab("reports");
    if (input === "f") setTab("files");
    if (key.return) setTab((current) => current === "summary" ? "messages" : "summary");
  });

  const timelineItems = useMemo(() => {
    if (!selected) return [];
    return tabTimelineItems(selected, tab, limit, eventsLimit);
  }, [eventsLimit, limit, selected, tab]);
  const detailOutput = useMemo(() => {
    if (!selected || !renderTaskDetail) return null;
    if (tab !== "logs" && tab !== "reports" && tab !== "files") return null;
    return renderTaskDetail(selected, {
      messages: false,
      events: false,
      logs: tab === "logs",
      reports: tab === "reports",
      files: tab === "files",
      limit,
      eventsLimit,
    });
  }, [eventsLimit, limit, renderTaskDetail, selected, tab]);
  const mainPane = selected
    ? paletteOpen
      ? h(ActionPalette, { actions, selectedActionIndex, actionNotice })
      : detailOutput
        ? h(TextOutputPane, { title: TAB_LABELS[tab], output: detailOutput, compact })
        : h(TimelinePane, { items: timelineItems, tab, compact })
    : h(Text, null, "No task selected.");

  if (summaries.length === 0) return h(EmptyState, { projectLabel });

  return h(Box, { flexDirection: "column" },
    h(HeaderBar, { projectLabel, summaries, selected, tab, refreshStatus }),
    compact
      ? h(Box, { flexDirection: "column" },
        h(TaskListPane, { summaries, selectedIndex, compact }),
        mainPane,
      )
      : h(Box, { flexDirection: "row" },
        h(TaskListPane, { summaries, selectedIndex, compact }),
        h(Box, { flexDirection: "column", flexGrow: 1 },
          mainPane,
          selected ? h(DetailPane, { summary: selected, tab }) : h(Text, null, ""),
        ),
      ),
    compact && selected ? h(DetailPane, { summary: selected, tab }) : h(Text, { dimColor: true }, ""),
    h(FooterBar, { tab, paletteOpen, actionNotice }),
  );
}
