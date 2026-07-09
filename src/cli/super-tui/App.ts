import { Box, Text, useApp, useInput, useStdout } from "ink";
import { createElement, useEffect, useMemo, useState, type ReactElement } from "react";
import { resetAction } from "../commands/reset.js";
import type { InboxTaskSummary } from "../commands/inbox.js";
import { buildSuperTuiPaletteActions, type SuperTuiPaletteAction } from "./actions.js";
import type { SuperTuiLoadSummaries } from "./data.js";
import { createSuperTuiState, filterSuperTuiSummaries, reduceSuperTuiState, selectedIndexForSelection, type SuperTuiState, type SuperTuiTab, type SuperTuiView } from "./model.js";
import { BoardPane } from "./panes/BoardPane.js";
import { DetailPane, type RenderSuperTuiTaskDetail } from "./panes/DetailPane.js";
import { InboxPane } from "./panes/InboxPane.js";
import { Pane, compactId, truncate } from "./panes/TaskListPane.js";
import { StatusPane } from "./panes/StatusPane.js";
import { TaskListPane } from "./panes/TaskListPane.js";

const h = createElement;

export interface SuperTuiAppProps {
  summaries: InboxTaskSummary[];
  projectLabel: string;
  limit: number;
  eventsLimit: number;
  initialView?: SuperTuiView;
  initialTaskId?: string | null;
  initialRunId?: string | null;
  renderTaskDetail?: RenderSuperTuiTaskDetail;
  loadSummaries?: SuperTuiLoadSummaries;
  refreshIntervalMs?: number;
  resetTask?: SuperTuiResetTaskExecutor;
}

export interface SuperTuiResetTaskResult {
  code: number;
  output: string;
}

export type SuperTuiResetTaskExecutor = (args: { taskId: string; projectId: string | null; projectLabel: string; reason: string }) => Promise<SuperTuiResetTaskResult>;

function stringifyConsoleArgs(args: unknown[]): string {
  return args.map((value) => value instanceof Error ? value.message : String(value)).join(" ");
}

export async function runResetTaskAction(args: { taskId: string; projectLabel: string; reason: string }): Promise<SuperTuiResetTaskResult> {
  const output: string[] = [];
  const originalLog = console.log;
  const originalError = console.error;
  console.log = (...values: unknown[]) => {
    output.push(stringifyConsoleArgs(values));
  };
  console.error = (...values: unknown[]) => {
    output.push(stringifyConsoleArgs(values));
  };
  try {
    const code = await resetAction(args.taskId, { project: args.projectLabel, reason: args.reason });
    return { code, output: output.join("\n") };
  } finally {
    console.log = originalLog;
    console.error = originalError;
  }
}

export interface SuperTuiResetTaskExecutionResult {
  status: "executed" | "failed" | "cancelled";
  notice: string;
  summaries?: InboxTaskSummary[];
}

export async function executeSuperTuiResetTask(args: {
  selected: InboxTaskSummary;
  projectLabel: string;
  resetTask: SuperTuiResetTaskExecutor;
  loadSummaries?: SuperTuiLoadSummaries;
}): Promise<SuperTuiResetTaskExecutionResult> {
  const result = await args.resetTask({
    taskId: args.selected.taskId,
    projectId: args.selected.projectId ?? null,
    projectLabel: args.projectLabel,
    reason: "reset from Foreman TUI",
  });
  const output = result.output ? `: ${truncate(result.output.replace(/\s+/g, " "), 120)}` : "";
  if (result.code !== 0) {
    return { status: "failed", notice: `reset failed (${result.code})${output}` };
  }
  const summaries = args.loadSummaries ? await args.loadSummaries() : undefined;
  return { status: "executed", notice: `reset complete: ${args.selected.taskId}`, summaries };
}

export async function handleSuperTuiResetConfirmation(args: {
  decision: "confirm" | "cancel";
  selected: InboxTaskSummary;
  projectLabel: string;
  resetTask: SuperTuiResetTaskExecutor;
  loadSummaries?: SuperTuiLoadSummaries;
}): Promise<SuperTuiResetTaskExecutionResult> {
  if (args.decision === "cancel") return { status: "cancelled", notice: "reset cancelled" };
  return executeSuperTuiResetTask(args);
}

