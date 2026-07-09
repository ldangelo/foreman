import type { InboxTaskSummary } from "../commands/inbox.js";
import type { SuperTuiPaletteAction } from "./actions.js";
import { actionNotice, buildSuperTuiPaletteActions } from "./actions.js";

export type SuperTuiView = "overview" | "inbox" | "status" | "board";
export type SuperTuiTab = "summary" | "messages" | "events" | "logs" | "reports" | "files";
export type SuperTuiScope = "active" | "attention" | "all";
export type SuperTuiFilter = "active" | "attention" | "failed" | "stale" | "has-pr" | "dirty-worktree" | "current-project" | "global";
export type SuperTuiFocus = "tasks" | "main" | "details" | "palette" | "search";

export interface SuperTuiSelection {
  taskId: string | null;
  runId: string | null;
  projectId: string | null;
  view: SuperTuiView;
}

export interface SuperTuiState {
  summaries: InboxTaskSummary[];
  view: SuperTuiView;
  tab: SuperTuiTab;
  focus: SuperTuiFocus;
  selectedIndex: number;
  selection: SuperTuiSelection;
  scope: SuperTuiScope;
  searchQuery: string;
  filters: SuperTuiFilter[];
  paletteOpen: boolean;
  paletteIndex: number;
  actionNotice: string | null;
  confirmationAction: SuperTuiPaletteAction | null;
}

export type SuperTuiAction =
  | { type: "refresh"; summaries: InboxTaskSummary[] }
  | { type: "select-index"; index: number }
  | { type: "move-selection"; delta: number }
  | { type: "set-view"; view: SuperTuiView }
  | { type: "cycle-view"; delta: 1 | -1 }
  | { type: "set-tab"; tab: SuperTuiTab }
  | { type: "set-scope"; scope: SuperTuiScope }
  | { type: "set-search"; query: string }
  | { type: "set-filters"; filters: SuperTuiFilter[] }
  | { type: "cycle-focus"; delta: 1 | -1 }
  | { type: "open-palette" }
  | { type: "close-palette" }
  | { type: "move-palette"; delta: number; actionCount: number }
  | { type: "show-palette-action"; action?: SuperTuiPaletteAction }
  | { type: "set-action-notice"; notice: string | null; closePalette?: boolean }
  | { type: "cancel-palette-confirmation" }
  | { type: "append-search"; input: string }
  | { type: "backspace-search" }
  | { type: "close-search" };

const VIEWS: SuperTuiView[] = ["overview", "inbox", "status", "board"];
const FOCI: SuperTuiFocus[] = ["tasks", "main", "details"];

export function selectionFromSummary(summary: InboxTaskSummary | undefined, view: SuperTuiView): SuperTuiSelection {
  return {
    taskId: summary?.taskId ?? null,
    runId: summary?.runId ?? null,
    projectId: summary?.projectId ?? null,
    view,
  };
}

export function selectedIndexForSelection(
  summaries: InboxTaskSummary[],
  selection: Pick<SuperTuiSelection, "runId" | "taskId">,
  previousIndex = 0,
): number {
  if (summaries.length === 0) return -1;
  if (selection.runId) {
    const runIndex = summaries.findIndex((summary) => summary.runId === selection.runId);
    if (runIndex >= 0) return runIndex;
  }
  if (selection.taskId) {
    const taskIndex = summaries.findIndex((summary) => summary.taskId === selection.taskId);
    if (taskIndex >= 0) return taskIndex;
  }
  return clampIndex(previousIndex, summaries.length);
}

export function selectedSummary(state: SuperTuiState): InboxTaskSummary | undefined {
  return state.selectedIndex >= 0 ? state.summaries[state.selectedIndex] : undefined;
}

export function createSuperTuiState(options: {
  summaries: InboxTaskSummary[];
  initialView?: SuperTuiView;
  initialTaskId?: string | null;
  initialRunId?: string | null;
  scope?: SuperTuiScope;
  searchQuery?: string;
  filters?: SuperTuiFilter[];
}): SuperTuiState {
  const view = options.initialView ?? "overview";
  const selectedIndex = selectedIndexForSelection(
    options.summaries,
    { runId: options.initialRunId ?? null, taskId: options.initialTaskId ?? null },
    0,
  );
  const summary = selectedIndex >= 0 ? options.summaries[selectedIndex] : undefined;
  return {
    summaries: options.summaries,
    view,
    tab: "summary",
    focus: "tasks",
    selectedIndex,
    selection: selectionFromSummary(summary, view),
    scope: options.scope ?? "attention",
    searchQuery: options.searchQuery ?? "",
    filters: options.filters ?? [],
    paletteOpen: false,
    paletteIndex: 0,
    actionNotice: null,
    confirmationAction: null,
  };
}

