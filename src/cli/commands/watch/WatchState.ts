/**
 * WatchState — State machine for the unified watch poll + render cycle.
 *
 * Responsibilities:
 * - Poll cycle state: store, runs, messages, task counts
 * - Key handling state: focused panel, selected task
 * - Live inbox tracking: last seen message ID for new-message detection
 * - SIGWINCH handling: terminal resize signal
 */

import chalk from "chalk";
import { resolve } from "node:path";
import { ForemanStore } from "../../../lib/store.js";
import type { Run, RunProgress, Message } from "../../../lib/store.js";
import type { BoardTask } from "../board.js";
import { fetchDaemonDashboardState, type DashboardState } from "../dashboard.js";
import { type BoardStatus } from "../board.js";
import { fetchTaskCounts } from "../../../lib/task-client-factory.js";
import { createTrpcClient } from "../../../lib/trpc-client.js";
import { listRegisteredProjects } from "../project-task-support.js";

// ── Panel focus ─────────────────────────────────────────────────────────

export type PanelId = "agents" | "board" | "inbox";

export function nextPanel(current: PanelId): PanelId {
  return current === "agents" ? "board" : current === "board" ? "inbox" : "agents";
}

// ── Watch options ─────────────────────────────────────────────────────────

export interface WatchOptions {
  refreshMs: number;       // Main poll interval (default: 5000)
  inboxLimit: number;     // Max messages shown (default: 5)
  inboxPollMs: number;    // Inbox-only poll interval (default: 2000)
  noWatch: boolean;       // One-shot snapshot mode
  noBoard: boolean;       // Hide board panel
  noInbox: boolean;       // Hide inbox panel
  projectId?: string;     // Filter to specific project
}

// ── Panel data ────────────────────────────────────────────────────────────

export interface AgentEntry {
  run: Run;
  progress: RunProgress | null;
}

export interface BoardSummary {
  counts: Record<BoardStatus, number>;
  total: number;
  ready: number;
  needsAttention: BoardTask[];
}

export interface InboxEntry {
  message: Message;
  isNew: boolean;  // true if arrived since last render
}

export interface InboxState {
  messages: InboxEntry[];
  totalCount: number;
  newestTimestamp: string | null;
  oldestTimestamp: string | null;
}

// ── Watch state ──────────────────────────────────────────────────────────

export interface WatchState {
  // Data
  dashboard: DashboardState | null;
  agents: AgentEntry[];
  board: BoardSummary | null;
  inbox: InboxState | null;
  taskCounts: { total: number; ready: number; inProgress: number; completed: number; blocked: number } | null;

  // Time
  lastPollMs: number;  // monotonic timestamp of last full poll
  lastInboxPollMs: number;
  inboxLastSeenId: string | null;  // Most recently seen message ID

  // UI
  focusedPanel: PanelId;
  expandedAgentIndices: Set<number>;
  selectedTaskIndex: number;
  showHelp: boolean;
  errorMessage: string | null;

  // Offline indicators (graceful degradation)
  agentsOffline: boolean;
  boardOffline: boolean;
  inboxOffline: boolean;
}

// ── Initial state ────────────────────────────────────────────────────────

export function initialWatchState(): WatchState {
  return {
    dashboard: null,
    agents: [],
    board: null,
    inbox: null,
    taskCounts: null,
    lastPollMs: 0,
    lastInboxPollMs: 0,
    inboxLastSeenId: null,
    focusedPanel: "agents",
    expandedAgentIndices: new Set(),
    selectedTaskIndex: -1,
    showHelp: false,
    errorMessage: null,
    agentsOffline: false,
    boardOffline: false,
    inboxOffline: false,
  };
}

// ── Data polling ──────────────────────────────────────────────────────────

export interface PollResult {
  dashboard: DashboardState;
  agents: AgentEntry[];
  board: BoardSummary;
  taskCounts: { total: number; ready: number; inProgress: number; completed: number; blocked: number };
}