const VIEW_LABELS: Record<SuperTuiView, string> = {
  overview: "Overview",
  inbox: "Inbox",
  status: "Status",
  board: "Board",
};

const TAB_LABELS: Record<SuperTuiTab, string> = {
  summary: "Summary",
  messages: "Messages",
  events: "Events",
  logs: "Logs",
  reports: "Reports",
  files: "Files",
};

function HeaderBar({ projectLabel, state, selected, visibleCount, refreshStatus }: { projectLabel: string; state: SuperTuiState; selected: InboxTaskSummary | undefined; visibleCount: number; refreshStatus: string }): ReactElement {
  const attentionCount = state.summaries.filter((summary) => summary.attention).length;
  const activeCount = state.summaries.filter((summary) => ["pending", "running", "in_progress", "cooldown"].includes(summary.runStatus)).length;
  const selectedLabel = selected ? `${selected.taskId} / ${compactId(selected.runId, 10)}` : "none";
  const filterLabel = state.filters.length > 0 ? ` filters=${state.filters.join(",")}` : "";
  const searchLabel = state.searchQuery ? ` search=${state.searchQuery}` : "";

  return h(Box, { borderStyle: "single", borderColor: "cyan", paddingX: 1 },
    h(Text, null,
      h(Text, { bold: true }, "FOREMAN WATCH"),
      ` cockpit project=${projectLabel} tasks=${visibleCount}/${state.summaries.length} active=${activeCount} attention=${attentionCount} selected=${selectedLabel} view=${VIEW_LABELS[state.view]} tab=${TAB_LABELS[state.tab]}${filterLabel}${searchLabel} ${refreshStatus}`,
    ),
  );
}

function FooterBar({ state }: { state: SuperTuiState }): ReactElement {
  const paletteHint = state.paletteOpen ? "Esc close palette · Enter show/cue action" : "a/: actions";
  const notice = state.actionNotice ? ` · ${truncate(state.actionNotice, 100)}` : "";
  const searchHint = state.focus === "search" ? `search: ${state.searchQuery || "type…"}` : "/ search";
  return h(Box, { borderStyle: "single", borderColor: "gray", paddingX: 1 },
    h(Text, { dimColor: true }, `j/k select · Tab focus · i inbox · s status · b board · m/e/l/r/f tabs · ${searchHint} · 1 active · 2 attention · 3 all · ! failed · p PR · d dirty · ${paletteHint} · q/Esc quit${notice}`),
  );
}

function OverviewPane({ selected, compact }: { selected: InboxTaskSummary | undefined; compact: boolean }): ReactElement {
  if (!selected) return h(Pane, { title: "Overview" }, h(Text, null, "No task selected."));
  return h(Pane, { title: "Overview", minHeight: compact ? 7 : 14 },
    h(Text, { bold: true }, selected.taskId),
    h(Text, null, `Run: ${selected.runId}`),
    h(Text, null, `State: ${selected.runStatus} · Phase: ${selected.phase} · Verdict: ${selected.verdict}`),
    h(Text, null, `Status: ${truncate(selected.statusText, compact ? 72 : 120)}`),
    selected.attentionReason ? h(Text, { color: "red" }, `Attention: ${truncate(selected.attentionReason, compact ? 72 : 120)}`) : h(Text, { dimColor: true }, "Attention: none"),
    h(Text, { dimColor: true }, "Switch views: i inbox · s status/workflow · b board."),
  );
}