export function reduceSuperTuiState(state: SuperTuiState, action: SuperTuiAction): SuperTuiState {
  switch (action.type) {
    case "refresh": {
      const selectedIndex = selectedIndexForSelection(action.summaries, state.selection, state.selectedIndex);
      const summary = selectedIndex >= 0 ? action.summaries[selectedIndex] : undefined;
      return {
        ...state,
        summaries: action.summaries,
        selectedIndex,
        selection: selectionFromSummary(summary, state.view),
        paletteIndex: 0,
        confirmationAction: null,
      };
    }
    case "select-index":
      return selectIndex(state, action.index);
    case "move-selection":
      return selectIndex(state, state.selectedIndex + action.delta);
    case "set-view":
      return {
        ...state,
        view: action.view,
        selection: { ...state.selection, view: action.view },
        paletteOpen: false,
        actionNotice: null,
      };
    case "cycle-view": {
      const current = VIEWS.indexOf(state.view);
      const next = VIEWS[wrapIndex(current + action.delta, VIEWS.length)] ?? "overview";
      return reduceSuperTuiState(state, { type: "set-view", view: next });
    }
    case "set-tab":
      return { ...state, tab: action.tab, paletteOpen: false };
    case "set-scope":
      return { ...state, scope: action.scope };
    case "set-search":
      return { ...state, searchQuery: action.query, focus: "search" };
    case "set-filters":
      return { ...state, filters: [...action.filters] };
    case "append-search":
      return { ...state, searchQuery: `${state.searchQuery}${action.input}`, focus: "search" };
    case "backspace-search":
      return { ...state, searchQuery: state.searchQuery.slice(0, -1), focus: "search" };
    case "close-search":
      return { ...state, focus: "tasks" };
    case "cycle-focus": {
      const focusList = state.paletteOpen ? [...FOCI, "palette" as const] : FOCI;
      const current = focusList.indexOf(state.focus);
      const focus = focusList[wrapIndex(current + action.delta, focusList.length)] ?? "tasks";
      return { ...state, focus };
    }
    case "open-palette":
      return { ...state, paletteOpen: true, focus: "palette", paletteIndex: 0, actionNotice: null, confirmationAction: null };
    case "close-palette":
      return { ...state, paletteOpen: false, focus: "tasks", actionNotice: null, confirmationAction: null };
    case "move-palette":
      return {
        ...state,
        paletteIndex: wrapIndex(state.paletteIndex + action.delta, Math.max(1, action.actionCount)),
        actionNotice: null,
        confirmationAction: null,
      };
    case "show-palette-action":
      if (action.action?.safety === "confirmed-execution") {
        return {
          ...state,
          paletteOpen: true,
          focus: "palette",
          confirmationAction: action.action,
          actionNotice: `Confirm ${action.action.label}: press y to execute, or Esc/n to cancel. ${action.action.command}`,
        };
      }
      return { ...state, actionNotice: actionNotice(action.action), paletteOpen: false, focus: "tasks", confirmationAction: null };
    case "set-action-notice":
      return {
        ...state,
        actionNotice: action.notice,
        paletteOpen: action.closePalette ? false : state.paletteOpen,
        focus: action.closePalette ? "tasks" : state.focus,
        confirmationAction: action.closePalette ? null : state.confirmationAction,
      };
    case "cancel-palette-confirmation":
      return {
        ...state,
        paletteOpen: false,
        focus: "tasks",
        confirmationAction: null,
        actionNotice: state.confirmationAction ? `cancelled: ${state.confirmationAction.label}` : null,
      };
  }
}

export interface SuperTuiFilterOptions {
  query?: string;
  filters?: SuperTuiFilter[];
  currentProjectId?: string | null;
  staleAfterMs?: number;
  now?: number;
}