async function loadBoardSummary(
  projectPath: string,
  projectId?: string,
): Promise<BoardSummary> {
  const projects = await listRegisteredProjects();
  const normalizedProjectPath = resolve(projectPath);
  const project = projectId
    ? projects.find((record) => record.id === projectId || record.name === projectId)
    : projects.find((record) => resolve(record.path) === normalizedProjectPath);

  if (!project) {
    return { counts: createEmptyCounts(), total: 0, ready: 0, needsAttention: [] };
  }

  const client = createTrpcClient();
  const rows = await client.tasks.list({ projectId: project.id, limit: 1000 }) as Array<BoardTask>;
  const counts = createEmptyCounts();
  const needsAttention: BoardTask[] = [];

  for (const row of rows) {
    const normalizedStatus = row.status.replace(/-/g, "_") as BoardStatus;
    const status = BOARD_STATUS_SET.has(normalizedStatus) ? normalizedStatus : "closed";
    counts[status] += 1;
    if (NEEDS_ATTENTION_STATUSES.has(row.status)) {
      needsAttention.push({
        ...row,
        projectId: project.id,
        projectName: project.name,
        projectPath: project.path,
      } as BoardTask);
    }
  }

  return {
    counts,
    total: countsTotal(counts),
    ready: counts.ready,
    needsAttention: needsAttention.sort((a, b) => a.priority - b.priority),
  };
}

/**
 * Poll all data sources for the main display.
 * Returns null for unavailable sources (graceful degradation).
 */
export async function pollWatchData(
  projectPath: string,
  projectId?: string,
): Promise<PollResult> {
  // Dashboard state
  let dashboard: DashboardState;
  try {
    dashboard = await fetchDaemonDashboardState(projectPath, projectId)
      ?? { projects: [], activeRuns: new Map(), completedRuns: new Map(), progresses: new Map(), metrics: new Map(), events: new Map(), lastUpdated: new Date() };
  } catch {
    dashboard = { projects: [], activeRuns: new Map(), completedRuns: new Map(), progresses: new Map(), metrics: new Map(), events: new Map(), lastUpdated: new Date() };
  }

  // Active agent entries
  const agents: AgentEntry[] = [];
  try {
    const activeRuns: Run[] = [];
    for (const [, runs] of dashboard.activeRuns) {
      activeRuns.push(...runs);
    }
    for (const run of activeRuns) {
      const progress = dashboard.progresses.get(run.id) ?? null;
      agents.push({ run, progress });
    }
  } catch {
    // agents stays empty
  }

  // Board summary
  let board: BoardSummary;
  try {
    board = await loadBoardSummary(projectPath, projectId);
  } catch {
    board = { counts: createEmptyCounts(), total: 0, ready: 0, needsAttention: [] };
  }

  // Task counts
  let taskCounts = { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 };
  try {
    const currentProject = dashboard.projects[0];
    if (currentProject) {
      const client = createTrpcClient();
      const stats = await client.projects.stats({ projectId: currentProject.id }) as {
        tasks: { total: number; ready: number; inProgress: number; merged: number; closed: number; backlog: number };
      };
      taskCounts = {
        total: stats.tasks.total,
        ready: stats.tasks.ready,
        inProgress: stats.tasks.inProgress,
        completed: stats.tasks.merged + stats.tasks.closed,
        blocked: stats.tasks.backlog,
      };
    } else {
      taskCounts = await fetchTaskCounts(projectPath);
    }
  } catch {
    // ignore
  }

  return { dashboard, agents, board, taskCounts };
}

/**
 * Poll inbox messages for the inbox panel.
 * Returns new messages since `lastSeenId` + total count.
 */