function ActionPalette({ actions, selectedActionIndex, actionNotice, confirmingAction, busy }: { actions: SuperTuiPaletteAction[]; selectedActionIndex: number; actionNotice: string | null; confirmingAction: SuperTuiPaletteAction | null; busy: boolean }): ReactElement {
  return h(Pane, { title: "Actions", minHeight: 8 },
    h(Text, { bold: true }, "Command palette"),
    h(Text, { dimColor: true }, "Enter shows copy/manual commands. Reset runs only after explicit y confirmation."),
    ...actions.map((action, index) => {
      const selected = index === selectedActionIndex;
      return h(Text, {
        key: action.id,
        color: selected ? "black" : action.destructive ? "yellow" : "white",
        backgroundColor: selected ? "cyan" : undefined,
        bold: selected,
      }, `${selected ? "›" : " "} ${action.shortcut} ${action.label}: ${action.description}`);
    }),
    busy ? h(Text, { color: "yellow" }, "Running reset…") : confirmingAction ? h(Text, { color: "red" }, `Confirm ${confirmingAction.label}: press y to run, Esc/n to cancel.`) : actionNotice ? h(Text, { color: "yellow" }, actionNotice) : h(Text, { dimColor: true }, " "),
  );
}

function mainPaneForView(props: { state: SuperTuiState; summaries: InboxTaskSummary[]; selected: InboxTaskSummary | undefined; compact: boolean; limit: number; eventsLimit: number; actions: SuperTuiPaletteAction[]; confirmingAction: SuperTuiPaletteAction | null; actionBusy: boolean }): ReactElement {
  if (props.state.paletteOpen) {
    return h(ActionPalette, { actions: props.actions, selectedActionIndex: props.state.paletteIndex, actionNotice: props.state.actionNotice, confirmingAction: props.confirmingAction, busy: props.actionBusy });
  }
  switch (props.state.view) {
    case "overview":
      return h(OverviewPane, { selected: props.selected, compact: props.compact });
    case "inbox":
      return h(InboxPane, { summary: props.selected, tab: props.state.tab, limit: props.limit, eventsLimit: props.eventsLimit, compact: props.compact });
    case "status":
      return h(StatusPane, { summary: props.selected, compact: props.compact });
    case "board":
      return h(BoardPane, { summaries: props.summaries, selected: props.selected, compact: props.compact });
  }
}