export function filterSuperTuiSummaries(summaries: InboxTaskSummary[], options: SuperTuiFilterOptions = {}): InboxTaskSummary[] {
  const query = (options.query ?? "").trim().toLowerCase();
  const filters = options.filters ?? [];
  const now = options.now ?? Date.now();
  const staleAfterMs = options.staleAfterMs ?? 30 * 60 * 1000;
  return summaries.filter((summary) => {
    if (query && !summaryMatchesSearch(summary, query)) return false;
    return filters.every((filter) => summaryMatchesFilter(summary, filter, { currentProjectId: options.currentProjectId ?? null, now, staleAfterMs }));
  });
}

export function selectedVisibleIndexForState(state: SuperTuiState, visibleSummaries: InboxTaskSummary[]): number {
  return selectedIndexForSelection(visibleSummaries, state.selection, state.selectedIndex);
}

function summaryMatchesSearch(summary: InboxTaskSummary, query: string): boolean {
  const values: string[] = [
    summary.taskId,
    summary.runId,
    summary.runStatus,
    summary.phase,
    summary.statusText,
    summary.attentionReason ?? "",
    summary.projectId ?? "",
    summary.worktreePath ?? "",
  ];
  for (const message of summary.messages) {
    values.push(message.subject, message.body, message.sender_agent_type, message.recipient_agent_type);
  }
  for (const event of summary.events) {
    values.push(event.eventType, event.taskId ?? "", event.runId ?? "", event.projectId ?? "");
    if (event.details) values.push(...Object.values(event.details).map((value) => typeof value === "string" || typeof value === "number" || typeof value === "boolean" ? String(value) : JSON.stringify(value)));
  }
  return values.some((value) => value.toLowerCase().includes(query));
}

function summaryMatchesFilter(summary: InboxTaskSummary, filter: SuperTuiFilter, context: { currentProjectId: string | null; now: number; staleAfterMs: number }): boolean {
  switch (filter) {
    case "active":
      return ["pending", "running", "in_progress", "cooldown"].includes(summary.runStatus);
    case "attention":
      return summary.attention;
    case "failed":
      return summary.verdict === "fail" || ["failed", "stuck", "conflict", "test-failed"].includes(summary.runStatus);
    case "stale": {
      const last = timestampMs(summary.lastActivityAt);
      return last > 0 && context.now - last >= context.staleAfterMs;
    }
    case "has-pr":
      return summary.runStatus === "pr-created" || summaryHasDetail(summary, ["prUrl", "pr_url", "pull_request_url"]);
    case "dirty-worktree":
      return /dirty|changed files?|modified|uncommitted/i.test(summary.statusText) || summaryHasDetail(summary, ["dirty", "dirtyWorktree", "dirty_worktree", "changedFiles", "changed_files"]);
    case "current-project":
      return context.currentProjectId ? summary.projectId === context.currentProjectId : true;
    case "global":
      return context.currentProjectId ? summary.projectId !== context.currentProjectId : summary.projectId === null;
  }
}

function summaryHasDetail(summary: InboxTaskSummary, keys: string[]): boolean {
  for (const event of summary.events) {
    if (!event.details) continue;
    for (const key of keys) {
      const value = event.details[key];
      if (typeof value === "boolean") {
        if (value) return true;
      } else if (typeof value === "string" && value.length > 0) {
        return true;
      } else if (Array.isArray(value) && value.length > 0) {
        return true;
      }
    }
  }
  return false;
}

function timestampMs(value: unknown): number {
  if (typeof value === "string" || typeof value === "number" || value instanceof Date) {
    const ms = new Date(value).getTime();
    return Number.isFinite(ms) ? ms : 0;
  }
  return 0;
}

export function buildCurrentPaletteActions(state: SuperTuiState, projectLabel: string): SuperTuiPaletteAction[] {
  return buildSuperTuiPaletteActions(selectedSummary(state), projectLabel);
}

function selectIndex(state: SuperTuiState, index: number): SuperTuiState {
  const selectedIndex = state.summaries.length === 0 ? -1 : clampIndex(index, state.summaries.length);
  const summary = selectedIndex >= 0 ? state.summaries[selectedIndex] : undefined;
  return {
    ...state,
    selectedIndex,
    selection: selectionFromSummary(summary, state.view),
    paletteIndex: 0,
    actionNotice: null,
  };
}

function clampIndex(index: number, length: number): number {
  if (length <= 0) return -1;
  if (!Number.isFinite(index)) return 0;
  return Math.max(0, Math.min(length - 1, Math.trunc(index)));
}

function wrapIndex(index: number, length: number): number {
  if (length <= 0) return 0;
  return ((index % length) + length) % length;
}