export async function pollInboxData(
  store: ForemanStore,
  lastSeenId: string | null,
  inboxLimit: number,
  runIds: string[],
  projectPath?: string,
  projectId?: string,
): Promise<{ messages: InboxEntry[]; totalCount: number; newestId: string | null }> {
  try {
    if (projectPath) {
      try {
        const projects = await listRegisteredProjects();
        const normalizedProjectPath = resolve(projectPath);
        const project = projectId
          ? projects.find((record) => record.id === projectId || record.name === projectId)
          : projects.find((record) => resolve(record.path) === normalizedProjectPath);
        if (project) {
          const client = createTrpcClient();
          const messageLists = await Promise.all(
            runIds.map((runId) => client.runs.listMessages({ runId }) as Promise<Array<{ id: string; run_id: string; step_key: string | null; stream: string; chunk: string; created_at: string }>>),
          );

          const allMessages: Message[] = messageLists
            .flat()
            .map((msg) => ({
              id: msg.id,
              run_id: msg.run_id,
              sender_agent_type: msg.stream,
              recipient_agent_type: msg.step_key ?? "run",
              subject: (msg.chunk || "").trim().slice(0, 60) || msg.stream,
              body: msg.chunk,
              read: 0,
              created_at: msg.created_at,
              deleted_at: null,
            }));

          allMessages.sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime());
          const totalCount = allMessages.length;
          const recent = allMessages.slice(0, inboxLimit);
          const newestId = recent[0]?.id ?? null;
          const messages: InboxEntry[] = recent.map((msg, i) => ({
            message: msg,
            isNew: lastSeenId !== null && i === 0 && msg.id !== lastSeenId,
          }));
          return { messages, totalCount, newestId };
        }
      } catch {
        // Fall through to legacy local-store inbox path.
      }
    }

    const allMessages: Message[] = [];
    for (const runId of runIds) {
      const msgs = store.getAllMessages(runId);
      allMessages.push(...msgs);
    }

    // Sort by created_at descending
    allMessages.sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime());

    const totalCount = allMessages.length;
    const recent = allMessages.slice(0, inboxLimit);

    const newestId = recent[0]?.id ?? null;
    const messages: InboxEntry[] = recent.map((msg, i) => ({
      message: msg,
      isNew: lastSeenId !== null && i === 0 && msg.id !== lastSeenId,
    }));

    return { messages, totalCount, newestId };
  } catch {
    return { messages: [], totalCount: 0, newestId: null };
  }
}

// ── Board helpers ─────────────────────────────────────────────────────────

function createEmptyCounts(): Record<BoardStatus, number> {
  return {
    backlog: 0,
    ready: 0,
    in_progress: 0,
    review: 0,
    blocked: 0,
    closed: 0,
  };
}

const BOARD_STATUS_SET = new Set<BoardStatus>(["backlog", "ready", "in_progress", "review", "blocked", "closed"]);

function countsTotal(counts: Record<BoardStatus, number>): number {
  return Object.values(counts).reduce((sum, n) => sum + n, 0);
}

const NEEDS_ATTENTION_STATUSES = new Set(["conflict", "failed", "stuck", "backlog"]);

// ── Key handling ──────────────────────────────────────────────────────────

export interface KeyAction {
  panel: PanelId | "global";
  key: string;
  description: string;
  handler: (state: WatchState) => KeyHandlerResult;
}

export interface KeyHandlerResult {
  /** Re-render the display */
  render: boolean;
  /** Interrupt the poll sleep to update immediately */
  wake: boolean;
  /** Quit the watch loop */
  quit: boolean;
  /** No key was matched */
  none: boolean;
}

/**
 * Handle a single keypress in the watch loop.
 * Returns whether to re-render, wake the poll sleep, or quit.
 */