export function SuperTuiApp({ summaries: initialSummaries, projectLabel, limit, eventsLimit, initialView = "overview", initialTaskId = null, initialRunId = null, renderTaskDetail, loadSummaries, refreshIntervalMs = 2000, resetTask = runResetTaskAction }: SuperTuiAppProps): ReactElement {
  const { exit } = useApp();
  const [state, setState] = useState(() => createSuperTuiState({ summaries: initialSummaries, initialView, initialTaskId, initialRunId }));
  const [lastRefreshAt, setLastRefreshAt] = useState<Date | null>(null);
  const [refreshError, setRefreshError] = useState<string | null>(null);
  const [actionBusy, setActionBusy] = useState(false);
  const compact = (process.stdout.columns || 100) < 90;
  const visibleSummaries = useMemo(() => filterSuperTuiSummaries(state.summaries, { query: state.searchQuery, filters: state.filters }), [state.filters, state.searchQuery, state.summaries]);
  const visibleSelectedIndex = selectedIndexForSelection(visibleSummaries, state.selection, state.selectedIndex);
  const selected = visibleSelectedIndex >= 0 ? visibleSummaries[visibleSelectedIndex] : undefined;
  const actions = useMemo(() => buildSuperTuiPaletteActions(selected, projectLabel), [projectLabel, selected]);
  const confirmingAction = state.confirmationAction;
  const refreshStatus = refreshError
    ? `refresh error: ${truncate(refreshError, 48)}`
    : loadSummaries
      ? `refresh=live${lastRefreshAt ? ` · refreshed ${lastRefreshAt.toLocaleTimeString()}` : ""}`
      : "refresh=static";

  const { stdout } = useStdout();
  const terminalRows = stdout.isTTY && Number.isFinite(stdout.rows) ? Math.max(12, stdout.rows) : undefined;
  const bodyRows = terminalRows === undefined ? undefined : Math.max(6, terminalRows - 6);

  useEffect(() => {
    setState((current) => reduceSuperTuiState(current, { type: "refresh", summaries: initialSummaries }));
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
        setState((current) => reduceSuperTuiState(current, { type: "refresh", summaries: next }));
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

  const selectVisibleDelta = (delta: number): void => {
    setState((current) => {
      const currentVisible = filterSuperTuiSummaries(current.summaries, { query: current.searchQuery, filters: current.filters });
      const currentVisibleIndex = selectedIndexForSelection(currentVisible, current.selection, current.selectedIndex);
      if (currentVisible.length === 0) return current;
      const nextVisibleIndex = Math.max(0, Math.min(currentVisible.length - 1, currentVisibleIndex + delta));
      const next = currentVisible[nextVisibleIndex];
      const nextFullIndex = next ? current.summaries.findIndex((summary) => summary.runId === next.runId) : -1;
      return nextFullIndex >= 0 ? reduceSuperTuiState(current, { type: "select-index", index: nextFullIndex }) : current;
    });
  };

  const toggleFilter = (filter: "failed" | "has-pr" | "dirty-worktree"): void => {
    setState((current) => reduceSuperTuiState(current, {
      type: "set-filters",
      filters: current.filters.includes(filter) ? current.filters.filter((item) => item !== filter) : [...current.filters, filter],
    }));
  };

  const executeConfirmedAction = (action: SuperTuiPaletteAction): void => {
    if (action.execution !== "reset-task") return;
    if (!selected) {
      setState((current) => reduceSuperTuiState(current, { type: "set-action-notice", notice: "reset unavailable: no task selected", closePalette: true }));
      return;
    }
    setActionBusy(true);
    setState((current) => reduceSuperTuiState(current, { type: "set-action-notice", notice: `resetting ${selected.taskId}…` }));
    void (async () => {
      try {
        const result = await handleSuperTuiResetConfirmation({ decision: "confirm", selected, projectLabel, resetTask, loadSummaries });
        if (result.summaries) {
          setState((current) => reduceSuperTuiState(reduceSuperTuiState(current, { type: "refresh", summaries: result.summaries ?? current.summaries }), { type: "set-action-notice", notice: result.notice, closePalette: true }));
          setLastRefreshAt(new Date());
          setRefreshError(null);
        } else {
          setState((current) => reduceSuperTuiState(current, { type: "set-action-notice", notice: result.notice, closePalette: true }));
        }
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        setState((current) => reduceSuperTuiState(current, { type: "set-action-notice", notice: `reset failed: ${truncate(message, 120)}`, closePalette: true }));
      } finally {
        setActionBusy(false);
      }
    })();
  };

  useInput((input, key) => {
    if (state.paletteOpen) {
      if (actionBusy) return;
      if (confirmingAction) {
        if (key.escape || input === "n" || input === "N") {
          setState((current) => reduceSuperTuiState(current, { type: "cancel-palette-confirmation" }));
          return;
        }
        if (input === "y" || input === "Y") {
          executeConfirmedAction(confirmingAction);
          return;
        }
        return;
      }
      if (key.escape) {
        setState((current) => reduceSuperTuiState(current, { type: "close-palette" }));
        return;
      }
      if (key.upArrow || input === "k") {
        setState((current) => reduceSuperTuiState(current, { type: "move-palette", delta: -1, actionCount: actions.length }));
        return;
      }
      if (key.downArrow || input === "j") {
        setState((current) => reduceSuperTuiState(current, { type: "move-palette", delta: 1, actionCount: actions.length }));
        return;
      }
      if (key.return) {
        const action = actions[state.paletteIndex];
        if (action?.execution === "reset-task") {
          setState((current) => reduceSuperTuiState(current, { type: "show-palette-action", action }));
          return;
        }
        setState((current) => reduceSuperTuiState(current, { type: "show-palette-action", action }));
        return;
      }
    }

    if (state.focus === "search") {
      if (key.escape || key.return) {
        setState((current) => reduceSuperTuiState(current, { type: "close-search" }));
        return;
      }
      if (key.backspace || key.delete) {
        setState((current) => reduceSuperTuiState(current, { type: "backspace-search" }));
        return;
      }
      if (input && input.length === 1) {
        setState((current) => reduceSuperTuiState(current, { type: "append-search", input }));
        return;
      }
    }

    if (input === "q" || key.escape) exit();
    if (input === "/") setState((current) => reduceSuperTuiState(current, { type: "set-search", query: "" }));
    if (input === "a" || input === ":") setState((current) => reduceSuperTuiState(current, { type: "open-palette" }));
    if (key.upArrow || input === "k") selectVisibleDelta(-1);
    if (key.downArrow || input === "j") selectVisibleDelta(1);
    if (key.tab) setState((current) => reduceSuperTuiState(current, { type: "cycle-focus", delta: key.shift ? -1 : 1 }));
    if (input === "i") setState((current) => reduceSuperTuiState(current, { type: "set-view", view: "inbox" }));
    if (input === "s") setState((current) => reduceSuperTuiState(current, { type: "set-view", view: "status" }));
    if (input === "b") setState((current) => reduceSuperTuiState(current, { type: "set-view", view: "board" }));
    if (input === "m") setState((current) => reduceSuperTuiState(current, { type: "set-tab", tab: "messages" }));
    if (input === "e") setState((current) => reduceSuperTuiState(current, { type: "set-tab", tab: "events" }));
    if (input === "l") setState((current) => reduceSuperTuiState(current, { type: "set-tab", tab: "logs" }));
    if (input === "r") setState((current) => reduceSuperTuiState(current, { type: "set-tab", tab: "reports" }));
    if (input === "f") setState((current) => reduceSuperTuiState(current, { type: "set-tab", tab: "files" }));
    if (input === "1") setState((current) => reduceSuperTuiState(reduceSuperTuiState(current, { type: "set-scope", scope: "active" }), { type: "set-filters", filters: ["active"] }));
    if (input === "2") setState((current) => reduceSuperTuiState(reduceSuperTuiState(current, { type: "set-scope", scope: "attention" }), { type: "set-filters", filters: ["attention"] }));
    if (input === "3") setState((current) => reduceSuperTuiState(reduceSuperTuiState(current, { type: "set-scope", scope: "all" }), { type: "set-filters", filters: [] }));
    if (input === "!") toggleFilter("failed");
    if (input === "p") toggleFilter("has-pr");
    if (input === "d") toggleFilter("dirty-worktree");
    if (key.return && state.view === "overview") setState((current) => reduceSuperTuiState(current, { type: "set-view", view: "inbox" }));
  });

  if (state.summaries.length === 0 || visibleSummaries.length === 0) {
    return h(Box, { flexDirection: "column", height: terminalRows },
      h(HeaderBar, { projectLabel, state, selected, visibleCount: visibleSummaries.length, refreshStatus }),
      h(Box, { flexDirection: "column", flexGrow: 1, height: bodyRows },
        h(Pane, { title: "Cockpit", minHeight: 7 },
          h(Text, { bold: true }, state.summaries.length === 0 ? "No active or attention tasks found." : "No tasks match the current search/filter."),
          h(Text, null, state.summaries.length === 0 ? "Try `foreman inbox --scope all` to include terminal runs, or start a Foreman task to populate this cockpit." : "Press / to change search, 3 for all tasks, or toggle filters."),
        ),
      ),
      h(FooterBar, { state }),
    );
  }

  const mainPane = mainPaneForView({ state, summaries: visibleSummaries, selected, compact, limit, eventsLimit, actions, confirmingAction, actionBusy });

  return h(Box, { flexDirection: "column", height: terminalRows },
    h(HeaderBar, { projectLabel, state, selected, visibleCount: visibleSummaries.length, refreshStatus }),
    compact
      ? h(Box, { flexDirection: "column", flexGrow: 1, height: bodyRows },
        h(TaskListPane, { summaries: visibleSummaries, selectedIndex: visibleSelectedIndex, compact }),
        mainPane,
        h(DetailPane, { summary: selected, tab: state.tab, limit, eventsLimit, renderTaskDetail, compact }),
      )
      : h(Box, { flexDirection: "row", flexGrow: 1, height: bodyRows },
        h(TaskListPane, { summaries: visibleSummaries, selectedIndex: visibleSelectedIndex, compact }),
        h(Box, { flexDirection: "column", flexGrow: 1 },
          mainPane,
          h(DetailPane, { summary: selected, tab: state.tab, limit, eventsLimit, renderTaskDetail, compact }),
        ),
      ),
    h(FooterBar, { state }),
  );
}