export function handleWatchKey(
  state: WatchState,
  key: string,
): KeyHandlerResult {
  // Global: quit
  if (key === "q" || key === "Q" || key === "\u001B" /* ESC */) {
    return { render: false, wake: false, quit: true, none: false };
  }

  // Global: toggle help
  if (key === "?") {
    state.showHelp = !state.showHelp;
    return { render: true, wake: false, quit: false, none: false };
  }

  // Global: cycle focus
  if (key === "\t" /* Tab */) {
    state.focusedPanel = nextPanel(state.focusedPanel);
    return { render: true, wake: false, quit: false, none: false };
  }

  // Global: open full board
  if (key === "b" || key === "B") {
    // Signal to open foreman board and exit
    return { render: false, wake: false, quit: true, none: false };
  }

  // Global: open full inbox
  if (key === "i" || key === "I") {
    return { render: false, wake: false, quit: true, none: false };
  }

  // Panel-specific keys
  if (state.focusedPanel === "agents") {
    // Tab/1-9 expand agent cards
    if (key === "\t") {
      state.focusedPanel = "board";
      return { render: true, wake: false, quit: false, none: false };
    }
    if (/^[1-9]$/.test(key)) {
      const idx = parseInt(key, 10) - 1;
      if (state.expandedAgentIndices.has(idx)) {
        state.expandedAgentIndices.delete(idx);
      } else {
        state.expandedAgentIndices.add(idx);
      }
      return { render: true, wake: false, quit: false, none: false };
    }
    // a = toggle all
    if (key === "a" || key === "A") {
      if (state.expandedAgentIndices.size > 0) {
        state.expandedAgentIndices.clear();
      } else {
        for (let i = 0; i < state.agents.length; i++) {
          state.expandedAgentIndices.add(i);
        }
      }
      return { render: true, wake: false, quit: false, none: false };
    }
  }

  if (state.focusedPanel === "board") {
    // j/k navigation
    if (key === "j" || key === "\u001B[B" /* Down */) {
      if (state.agents.length > 0) {
        state.selectedTaskIndex = Math.min(state.selectedTaskIndex + 1, (state.board?.needsAttention.length ?? 1) - 1);
      }
      return { render: true, wake: false, quit: false, none: false };
    }
    if (key === "k" || key === "\u001B[A" /* Up */) {
      if (state.agents.length > 0) {
        state.selectedTaskIndex = Math.max(state.selectedTaskIndex - 1, 0);
      }
      return { render: true, wake: false, quit: false, none: false };
    }
    // a = approve
    if (key === "a" || key === "A") {
      return { render: true, wake: true, quit: false, none: false };
    }
    // r = retry
    if (key === "r" || key === "R") {
      return { render: true, wake: true, quit: false, none: false };
    }
  }

  if (state.focusedPanel === "inbox") {
    if (key === "\t") {
      state.focusedPanel = "agents";
      return { render: true, wake: false, quit: false, none: false };
    }
  }

  return { render: false, wake: false, quit: false, none: true };
}

// ── Help overlay ──────────────────────────────────────────────────────────

export function renderHelpOverlay(width: number): string {
  const lines: string[] = [];
  lines.push(chalk.bold("\n  ── HELP ──────────────────────────────────────────────────"));
  lines.push("");
  lines.push("  Global keys:");
  lines.push("    Tab          Cycle focus: Agents → Board → Inbox");
  lines.push("    ?            Toggle this help overlay");
  lines.push("    b            Open full board (foreman board)");
  lines.push("    i            Open full inbox (foreman inbox)");
  lines.push("    q / Esc      Quit");
  lines.push("");
  lines.push("  Agents panel:");
  lines.push("    1-9          Expand/collapse agent card");
  lines.push("    a            Expand all agents");
  lines.push("");
  lines.push("  Board panel:");
  lines.push("    j / ↓       Select next task");
  lines.push("    k / ↑       Select previous task");
  lines.push("    a            Approve selected backlog task → ready");
  lines.push("    r            Retry selected failed/stuck task → backlog");
  lines.push("");
  lines.push("  ────────────────────────────────────────────────────────────");
  lines.push(chalk.dim("  Press any key to close help"));
  return lines.join("\n");
}
