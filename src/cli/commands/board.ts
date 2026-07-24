/**
 * `foreman board` — Terminal UI kanban board for managing Foreman tasks.
 *
 * Features:
 * - 5 status columns: backlog, ready, in_progress, needs_attention, closed
 * - review tasks are routed to needs_attention column
 * - vim-style navigation: j/k (vertical), h/l (horizontal)
 * - Status cycling: s (forward), S (backward)
 * - Mark as ready: R
 * - Close task: c / C (with reason)
 * - Edit in $EDITOR: e / E (full schema)
 * - Copy selected task ID: y
 * - Task detail view: Enter
 * - Help overlay: ?
 * - Refresh: r
 *
 * @module src/cli/commands/board
 */

import { Command } from "commander";
import chalk from "chalk";
import { Box, Spacer, Text, renderToString } from "ink";
import { createElement } from "react";
import { basename, resolve } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join as joinPath } from "node:path";
import { createInterface } from "node:readline/promises";
import * as yaml from "js-yaml";
import { createTrpcClient } from "../../lib/trpc-client.js";
import { foremanBackendMode } from "../../lib/backend-mode.js";
import { ElixirServerClient, type ElixirTask } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import {
  priorityLabel,
  formatTaskIdDisplay,
  parsePriority,
  type TaskRow,
} from "../../lib/task-store.js";
type TaskNoteRow = { id: string; task_id: string; body: string; author: string; created_at: string; phase: string | null; kind: string };
import { listRegisteredProjects, resolveProjectPathFromOptions, requireProjectOrAllInMultiMode } from "./project-task-support.js";
import { runInboxSuperTuiForProject } from "./inbox.js";

// ── Types ─────────────────────────────────────────────────────────────────────────

/** The 6 fixed status columns. */
export const BOARD_STATUSES = [
  "backlog",
  "ready",
  "in_progress",
  "needs_attention",
  "closed",
] as const;
export type BoardStatus = (typeof BOARD_STATUSES)[number];

export type BoardCommandRoute = "cockpit" | "legacy-board";

export interface BoardCommandRouteOptions {
  all?: boolean;
  filter?: string;
}

export function resolveBoardCommandRoute(options: BoardCommandRouteOptions, stdoutIsTTY: boolean | undefined): BoardCommandRoute {
  if (options.all === true || options.filter != null || stdoutIsTTY !== true) {
    return "legacy-board";
  }
  return "cockpit";
}

export function normalizeStatusForBoard(status: string): BoardStatus | null {
  const normalized = status.replace(/-/g, "_");
  return BOARD_STATUSES.includes(normalized as BoardStatus) ? normalized as BoardStatus : null;
}

// The server's `BoardItem.status` is already a lifecycle value
// (backlog/ready/in_progress/needs_attention/done). Phase names
// (developer/qa/reviewer/finalize/explorer) are NEVER accepted here
// — they belong to runs, not tasks, and treating them as task
// statuses was the root cause of the user-reported leak. If a phase
// name somehow reaches the CLI, the default arm routes to
// `needs_attention` so the ambiguous state is visible.
export function boardColumnForTaskStatus(status: string): BoardStatus {
  const normalized = status.replace(/-/g, "_");
  if (["open", "todo"].includes(normalized)) {
    return "backlog";
  }
  if (["pending", "ready"].includes(normalized)) {
    return "ready";
  }
  if (["running", "cooldown"].includes(normalized)) {
    return "in_progress";
  }
  if (["failed", "fail", "stuck", "conflict", "blocked", "test_failed"].includes(normalized)) {
    return "needs_attention";
  }
  if (["merged", "completed", "done", "closed", "reset", "pr_created"].includes(normalized)) {
    // Legacy CLI column key is `closed` (Go cockpit uses `done`);
    // see the module-level `BoardCommandRoute` comment.
    return "closed";
  }
  return normalizeStatusForBoard(status) ?? "needs_attention";
}

function boardStatusToStoreStatus(status: BoardStatus): string {
  if (status === "in_progress") return "in-progress";
  if (status === "needs_attention") return "blocked";
  return status;
}

/**
 * Convert a store status (hyphenated) to a board status (underscored).
 * Returns the board status or null if not a valid board status.
 */
function storeStatusToBoardStatus(status: string): BoardStatus | null {
  const normalized = status.replace(/-/g, "_");
  return BOARD_STATUSES.includes(normalized as BoardStatus) ? normalized as BoardStatus : null;
}

/**
 * Convert a user-entered status (underscore or hyphen variants) to a store-valid status.
 * Handles in_progress → in-progress and needs_attention → blocked conversions.
 */
export function normalizeStatusForStore(status: string): string {
  const boardStatus = storeStatusToBoardStatus(status);
  if (boardStatus) {
    return boardStatusToStoreStatus(boardStatus);
  }
  // If not a valid board status, return as-is and let the API reject it
  return status;
}

const STATUS_LABELS: Record<BoardStatus, string> = {
  backlog: "Backlog",
  ready: "Ready",
  in_progress: "In Progress",
  needs_attention: "Needs Attention",
  closed: "Closed",
};

/** Priority badge characters. */
const PRIORITY_BADGES: Record<number, string> = {
  0: "P0",
  1: "P1",
  2: "P2",
  3: "P3",
  4: "P4",
};

const PRIORITY_COLORS: Record<number, { textColor: string; backgroundColor: string }> = {
  0: { textColor: "white", backgroundColor: "red" },
  1: { textColor: "black", backgroundColor: "yellow" },
  2: { textColor: "black", backgroundColor: "cyan" },
  3: { textColor: "white", backgroundColor: "gray" },
  4: { textColor: "white", backgroundColor: "blackBright" },
};

export interface BoardTaskNote {
  id: string;
  created_at: string;
  phase: string | null;
  kind: string;
  author: string;
  body: string;
}

export interface BoardTask {
  id: string;
  title: string;
  description: string | null;
  type: string;
  priority: number;
  status: string;
  external_id: string | null;
  created_at: string;
  updated_at: string;
  approved_at: string | null;
  closed_at: string | null;
  run_id?: string | null;
  phase_id?: string | null;
  notes?: BoardTaskNote[];
}

type BoardContext =
  | { backend: "node"; client: ReturnType<typeof createTrpcClient>; projectId: string; projectPath: string }
  | { backend: "elixir"; client: ElixirServerClient; projectId: string; projectPath: string };

export interface NavigationState {
  colIndex: number;       // 0-5 for status columns
  rowIndex: number;       // position within the column's task list
}

/** Sort modes for board columns. */
export type SortMode = "updated" | "priority";

/** Sort mode display labels. */
export const SORT_MODE_LABELS: Record<SortMode, string> = {
  updated: "Updated",
  priority: "Priority",
};

export interface RenderState {
  tasks: Map<BoardStatus, BoardTask[]>;
  nav: NavigationState;
  totalTasks: number;
  errorMessage: string | null;
  flashTaskId: string | null;
  showHelp: boolean;
  showDetail: boolean;
  detailTask: BoardTask | null;
  detailNotesStatus: "idle" | "loading" | "loaded" | "error";
  detailNotesError: string | null;
  sortMode: SortMode;
  refreshStatus?: "idle" | "refreshing" | "refreshed";
  refreshSpinnerFrame?: number;
  refreshedAt?: string | null;
}

// ── Board data loading ───────────────────────────────────────────────────────

/**
 * Sort tasks based on the selected sort mode.
 * - "updated" (default): most recently updated first (descending updated_at)
 * - "priority": P0 first (ascending priority), then by updated_at
 */
function parseTaskUpdatedAt(task: BoardTask): number {
  const timestamp = Date.parse(task.updated_at);
  return Number.isNaN(timestamp) ? 0 : timestamp;
}

export function sortBoardTasks(tasks: BoardTask[], sortMode: SortMode): BoardTask[] {
  const sorted = [...tasks];
  if (sortMode === "priority") {
    // Sort by priority ascending (P0 first), then by updated_at descending (most recent first)
    sorted.sort((a, b) => {
      if (a.priority !== b.priority) {
        return a.priority - b.priority;
      }
      return parseTaskUpdatedAt(b) - parseTaskUpdatedAt(a);
    });
  } else {
    // Default: sort by updated_at descending (most recently updated first)
    sorted.sort((a, b) => parseTaskUpdatedAt(b) - parseTaskUpdatedAt(a));
  }
  return sorted;
}

/**
 * Sort all tasks in a column map based on the selected sort mode.
 */
export function sortBoardColumns(
  taskMap: Map<BoardStatus, BoardTask[]>,
  sortMode: SortMode,
): Map<BoardStatus, BoardTask[]> {
  const sorted = new Map<BoardStatus, BoardTask[]>();
  for (const [status, tasks] of taskMap) {
    sorted.set(status, sortBoardTasks(tasks, sortMode));
  }
  return sorted;
}

async function resolveBoardContext(projectPath: string): Promise<BoardContext> {
  const projects = await listRegisteredProjects();
  const resolvedProjectPath = resolve(projectPath);
  const project = projects.find((record) => resolve(record.path) === resolvedProjectPath);
  if (!project) {
    throw new Error(
      `Project at '${projectPath}' is not registered in Elixir projections. Run 'foreman project register ${resolvedProjectPath}'.`,
    );
  }

  if (foremanBackendMode() === "elixir") {
    const manager = new ElixirServerManager();
    const status = await manager.ensureRunning();
    if (!status.running) {
      throw new Error("Elixir server is not running. Start it with 'foreman server start'.");
    }
    const client = new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN);
    return { backend: "elixir", client, projectId: project.id, projectPath };
  }

  return {
    backend: "node",
    client: createTrpcClient(),
    projectId: project.id,
    projectPath,
  };
}

/**
 * Load all tasks from the native task store, grouped by status.
 * Tasks with unknown statuses are placed in the rightmost column (closed).
 * Failed, stuck, and conflict statuses route to needs_attention (not closed).
 */
function boardTaskFromRow(row: TaskRow): BoardTask {
  return {
    id: row.id,
    title: row.title,
    description: row.description,
    type: row.type,
    priority: row.priority,
    status: row.status,
    external_id: row.external_id,
    created_at: row.created_at,
    updated_at: row.updated_at,
    approved_at: row.approved_at,
    closed_at: row.closed_at,
    run_id: row.run_id,
    phase_id: null,
  };
}

function boardTaskFromElixir(row: ElixirTask): BoardTask {
  const now = new Date().toISOString();
  const id = row.task_id ?? row.id ?? "unknown";
  return {
    id,
    title: row.title ?? id,
    description: row.description ?? null,
    type: row.type ?? row.task_type ?? "task",
    priority: typeof row.priority === "number" ? row.priority : 2,
    status: row.status ?? "backlog",
    external_id: row.external_id ?? null,
    created_at: row.created_at ?? row.updated_at ?? now,
    updated_at: row.updated_at ?? row.created_at ?? now,
    approved_at: row.approved_at ?? null,
    closed_at: row.closed_at ?? null,
    run_id: row.run_id ?? null,
    phase_id: row.phase_id ?? null,
    notes: (row.annotations ?? []).map((note, index) => ({
      id: `${id}-annotation-${index}`,
      created_at: note.created_at ?? now,
      phase: null,
      kind: "note",
      author: note.author ?? "unknown",
      body: note.body,
    })),
  };
}

/**
 * Resolve a user-provided filter value to the target BoardStatus.
 * Handles common aliases: completed/closed, in-progress/in_progress, needs-attention/needs_attention.
 */
export function resolveFilterToBoardStatus(filter: string | undefined): BoardStatus | null {
  if (!filter) return null;
  const normalized = filter.replace(/-/g, "_").toLowerCase();
  // Handle aliases for closed column
  if (["completed", "closed", "merged", "done"].includes(normalized)) {
    return "closed";
  }
  // Handle aliases for in_progress
  if (["in_progress", "inprogress", "in-progress"].includes(normalized)) {
    return "in_progress";
  }
  // Handle aliases for needs_attention
  if (["needs_attention", "needsattention", "needs-attention", "blocked"].includes(normalized)) {
    return "needs_attention";
  }
  // Handle backlog aliases
  if (["backlog", "open", "todo"].includes(normalized)) {
    return "backlog";
  }
  // Handle ready aliases
  if (["ready"].includes(normalized)) {
    return "ready";
  }
  // Try direct match to BOARD_STATUSES
  return normalizeStatusForBoard(normalized);
}

/**
 * Filter tasks to only include those in the specified board status column.
 */
function applyStatusFilter(tasks: BoardTask[], targetStatus: BoardStatus): BoardTask[] {
  return tasks.filter((task) => boardColumnForTaskStatus(task.status) === targetStatus);
}

export async function loadBoardTasks(projectPath: string, options: { filter?: string } = {}): Promise<Map<BoardStatus, BoardTask[]>> {
  const context = await resolveBoardContext(projectPath);
  const rows = context.backend === "elixir"
    ? (await context.client.listTasks())
        .filter((task) => task.project_id === context.projectId)
        .map(boardTaskFromElixir)
    : (await context.client.tasks.list({ projectId: context.projectId, limit: 1000 }) as TaskRow[])
        .map(boardTaskFromRow);

  const map = new Map<BoardStatus, BoardTask[]>();
  for (const status of BOARD_STATUSES) {
    map.set(status, []);
  }

  // Apply status filter if specified
  const targetStatus = resolveFilterToBoardStatus(options.filter);
  const filteredRows = targetStatus !== null
    ? applyStatusFilter(rows, targetStatus)
    : rows;

  for (const row of filteredRows) {
    const status = boardColumnForTaskStatus(row.status);
    map.get(status)!.push(row);
  }

  return map;
}

export async function loadBoardTask(projectPath: string, taskId: string): Promise<BoardTask | null> {
  const context = await resolveBoardContext(projectPath);
  if (context.backend === "elixir") {
    const row = await context.client.getTask(taskId);
    if (!row || (row.project_id && row.project_id !== context.projectId)) return null;
    return boardTaskFromElixir(row);
  }
  const row = await context.client.tasks.get({ projectId: context.projectId, taskId }) as TaskRow | null;
  return row ? boardTaskFromRow(row) : null;
}

interface BoardInboxMessageRow {
  id: string;
  run_id: string;
  created_at: string;
}

interface BoardRunRow {
  id: string;
  task_id?: string | null;
}

export interface BoardInboxUpdateResult {
  taskIds: string[];
  newestId: string | null;
}

export async function pollBoardInboxTaskUpdates(
  projectPath: string,
  lastSeenId: string | null,
  limit = 100,
  cursorTasked = lastSeenId !== null,
): Promise<BoardInboxUpdateResult> {
  const context = await resolveBoardContext(projectPath);
  if (context.backend === "elixir") {
    return { taskIds: [], newestId: lastSeenId };
  }

  const { client, projectId } = context;
  const rows = await client.mail.listGlobal({ projectId, limit }) as BoardInboxMessageRow[];
  const newestId = rows[rows.length - 1]?.id ?? null;

  if (!cursorTasked) {
    return { taskIds: [], newestId };
  }

  const lastSeenIndex = lastSeenId ? rows.findIndex((row) => row.id === lastSeenId) : -1;
  const newRows = lastSeenId && lastSeenIndex >= 0 ? rows.slice(lastSeenIndex + 1) : rows;
  const runIds = [...new Set(newRows.map((row) => row.run_id).filter(Boolean))];
  const taskIds = new Set<string>();

  for (const runId of runIds) {
    const run = await client.runs.get({ runId }) as BoardRunRow | null;
    const taskId = run?.task_id ?? run?.task_id ?? null;
    if (taskId) taskIds.add(taskId);
  }

  return { taskIds: [...taskIds], newestId };
}

export function applyBoardTaskUpdate(
  taskMap: Map<BoardStatus, BoardTask[]>,
  task: BoardTask | null,
  taskId: string,
  sortMode: SortMode,
): Map<BoardStatus, BoardTask[]> {
  const next = new Map<BoardStatus, BoardTask[]>();
  for (const [status, tasks] of taskMap) {
    next.set(status, tasks.filter((candidate) => candidate.id !== taskId));
  }

  if (task) {
    const status = boardColumnForTaskStatus(task.status);
    next.get(status)!.push(task);
    next.set(status, sortBoardTasks(next.get(status)!, sortMode));
  }

  return next;
}

export async function refreshBoardTasksById(
  projectPath: string,
  taskMap: Map<BoardStatus, BoardTask[]>,
  taskIds: Iterable<string>,
  sortMode: SortMode,
): Promise<Map<BoardStatus, BoardTask[]>> {
  let next = taskMap;
  for (const taskId of taskIds) {
    const task = await loadBoardTask(projectPath, taskId);
    next = applyBoardTaskUpdate(next, task, taskId, sortMode);
  }
  return next;
}

export interface BoardTaskSnapshotUpdateResult {
  taskIds: string[];
  tasks: Map<BoardStatus, BoardTask[]>;
}

function boardTaskSignature(task: BoardTask): string {
  return [
    task.id,
    task.status,
    task.updated_at,
    task.title,
    task.priority,
    task.run_id ?? "",
    task.phase_id ?? "",
  ].join("\u0000");
}

function flattenBoardTasks(taskMap: Map<BoardStatus, BoardTask[]>): Map<string, BoardTask> {
  const flattened = new Map<string, BoardTask>();
  for (const rows of taskMap.values()) {
    for (const task of rows) flattened.set(task.id, task);
  }
  return flattened;
}

export function diffBoardTaskSnapshots(
  previousTasks: Map<BoardStatus, BoardTask[]>,
  nextTasks: Map<BoardStatus, BoardTask[]>,
): string[] {
  const previous = flattenBoardTasks(previousTasks);
  const next = flattenBoardTasks(nextTasks);
  const changed = new Set<string>();

  for (const [taskId, task] of next) {
    const prior = previous.get(taskId);
    if (!prior || boardTaskSignature(prior) !== boardTaskSignature(task)) {
      changed.add(taskId);
    }
  }

  for (const taskId of previous.keys()) {
    if (!next.has(taskId)) changed.add(taskId);
  }

  return [...changed];
}

export async function pollBoardTaskSnapshotUpdates(
  projectPath: string,
  currentTasks: Map<BoardStatus, BoardTask[]>,
  sortMode: SortMode,
): Promise<BoardTaskSnapshotUpdateResult> {
  const loaded = sortBoardColumns(await loadBoardTasks(projectPath), sortMode);
  return { taskIds: diffBoardTaskSnapshots(currentTasks, loaded), tasks: loaded };
}

export async function loadBoardTaskNotes(projectPath: string, taskId: string): Promise<BoardTaskNote[]> {
  const context = await resolveBoardContext(projectPath);
  if (context.backend === "elixir") {
    const task = await context.client.getTask(taskId);
    return (task?.annotations ?? []).slice(-10).map((note, index) => ({
      id: `${taskId}-annotation-${index}`,
      created_at: note.created_at ?? new Date().toISOString(),
      phase: null,
      kind: "note",
      author: note.author ?? "unknown",
      body: note.body,
    }));
  }

  const notes = await context.client.tasks.listNotes({
    projectId: context.projectId,
    taskId,
    limit: 10,
    newestFirst: true,
  }) as TaskNoteRow[];

  return [...notes].reverse().map((note) => ({
    id: note.id,
    created_at: note.created_at,
    phase: note.phase,
    kind: note.kind,
    author: note.author,
    body: note.body,
  }));
}

// ── ANSI rendering helpers ────────────────────────────────────────────────────

/** Clear the entire screen and move cursor to top-left. */
const CLEAR_SCREEN = "\x1B[2J\x1B[H";

/** Hide the cursor. */
const HIDE_CURSOR = "\x1b[?25l";

/** Show the cursor. */
const SHOW_CURSOR = "\x1b[?25h";

/** Get the terminal width. */
export function getTerminalWidth(): number {
  return process.stdout.columns || 80;
}

/** Get the terminal height. */
function getTerminalHeight(): number {
  return process.stdout.rows || 24;
}

/**
 * Clamp a value to [min, max] inclusive.
 */
function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

// ── Board renderer ────────────────────────────────────────────────────────────

const MIN_COL_WIDTH = 12;
const MAX_VISIBLE_PER_COL = 5;
const COLUMN_GAP = 1;
const h = createElement;

export function getVisibleStatuses(
  terminalWidth: number,
  selectedColIndex: number,
): readonly BoardStatus[] {
  const maxHeaderLen = Math.max(...BOARD_STATUSES.map((status) => STATUS_LABELS[status].length + 5));
  const minColWidth = Math.max(maxHeaderLen, MIN_COL_WIDTH);
  const maxCols = Math.max(
    1,
    Math.floor((Math.max(terminalWidth, minColWidth) + COLUMN_GAP) / (minColWidth + COLUMN_GAP)),
  );

  if (maxCols >= BOARD_STATUSES.length) {
    return BOARD_STATUSES;
  }

  const windowSize = Math.max(1, Math.min(maxCols, BOARD_STATUSES.length));
  const maxStart = BOARD_STATUSES.length - windowSize;
  const start = clamp(selectedColIndex - Math.floor(windowSize / 2), 0, maxStart);
  return BOARD_STATUSES.slice(start, start + windowSize);
}

function getColumnWidth(terminalWidth: number, columnCount: number): number {
  if (columnCount <= 0) {
    return terminalWidth;
  }

  const availableWidth = Math.max(
    MIN_COL_WIDTH * columnCount + COLUMN_GAP * (columnCount - 1),
    terminalWidth,
  );
  return Math.max(
    MIN_COL_WIDTH,
    Math.floor((availableWidth - COLUMN_GAP * (columnCount - 1)) / columnCount),
  );
}

export interface VisibleTaskWindow {
  startIndex: number;
  visibleTasks: BoardTask[];
  hiddenBefore: number;
  hiddenAfter: number;
}

export function getVisibleTaskCapacity(
  columnHeight: number,
  taskCount: number,
  userLimit?: number,
): number {
  const reservedLines = 3; // top border + bottom border + header
  const overflowReserve = taskCount > 0 ? 2 : 0; // room for scroll indicators when needed
  const availableTaskLines = Math.max(2, columnHeight - reservedLines - overflowReserve);
  const autoCapacity = Math.max(1, Math.floor(availableTaskLines / 2));
  return userLimit == null ? autoCapacity : Math.max(1, Math.min(userLimit, autoCapacity));
}

export function getVisibleTaskWindow(
  tasks: readonly BoardTask[],
  selectedIndex: number,
  maxVisiblePerCol: number,
): VisibleTaskWindow {
  if (tasks.length <= maxVisiblePerCol) {
    return {
      startIndex: 0,
      visibleTasks: [...tasks],
      hiddenBefore: 0,
      hiddenAfter: 0,
    };
  }

  const maxStartIndex = Math.max(0, tasks.length - maxVisiblePerCol);
  const startIndex = clamp(selectedIndex - Math.floor(maxVisiblePerCol / 2), 0, maxStartIndex);
  const endIndex = startIndex + maxVisiblePerCol;

  return {
    startIndex,
    visibleTasks: tasks.slice(startIndex, endIndex),
    hiddenBefore: startIndex,
    hiddenAfter: Math.max(0, tasks.length - endIndex),
  };
}

function renderEmptyTaskSlot(): ReturnType<typeof h> {
  return h(
    Box,
    { flexDirection: "column", width: "100%" },
    h(Text, { dimColor: true }, " "),
    h(Text, { dimColor: true }, " "),
  );
}

/**
 * Returns the number of physical lines a task card occupies when rendered
 * at the given column width. Uses renderToString to measure actual height.
 */
function getCardLineCount(task: BoardTask, columnWidth: number): number {
  const card = renderTaskCardView(task, false, false);
  const rendered = renderToString(card, { columns: columnWidth });
  return rendered.split("\n").length;
}

function renderTaskCardView(
  task: BoardTask,
  isSelected: boolean,
  isFlash: boolean,
): ReturnType<typeof h> {
  const badge = PRIORITY_BADGES[task.priority] ?? "P?";
  const badgeStyle = PRIORITY_COLORS[task.priority] ?? PRIORITY_COLORS[4];
  const rowBackgroundColor = isFlash ? "green" : isSelected ? "cyan" : undefined;
  const rowTextColor = rowBackgroundColor ? "black" : "white";
  const metaTextColor = rowBackgroundColor ? "black" : "white";
  const phaseText = task.phase_id ? `phase: ${task.phase_id}` : task.status;

  return h(
    Box,
    { flexDirection: "column", width: "100%" },
    h(
      Box,
      { width: "100%", backgroundColor: rowBackgroundColor },
      h(Text, { color: rowTextColor }, `${isSelected || isFlash ? "▶" : " "} `),
      h(
        Box,
        { flexGrow: 1, minWidth: 0 },
        h(Text, { color: rowTextColor, wrap: "truncate-end" }, task.title),
      ),
      h(
        Text,
        {
          color: badgeStyle.textColor,
          backgroundColor: badgeStyle.backgroundColor,
        },
        ` ${badge} `,
      ),
    ),
    h(
      Box,
      { width: "100%", backgroundColor: rowBackgroundColor },
      h(
        Box,
        { width: "50%", minWidth: 0 },
        h(
          Text,
          { color: metaTextColor, dimColor: !rowBackgroundColor, wrap: "truncate-end" },
          formatTaskIdDisplay(task.id),
        ),
      ),
      h(
        Box,
        { width: "50%", minWidth: 0 },
        h(Text, { color: metaTextColor, dimColor: !rowBackgroundColor, wrap: "truncate-end" }, phaseText),
      ),
    ),
  );
}

function renderBoardColumn(
  status: BoardStatus,
  absoluteIndex: number,
  state: RenderState,
  columnWidth: number,
  columnHeight: number,
  userVisibleLimit?: number,
): ReturnType<typeof h> {
  const tasks = state.tasks.get(status) ?? [];
  const isSelectedColumn = absoluteIndex === state.nav.colIndex;
  const visibleLimit = getVisibleTaskCapacity(columnHeight, tasks.length, userVisibleLimit);
  const taskWindow = getVisibleTaskWindow(tasks, isSelectedColumn ? state.nav.rowIndex : 0, visibleLimit);

  // Calculate line budget for cards (column height minus border top, border bottom, and header)
  const reservedLines = 3;
  const lineBudget = Math.max(0, columnHeight - reservedLines);

  const slots: Array<ReturnType<typeof h>> = [];
  let usedLines = 0;
  let tasksShown = 0;

  if (taskWindow.hiddenBefore > 0) {
    slots.push(
      h(
        Text,
        { dimColor: true, wrap: "truncate-end" },
        `↑ ${taskWindow.hiddenBefore} earlier`,
      ),
    );
    usedLines += 1;
  }

  for (let index = 0; index < visibleLimit; index += 1) {
    const task = taskWindow.visibleTasks[index];
    if (!task) {
      // Only add empty slot if it fits in budget
      if (usedLines + 2 <= lineBudget) {
        slots.push(renderEmptyTaskSlot());
        usedLines += 2;
        tasksShown += 1;
      }
      continue;
    }

    const cardLineCount = getCardLineCount(task, columnWidth);

    // Reserve one row for the overflow marker when hidden tasks may remain
    const hasPotentialOverflow =
      taskWindow.hiddenAfter > 0 || index < taskWindow.visibleTasks.length - 1;
    const overflowReserve = hasPotentialOverflow ? 1 : 0;

    // Stop if adding this card would exceed line budget
    if (usedLines + cardLineCount + overflowReserve > lineBudget) {
      break;
    }

    slots.push(
      renderTaskCardView(
        task,
        isSelectedColumn && taskWindow.startIndex + index === state.nav.rowIndex,
        task.id === state.flashTaskId,
      ),
    );
    usedLines += cardLineCount;
    tasksShown += 1;
  }

  // Calculate actual hiddenAfter based on how many tasks we actually showed
  const visibleTasksNotShown = taskWindow.visibleTasks.length - tasksShown;
  const actualHiddenAfter = taskWindow.hiddenAfter + visibleTasksNotShown;

  if (actualHiddenAfter > 0) {
    slots.push(h(Text, { dimColor: true, wrap: "truncate-end" }, `↓ ${actualHiddenAfter} more`));
  }

  return h(
    Box,
    {
      borderStyle: "round",
      borderColor: isSelectedColumn ? "cyan" : "gray",
      flexDirection: "column",
      height: columnHeight,
      overflow: "hidden",
      paddingX: 1,
      width: columnWidth,
    },
    h(
      Text,
      {
        bold: true,
        color: isSelectedColumn ? "cyan" : "white",
        wrap: "truncate-end",
      },
      `${STATUS_LABELS[status]} (${tasks.length})`,
    ),
    ...slots,
  );
}

function renderHelpOverlayView(width: number): ReturnType<typeof h> {
  const panelWidth = Math.max(24, Math.min(72, width));
  const keyWidth = Math.max(8, Math.floor(panelWidth * 0.35));
  const rows: Array<[string, string]> = [
    ["j / k", "Move up / down in column"],
    ["h / l", "Move left / right between columns"],
    ["g / G", "Jump to first / last task"],
    ["[1]…[5]", "Jump to column by number"],
    ["s / S", "Cycle status forward / backward"],
    ["o", "Toggle sort: updated / priority"],
    ["R", "Mark task as ready"],
    ["c", "Close task"],
    ["C", "Close task with reason"],
    ["e / E", "Edit task in editor"],
    ["y", "Copy selected task ID"],
    ["n", "Create new task"],
    ["Enter", "Show task detail"],
    ["Esc", "Dismiss help / detail"],
    ["r", "Refresh board from store"],
    ["q", "Quit board"],
  ];

  return h(
    Box,
    { borderStyle: "round", borderColor: "yellow", flexDirection: "column", width: panelWidth },
    h(Text, { color: "yellow", bold: true }, "HELP — Key Bindings"),
    ...rows.map(([keyLabel, description]) =>
      h(
        Box,
        { key: `${keyLabel}:${description}`, width: "100%" },
        h(
          Box,
          { width: keyWidth, minWidth: 0 },
          h(Text, { color: "cyan", wrap: "truncate-end" }, keyLabel),
        ),
        h(
          Box,
          { flexGrow: 1, minWidth: 0 },
          h(Text, { wrap: "truncate-end" }, description),
        ),
      )),
    h(Text, { dimColor: true }, "Press ? or Esc to close"),
  );
}

function renderTaskDetailView(
  task: BoardTask,
  width: number,
  notesStatus: RenderState["detailNotesStatus"],
  notesError: string | null,
  terminalHeight?: number,
): ReturnType<typeof h> {
  // Use substantially more terminal real estate while never exceeding available width.
  const availableWidth = Math.max(8, width - 4);
  const preferredWidth = Math.max(50, Math.floor(width * 0.9));
  const panelWidth = Math.min(preferredWidth, availableWidth);
  const panelHeight = terminalHeight ? Math.max(8, terminalHeight - 2) : undefined;
  const fieldWidth = Math.max(8, Math.min(16, Math.floor(panelWidth * 0.2)));

  const rows: Array<[string, string | null]> = [
    ["ID:", task.id],
    ["Title:", task.title],
    ["Type:", task.type],
    ["Priority:", `${priorityLabel(task.priority)} (P${task.priority})`],
    ["Status:", task.status],
    ["Phase:", task.phase_id ?? null],
    ["External ID:", task.external_id],
    ["Created:", new Date(task.created_at).toLocaleString()],
    ["Updated:", new Date(task.updated_at).toLocaleString()],
    ["Approved:", task.approved_at ? new Date(task.approved_at).toLocaleString() : null],
    ["Closed:", task.closed_at ? new Date(task.closed_at).toLocaleString() : null],
  ];

  const children: Array<ReturnType<typeof h>> = [
    h(Text, { key: "detail-title", color: "blue", bold: true }, `TASK DETAIL — ${task.status}`),
  ];

  if (task.description) {
    const [firstLine, ...rest] = task.description.split("\n");
    children.push(
      h(
        Box,
        { key: "desc:first", width: "100%" },
        h(
          Box,
          { width: fieldWidth, minWidth: 0 },
          h(Text, { bold: true, wrap: "wrap" }, "Description:"),
        ),
        h(
          Box,
          { flexGrow: 1, minWidth: 0 },
          h(Text, { wrap: "wrap" }, firstLine ?? ""),
        ),
      ),
    );

    // Show all description lines with wrapping (no line limit)
    for (const [index, line] of rest.entries()) {
      children.push(
        h(
          Box,
          { key: `desc:${index}`, width: "100%" },
          h(Box, { width: fieldWidth }, h(Text, null, " ")),
          h(
            Box,
            { flexGrow: 1, minWidth: 0 },
            h(Text, { dimColor: true, wrap: "wrap" }, line),
          ),
        ),
      );
    }
  }

  for (const [label, value] of rows) {
    if (!value) {
      continue;
    }

    children.push(
      h(
        Box,
        { key: label, width: "100%" },
        h(
          Box,
          { width: fieldWidth, minWidth: 0 },
          h(Text, { bold: true, wrap: "wrap" }, label),
        ),
        h(
          Box,
          { flexGrow: 1, minWidth: 0 },
          h(Text, { wrap: "wrap" }, value),
        ),
      ),
    );
  }

  if (notesStatus === "loading") {
    children.push(h(Text, { key: "notes-loading", dimColor: true }, "Notes: loading…"));
  } else if (notesStatus === "error") {
    children.push(
      h(
        Text,
        { key: "notes-error", dimColor: true },
        `Notes: unavailable${notesError ? ` (${notesError})` : ""}`,
      ),
    );
  } else if (task.notes) {
    if (task.notes.length === 0) {
      children.push(h(Text, { key: "notes-empty", dimColor: true }, "Notes: none yet"));
    } else {
      children.push(h(Text, { key: "notes-title", bold: true }, "Notes:"));
      // Show all notes with wrapping (no item limit)
      for (const [noteIndex, note] of task.notes.entries()) {
        const when = new Date(note.created_at).toLocaleString();
        const phase = note.phase ? `${note.phase} ` : "";
        children.push(
          h(
            Text,
            { key: `note:${note.id}:meta`, dimColor: true, wrap: "wrap" },
            `[${when} ${phase}${note.kind}] ${note.author}`,
          ),
        );
        // Show all lines of note body with wrapping
        for (const [lineIndex, line] of note.body.split("\n").entries()) {
          children.push(
            h(
              Text,
              { key: `note:${note.id}:body:${lineIndex}`, wrap: "wrap" },
              line,
            ),
          );
        }
      }
    }
  }

  const contentLimit = panelHeight ? Math.max(1, panelHeight - 3) : undefined;
  const hasHiddenContent = contentLimit !== undefined && children.length > contentLimit;
  const visibleChildren = hasHiddenContent ? children.slice(0, contentLimit) : children;

  if (hasHiddenContent) {
    visibleChildren.push(h(Text, { key: "detail-more", dimColor: true }, "↓ more content"));
  }
  visibleChildren.push(h(Text, { key: "detail-hint", dimColor: true }, "Press Enter or Esc to close"));

  return h(
    Box,
    { borderStyle: "round", borderColor: "blue", flexDirection: "column", width: panelWidth, height: panelHeight },
    ...visibleChildren,
  );
}

const REFRESH_SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

function renderBoardStatusText(state: RenderState, totalTasks: number): string {
  const base = `${totalTasks} task${totalTasks === 1 ? "" : "s"} · Sort: ${SORT_MODE_LABELS[state.sortMode]}`;
  if (state.refreshStatus === "refreshing") {
    const frame = REFRESH_SPINNER_FRAMES[(state.refreshSpinnerFrame ?? 0) % REFRESH_SPINNER_FRAMES.length];
    return `${frame} refreshing… · ${base}`;
  }
  if (state.refreshStatus === "refreshed" && state.refreshedAt) {
    return `✓ refreshed ${state.refreshedAt} · ${base}`;
  }
  return base;
}

function renderBoardFrame(
  state: RenderState,
  projectName: string,
  terminalWidth: number,
  terminalHeight: number,
  userVisibleLimit?: number,
): string {
  const totalTasks = state.totalTasks;
  const visibleStatuses = getVisibleStatuses(terminalWidth, state.nav.colIndex);
  const columnWidth = getColumnWidth(terminalWidth, visibleStatuses.length);

  // Help overlay uses 16 rows; board footer uses 5 rows
  const reservedRows = 5 + (state.errorMessage ? 2 : 0) + (state.showHelp ? 16 : 0);
  const columnHeight = Math.max(8, terminalHeight - reservedRows);

  // Build the board content (header + columns + footer)
  const boardContent: Array<ReturnType<typeof h>> = [
    h(
      Box,
      { width: "100%", marginBottom: 1 },
      h(Text, { color: "blue", bold: true, wrap: "truncate-end" }, `Foreman Kanban Board — ${projectName}`),
      h(Spacer, null),
      h(
        Text,
        { dimColor: state.refreshStatus !== "refreshing", color: state.refreshStatus === "refreshing" ? "cyan" : undefined },
        renderBoardStatusText(state, totalTasks),
      ),
    ),
    h(
      Box,
      { flexDirection: "row", gap: COLUMN_GAP, marginBottom: 1, width: "100%" },
      ...visibleStatuses.map((status) => {
        const absoluteIndex = BOARD_STATUSES.indexOf(status);
        return h(
          Box,
          { key: `jump:${status}`, width: columnWidth, minWidth: columnWidth },
          h(
            Text,
            {
              color: absoluteIndex === state.nav.colIndex ? "cyan" : undefined,
              bold: absoluteIndex === state.nav.colIndex,
              wrap: "truncate-end",
            },
            `[${absoluteIndex + 1}] ${STATUS_LABELS[status]}`,
          ),
        );
      }),
    ),
    h(
      Box,
      { flexDirection: "row", gap: COLUMN_GAP, alignItems: "flex-start", width: "100%" },
      ...visibleStatuses.map((status) => {
        const absoluteIndex = BOARD_STATUSES.indexOf(status);
        return h(
          Box,
          { key: `column:${status}`, width: columnWidth, minWidth: columnWidth, height: columnHeight },
          renderBoardColumn(status, absoluteIndex, state, columnWidth, columnHeight, userVisibleLimit),
        );
      }),
    ),
    h(Text, { dimColor: true }, "j/k up/down  h/l left/right  o sort  s/S cycle status  R mark ready  c/C close  e/E edit  y copy id  n new  Enter detail  ? help  r refresh  q quit"),
  ];

  // Add error message if present
  if (state.errorMessage) {
    boardContent.push(
      h(
        Box,
        { marginTop: 1 },
        h(Text, { color: "red", bold: true }, "ERROR "),
        h(Text, { color: "red", wrap: "truncate-end" }, state.errorMessage),
      ),
    );
  }

  // When help is shown, render help overlay at bottom (existing behavior)
  if (state.showHelp) {
    const tree = h(
      Box,
      { flexDirection: "column", width: terminalWidth },
      ...boardContent,
      h(Box, { marginTop: 1 }, renderHelpOverlayView(Math.max(24, terminalWidth - 2))),
    );
    return renderToString(tree, { columns: terminalWidth });
  }

  const tree = h(
    Box,
    { flexDirection: "column", width: terminalWidth },
    ...boardContent,
  );

  return renderToString(tree, { columns: terminalWidth });
}

/**
 * Render the full kanban board to a string and write it to stdout,
 * leaving the cursor just below the board.
 *
 * Layout (top to bottom):
 *   1. Header: project name + total task count
 *   2. Column number row: [1] Backlog  [2] Ready ...
 *   3. Column headers (name + count)
 *   4. Task cards (scrollable within column to 5 visible, +N more)
 *   5. Footer: keybindings hint
 */
export function renderBoard(
  state: RenderState,
  projectName: string,
  terminalWidth: number,
  userVisibleLimit?: number,
  terminalHeight = getTerminalHeight(),
): string {
  // When detail is shown, render it as a true overlay (full screen) on top of the board
  // This gives the detail panel substantially more real estate than inline rendering
  if (state.showDetail && state.detailTask) {
    return `${CLEAR_SCREEN}${renderTaskDetail(
      state.detailTask,
      terminalWidth,
      state.detailNotesStatus,
      state.detailNotesError,
      terminalHeight,
    )}`;
  }
  return `${CLEAR_SCREEN}${renderBoardFrame(state, projectName, terminalWidth, terminalHeight, userVisibleLimit)}`;
}

/**
 * Render the help overlay panel.
 */
export function renderHelpOverlay(width: number): string {
  return renderToString(renderHelpOverlayView(width), { columns: width });
}

/**
 * Render the task detail panel (full metadata).
 */
export function renderTaskDetail(
  task: BoardTask,
  width: number,
  notesStatus: RenderState["detailNotesStatus"] = "idle",
  notesError: string | null = null,
  terminalHeight?: number,
): string {
  return renderToString(renderTaskDetailView(task, width, notesStatus, notesError, terminalHeight), { columns: width });
}

// ── Editor integration ───────────────────────────────────────────────────────

/** Resolve the $EDITOR environment variable with fallbacks. */
export function resolveEditor(): string {
  const editor = process.env.EDITOR ?? process.env.VISUAL;
  if (editor) return editor;
  // Check which editors are available on PATH
  for (const candidate of ["vim", "nvim", "nano", "vi", "emacs"]) {
    try {
      require("node:child_process").execFileSync(candidate, ["--version"], {
        stdio: "ignore",
      });
      return candidate;
    } catch {
      // not available
    }
  }
  return "vi";
}

/**
 * Open the task YAML in $EDITOR and return the parsed content on success.
 * On error or non-zero exit, returns null and sets errorMessage.
 */
export function editTaskInEditor(
  task: BoardTask,
  fullSchema: boolean,
  onError: (msg: string) => void,
): BoardTask | null {
  const editor = resolveEditor();
  const tmpFile = joinPath(tmpdir(), `foreman-task-${randomUUID()}.yaml`);

  // Build YAML document
  const doc: Record<string, unknown> = {
    id: task.id,
    title: task.title,
    description: task.description ?? "",
    type: task.type,
    priority: task.priority,
    status: task.status,
  };

  if (fullSchema) {
    doc.external_id = task.external_id ?? null;
    doc.created_at = task.created_at;
    doc.updated_at = task.updated_at;
    doc.approved_at = task.approved_at;
    doc.closed_at = task.closed_at;
    doc.phase_id = task.phase_id ?? null;
  }

  try {
    writeFileSync(tmpFile, yaml.dump(doc), "utf8");
  } catch (err) {
    onError(`Failed to write temp file: ${err instanceof Error ? err.message : String(err)}`);
    return null;
  }

  let exitCode = 0;
  try {
    exitCode = spawnSync(editor, [tmpFile], {
      stdio: "inherit",
      shell: true,
    }).status ?? 0;
  } catch (err) {
    onError(`Failed to launch editor '${editor}': ${err instanceof Error ? err.message : String(err)}`);
    try { unlinkSync(tmpFile); } catch { /* ignore */ }
    return null;
  }

  if (exitCode !== 0) {
    onError(`Editor exited with code ${exitCode} — changes discarded.`);
    try { unlinkSync(tmpFile); } catch { /* ignore */ }
    return null;
  }

  try {
    const raw = readFileSync(tmpFile, "utf8");
    const parsed = yaml.load(raw) as Record<string, unknown>;

    // Validate required fields
    if (!parsed.id || typeof parsed.title !== "string") {
      onError("YAML must include id and title fields.");
      try { unlinkSync(tmpFile); } catch { /* ignore */ }
      return null;
    }

    // Reconstitute a BoardTask (filter unknown fields)
    const updated: BoardTask = {
      id: String(parsed.id),
      title: String(parsed.title),
      description: typeof parsed.description === "string" ? parsed.description : null,
      type: typeof parsed.type === "string" ? parsed.type : task.type,
      priority: typeof parsed.priority === "number" ? clamp(parsed.priority, 0, 4) : task.priority,
      status: typeof parsed.status === "string" ? parsed.status : task.status,
      external_id: typeof parsed.external_id === "string" ? parsed.external_id : task.external_id,
      created_at: typeof parsed.created_at === "string" ? parsed.created_at : task.created_at,
      updated_at: typeof parsed.updated_at === "string" ? parsed.updated_at : task.updated_at,
      approved_at: typeof parsed.approved_at === "string" ? parsed.approved_at : task.approved_at,
      closed_at: typeof parsed.closed_at === "string" ? parsed.closed_at : task.closed_at,
      phase_id: typeof parsed.phase_id === "string" ? parsed.phase_id : task.phase_id,
    };

    try { unlinkSync(tmpFile); } catch { /* ignore */ }
    return updated;
  } catch (err) {
    onError(`Failed to parse YAML: ${err instanceof Error ? err.message : String(err)}`);
    try { unlinkSync(tmpFile); } catch { /* ignore */ }
    return null;
  }
}

// ── Store mutation helpers ────────────────────────────────────────────────────

/**
 * Write a status change to the store.
 */
export function applyStatusChange(projectPath: string, taskId: string, newStatus: string): string | null {
  throw new Error("applyStatusChange is now async; use applyStatusChangeAsync().");
}

async function sendElixirBoardCommand(
  client: ElixirServerClient,
  commandType: string,
  payload: Record<string, unknown>,
): Promise<void> {
  const commandId = `board-${commandType}-${randomUUID()}`;
  const response = await client.sendCommand({
    command_id: commandId,
    command_type: commandType,
    payload,
    metadata: { correlation_id: commandId, source: "foreman-board" },
  });
  if (!response.ok) throw new Error(response.error.message);
}

export async function applyStatusChangeAsync(projectPath: string, taskId: string, newStatus: string): Promise<string | null> {
  try {
    const context = await resolveBoardContext(projectPath);
    if (context.backend === "elixir") {
      await sendElixirBoardCommand(context.client, "task.update", { project_id: context.projectId, task_id: taskId, status: newStatus });
    } else {
      await context.client.tasks.update({ projectId: context.projectId, taskId, updates: { status: newStatus } });
    }
    return null;
  } catch (err) {
    return err instanceof Error ? err.message : String(err);
  }
}

/**
 * Close a task (status → closed, optionally with a reason stored in closed_at).
 */
export function closeTask(projectPath: string, taskId: string, reason?: string): string | null {
  throw new Error("closeTask is now async; use closeTaskAsync().");
}

export async function closeTaskAsync(projectPath: string, taskId: string, _reason?: string): Promise<string | null> {
  try {
    const context = await resolveBoardContext(projectPath);
    if (context.backend === "elixir") {
      await sendElixirBoardCommand(context.client, "task.close", { project_id: context.projectId, task_id: taskId });
    } else {
      await context.client.tasks.close({ projectId: context.projectId, taskId });
    }
    return null;
  } catch (err) {
    return err instanceof Error ? err.message : String(err);
  }
}

/**
 * Save an edited task back to the store (title, description, priority, status).
 */
export function saveEditedTask(projectPath: string, originalId: string, updated: BoardTask): string | null {
  throw new Error("saveEditedTask is now async; use saveEditedTaskAsync().");
}

export async function saveEditedTaskAsync(projectPath: string, originalId: string, updated: BoardTask): Promise<string | null> {
  try {
    const context = await resolveBoardContext(projectPath);
    const updates = {
      title: updated.title,
      description: updated.description ?? undefined,
      priority: updated.priority,
      status: updated.status,
    };
    if (context.backend === "elixir") {
      await sendElixirBoardCommand(context.client, "task.update", { project_id: context.projectId, task_id: originalId, ...updates });
    } else {
      await context.client.tasks.update({
        projectId: context.projectId,
        taskId: originalId,
        updates,
      });
    }
    return null;
  } catch (err) {
    return err instanceof Error ? err.message : String(err);
  }
}

/** Copy text to the system clipboard using the platform clipboard command. */
export function copyToClipboard(text: string): string | null {
  const candidates = process.platform === "darwin"
    ? [{ command: "pbcopy", args: [] }]
    : process.platform === "win32"
      ? [{ command: "clip", args: [] }]
      : [
          { command: "wl-copy", args: [] },
          { command: "xclip", args: ["-selection", "clipboard"] },
          { command: "xsel", args: ["--clipboard", "--input"] },
        ];

  const errors: string[] = [];
  for (const candidate of candidates) {
    const result = spawnSync(candidate.command, candidate.args, {
      input: text,
      encoding: "utf8",
      stdio: ["pipe", "ignore", "pipe"],
    });

    if (!result.error && result.status === 0) {
      return null;
    }

    const message = result.error instanceof Error
      ? result.error.message
      : result.stderr?.trim() || `exit ${result.status ?? "unknown"}`;
    errors.push(`${candidate.command}: ${message}`);
  }

  return `Failed to copy task ID to clipboard (${errors.join("; ")})`;
}

// ── Navigation ────────────────────────────────────────────────────────────────

/**
 * Normalize nav.rowIndex to be within the bounds of the current column.
 * If the column is empty, set rowIndex = 0.
 */
export function normalizeNavRowIndex(nav: NavigationState, tasks: Map<BoardStatus, BoardTask[]>): void {
  const currentTasks = tasks.get(BOARD_STATUSES[nav.colIndex]) ?? [];
  nav.rowIndex = clamp(nav.rowIndex, 0, Math.max(0, currentTasks.length - 1));
}

/**
 * Get the currently highlighted task, or null if the column is empty.
 */
export function getHighlightedTask(nav: NavigationState, tasks: Map<BoardStatus, BoardTask[]>): BoardTask | null {
  const currentTasks = tasks.get(BOARD_STATUSES[nav.colIndex]) ?? [];
  return currentTasks[nav.rowIndex] ?? null;
}

// ── Key handler ──────────────────────────────────────────────────────────────

/** Key codes. */
const KEY_ESC = "\x1B";
const KEY_ENTER = "\r";
const KEY_j = "j";
const KEY_k = "k";
const KEY_h = "h";
const KEY_l = "l";
const KEY_g = "g";
const KEY_G = "G";
const KEY_s = "s";
const KEY_S = "S";
const KEY_c = "c";
const KEY_C = "C";
const KEY_e = "e";
const KEY_E = "E";
const KEY_r = "r";
const KEY_R = "R";
const KEY_o = "o";
const KEY_q = "q";
const KEY_QUESTION = "?";
const KEY_n = "n";
const KEY_y = "y";

// ── New task editor template ────────────────────────────────────────────────

const VALID_TASK_TYPES = ["task", "bug", "feature", "epic", "chore", "docs", "question"] as const;
const TASK_TYPE_LABELS: Record<string, string> = {
  task: "task",
  bug: "bug",
  feature: "feature",
  epic: "epic",
  chore: "chore",
  docs: "docs",
  question: "question",
};

const VALID_PRIORITIES = [0, 1, 2, 3, 4] as const;
const PRIORITY_LABELS: Record<number, string> = {
  0: "0 (critical)",
  1: "1 (high)",
  2: "2 (medium)",
  3: "3 (low)",
  4: "4 (backlog)",
};

// Arrow key escape sequences (same mapping as board navigation)
const KEY_ARROW_UP = "\x1B[A";
const KEY_ARROW_DOWN = "\x1B[B";

/**
 * Interactive TTY dropdown selector using arrow keys and Enter.
 * Returns null if user presses Escape.
 */
async function selectFromDropdown(
  prompt: string,
  options: readonly string[],
  defaultIndex: number,
): Promise<{ value: string; index: number } | null> {
  if (options.length === 0) return null;

  let selectedIndex = defaultIndex;

  const render = () => {
    process.stdout.write("\r" + prompt + " ");
    for (let i = 0; i < options.length; i++) {
      if (i === selectedIndex) {
        process.stdout.write(chalk.inverse(` ${options[i]} `));
      } else {
        process.stdout.write(` ${options[i]} `);
      }
    }
    process.stdout.write(" (↑↓ navigate, Enter select, Esc cancel)");
  };

  // Initial render
  render();

  return new Promise((resolve) => {
    const onData = (chunk: Buffer) => {
      const cleanup = () => {
        process.stdin.removeListener("data", onData);
      };
      const key = chunk.toString("utf8");

      if (key === KEY_ARROW_UP) {
        selectedIndex = selectedIndex > 0 ? selectedIndex - 1 : options.length - 1;
        render();
      } else if (key === KEY_ARROW_DOWN) {
        selectedIndex = selectedIndex < options.length - 1 ? selectedIndex + 1 : 0;
        render();
      } else if (key === KEY_ENTER) {
        cleanup();
        process.stdout.write("\n");
        resolve({ value: options[selectedIndex], index: selectedIndex });
      } else if (key === KEY_ESC) {
        cleanup();
        process.stdout.write("\n");
        resolve(null);
      }
    };

    process.stdin.on("data", onData);
  });
}

/**
 * Interactive TTY form for creating a new task.
 * Prompts for title (text input), type (dropdown), and priority (dropdown).
 * Returns the parsed task data on success, or null if cancelled/failed.
 */
export async function createTaskInEditor(
  onError: (msg: string) => void,
): Promise<{ id?: string; title: string; description: string | null; type: string; priority: number; status: string } | null> {
  const wasRaw = process.stdin.isTTY && process.stdin.isRaw === true;
  // Suspend raw mode for interactive input
  if (process.stdin.isTTY && typeof process.stdin.setRawMode === "function") {
    try {
      process.stdin.setRawMode!(false);
    } catch {
      // ignore
    }
  }

  try {
    // Print form header
    process.stdout.write("\n" + chalk.bold("── Create New Task ──") + "\n");
    process.stdout.write(chalk.dim("Press Esc at any dropdown to cancel\n\n"));

    // Prompt for ID (optional)
    const idInput = await readLine("ID (optional, auto-generated if empty): ");
    const id = idInput.trim().length > 0 ? idInput.trim() : undefined;

    // Prompt for title
    const titleInput = await readLine("Title (required): ");
    if (titleInput.trim().length === 0) {
      onError("Title is required.");
      return null;
    }
    const title = titleInput.trim();

    // Prompt for description
    const descriptionInput = await readLine("Description (optional, press Enter to skip): ");
    const description = descriptionInput.trim().length > 0 ? descriptionInput.trim() : null;

    if (process.stdin.isTTY && typeof process.stdin.setRawMode === "function") {
      process.stdin.setRawMode!(true);
    }

    // Prompt for type using dropdown
    process.stdout.write(chalk.bold("\nTask Type:\n"));
    const typeResult = await selectFromDropdown(
      "Select type:",
      VALID_TASK_TYPES,
      0, // default: "task" at index 0
    );
    if (typeResult === null) {
      onError("Task creation cancelled.");
      return null;
    }
    const taskType = typeResult.value;

    // Prompt for priority using dropdown
    process.stdout.write(chalk.bold("\nTask Priority:\n"));
    const priorityOptions = VALID_PRIORITIES.map((p) => `${p} (${["critical", "high", "medium", "low", "backlog"][p]})`);
    const priorityResult = await selectFromDropdown(
      "Select priority:",
      priorityOptions,
      2, // default: "2 (medium)" at index 2
    );
    if (priorityResult === null) {
      onError("Task creation cancelled.");
      return null;
    }
    const priority = VALID_PRIORITIES[priorityResult.index];

    // Print summary
    process.stdout.write("\n" + chalk.bold("── Summary ──") + "\n");
    if (id) process.stdout.write(`  ID:          ${id}\n`);
    process.stdout.write(`  Title:       ${title}\n`);
    if (description) process.stdout.write(`  Description: ${description}\n`);
    process.stdout.write(`  Type:        ${taskType}\n`);
    process.stdout.write(`  Priority:    ${priority} (${["critical", "high", "medium", "low", "backlog"][priority]})\n`);
    process.stdout.write(`  Status:      backlog\n`);

    return {
      id,
      title,
      description,
      type: taskType,
      priority,
      status: "backlog",
    };
  } catch (err) {
    onError(`Failed to create task: ${err instanceof Error ? err.message : String(err)}`);
    return null;
  } finally {
    // Restore the raw-mode state this form entered with.
    if (process.stdin.isTTY && typeof process.stdin.setRawMode === "function") {
      try {
        process.stdin.setRawMode!(wasRaw);
      } catch {
        // ignore
      }
    }
  }
}

/**
 * Create a new task via the tRPC API.
 */
export async function createTaskAsync(
  projectPath: string,
  taskData: { id?: string; title: string; description?: string | null; type?: string; priority?: number; status?: string },
): Promise<{ taskId: string } | string> {
  try {
    const context = await resolveBoardContext(projectPath);
    const taskId = taskData.id || `task-${randomUUID().slice(0, 8)}`;
    if (context.backend === "elixir") {
      await sendElixirBoardCommand(context.client, "task.create", {
        project_id: context.projectId,
        task_id: taskId,
        title: taskData.title,
        description: taskData.description ?? undefined,
        task_type: taskData.type,
        priority: taskData.priority,
        status: taskData.status,
      });
      return { taskId };
    }

    const createInput: { projectId: string; id?: string; title: string; description?: string; type?: string; priority?: number; status?: string } = {
      projectId: context.projectId,
      title: taskData.title,
    };
    if (taskData.id) {
      createInput.id = taskData.id;
    }
    if (taskData.description !== undefined) {
      createInput.description = taskData.description ?? undefined;
    }
    if (taskData.type !== undefined) {
      createInput.type = taskData.type;
    }
    if (taskData.priority !== undefined) {
      createInput.priority = taskData.priority;
    }
    if (taskData.status !== undefined) {
      createInput.status = taskData.status;
    }
    const created = await context.client.tasks.create(createInput) as { id: string };
    return { taskId: created.id };
  } catch (err) {
    return err instanceof Error ? err.message : String(err);
  }
}

export const boardApi = {
  createTaskInEditor,
  createTaskAsync,
  applyStatusChangeAsync,
  loadTaskNotesAsync: loadBoardTaskNotes,
  closeTaskAsync,
  editTaskInEditor,
  saveEditedTaskAsync,
  copyToClipboard,
};

function suspendRawMode(): void {
  if (process.stdin.isTTY && typeof process.stdin.setRawMode === "function") {
    try {
      process.stdin.setRawMode(false);
    } catch {
      // ignore
    }
  }
}

function resumeRawMode(): void {
  if (process.stdin.isTTY && typeof process.stdin.setRawMode === "function") {
    try {
      process.stdin.setRawMode(true);
      process.stdin.resume();
      process.stdin.setEncoding("utf8");
    } catch {
      // ignore
    }
  }
}

export interface KeyHandlerResult {
  nav: NavigationState;
  errorMessage: string | null;
  flashTaskId: string | null;
  showHelp: boolean;
  showDetail: boolean;
  detailTask: BoardTask | null;
  /** If true, the board should be re-rendered after this handler. */
  needsRefresh: boolean;
  /** If true, the board should exit. */
  quit: boolean;
  /** If true, the caller should prompt for a close reason before closing. */
  promptForCloseReason: boolean;
  /** Close reason for C key */
  closeReason?: string;
  /** New sort mode, if toggled */
  sortMode?: SortMode;
}

export interface KeyHandlerCallbacks {
  onDetailNotesLoaded?: (
    taskId: string,
    notes: BoardTaskNote[] | null,
    error: string | null,
  ) => void;
}

export type KeyHandler = (
  key: string,
  state: RenderState,
  projectPath: string,
) => Promise<KeyHandlerResult>;

/**
 * Create the key handler closure that captures projectPath.
 */
export function createKeyHandler(projectPath: string, callbacks: KeyHandlerCallbacks = {}): KeyHandler {
  return async function handleKey(
    key: string,
    state: RenderState,
  ): Promise<KeyHandlerResult> {
    const result: KeyHandlerResult = {
      nav: { ...state.nav },
      errorMessage: null,
      flashTaskId: null,
      showHelp: state.showHelp,
      showDetail: state.showDetail,
      detailTask: state.detailTask,
      needsRefresh: false,
      quit: false,
      promptForCloseReason: false,
    };

    // Dismiss overlays on any key when shown
    if (state.showHelp) {
      if (key === KEY_ESC || key === KEY_QUESTION) {
        result.showHelp = false;
        result.needsRefresh = true;
      }
      return result;
    }

    if (state.showDetail) {
      if (key === KEY_ESC || key === KEY_ENTER) {
        result.showDetail = false;
        result.detailTask = null;
      }
      return result;
    }

    switch (key) {
      // ── Navigation ─────────────────────────────────────────────────────────
      case KEY_j: {
        const currentTasks = state.tasks.get(BOARD_STATUSES[result.nav.colIndex]) ?? [];
        if (currentTasks.length > 0) {
          result.nav.rowIndex = (result.nav.rowIndex + 1) % currentTasks.length;
        }
        break;
      }
      case KEY_k: {
        const currentTasks = state.tasks.get(BOARD_STATUSES[result.nav.colIndex]) ?? [];
        if (currentTasks.length > 0) {
          result.nav.rowIndex = result.nav.rowIndex <= 0
            ? currentTasks.length - 1
            : result.nav.rowIndex - 1;
        }
        break;
      }
      case KEY_h: {
        result.nav.colIndex = result.nav.colIndex <= 0
          ? BOARD_STATUSES.length - 1
          : result.nav.colIndex - 1;
        result.nav.rowIndex = 0;
        break;
      }
      case KEY_l: {
        result.nav.colIndex = (result.nav.colIndex + 1) % BOARD_STATUSES.length;
        result.nav.rowIndex = 0;
        break;
      }
      case KEY_g: {
        result.nav.rowIndex = 0;
        break;
      }
      case KEY_G: {
        const currentTasks = state.tasks.get(BOARD_STATUSES[result.nav.colIndex]) ?? [];
        result.nav.rowIndex = Math.max(0, currentTasks.length - 1);
        break;
      }
      case "1": case "2": case "3": case "4": case "5": {
        const colIdx = parseInt(key, 10) - 1;
        if (colIdx >= 0 && colIdx < BOARD_STATUSES.length) {
          result.nav.colIndex = colIdx;
          result.nav.rowIndex = 0;
        }
        break;
      }

      // ── Status cycling ─────────────────────────────────────────────────────
      case KEY_s:
      case KEY_S: {
        const task = getHighlightedTask(result.nav, state.tasks);
        if (!task) break;

        const currentStatus = normalizeStatusForBoard(task.status);
        if (!currentStatus) break;

        const currentStatusIdx = BOARD_STATUSES.indexOf(currentStatus);
        const delta = key === KEY_s ? 1 : -1;
        const newStatusIdx = (currentStatusIdx + delta + BOARD_STATUSES.length) % BOARD_STATUSES.length;
        const newStatus = BOARD_STATUSES[newStatusIdx];

        const err = await boardApi.applyStatusChangeAsync(projectPath, task.id, boardStatusToStoreStatus(newStatus));
        if (err) {
          result.errorMessage = err;
        } else {
          result.flashTaskId = task.id;
          result.needsRefresh = true;
        }
        break;
      }

      // ── Close task ─────────────────────────────────────────────────────────
      case KEY_c: {
        const task = getHighlightedTask(result.nav, state.tasks);
        if (!task) break;

        const err = await boardApi.closeTaskAsync(projectPath, task.id);
        if (err) {
          result.errorMessage = err;
        } else {
          result.flashTaskId = task.id;
          result.needsRefresh = true;
        }
        break;
      }
      case KEY_C: {
        const task = getHighlightedTask(result.nav, state.tasks);
        if (!task) break;
        result.promptForCloseReason = true;
        break;
      }

      // ── Create new task ─────────────────────────────────────────────────────
      case KEY_n: {
        suspendRawMode();
        try {
          const newTask = await boardApi.createTaskInEditor((msg) => {
            result.errorMessage = msg;
          });

          if (newTask) {
            const createErr = await boardApi.createTaskAsync(projectPath, newTask);
            if (typeof createErr === "string") {
              result.errorMessage = createErr;
            } else {
              result.flashTaskId = createErr.taskId;
              result.needsRefresh = true;
            }
          }
        } finally {
          resumeRawMode();
        }
        break;
      }

      // ── Edit in editor ──────────────────────────────────────────────────────
      case KEY_e:
      case KEY_E: {
        const task = getHighlightedTask(result.nav, state.tasks);
        if (!task) break;

        const fullSchema = key === KEY_E;
        const updated = boardApi.editTaskInEditor(task, fullSchema, (msg) => {
          result.errorMessage = msg;
        });

        if (updated && updated.id === task.id) {
          const saveErr = await boardApi.saveEditedTaskAsync(projectPath, task.id, updated);
          if (saveErr) {
            result.errorMessage = saveErr;
          } else {
            result.flashTaskId = task.id;
            result.needsRefresh = true;
          }
        }
        break;
      }

      // ── Copy selected task ID ────────────────────────────────────────────────
      case KEY_y: {
        const task = getHighlightedTask(result.nav, state.tasks);
        if (!task) break;

        const err = boardApi.copyToClipboard(task.id);
        if (err) {
          result.errorMessage = err;
        } else {
          result.flashTaskId = task.id;
        }
        break;
      }

      // ── Task detail ─────────────────────────────────────────────────────────
      case KEY_ENTER: {
        const task = getHighlightedTask(result.nav, state.tasks);
        if (task) {
          result.showDetail = true;
          result.detailTask = { ...task };
          void boardApi.loadTaskNotesAsync(projectPath, task.id)
            .then((notes) => callbacks.onDetailNotesLoaded?.(task.id, notes, null))
            .catch((err) => callbacks.onDetailNotesLoaded?.(task.id, null, err instanceof Error ? err.message : String(err)));
        }
        break;
      }

      // ── Mark task as ready ─────────────────────────────────────────────────
      case KEY_R: {
        const task = getHighlightedTask(result.nav, state.tasks);
        if (!task) break;

        if (task.status !== "backlog") {
          result.errorMessage = "Task must be in backlog to mark as ready";
          break;
        }

        const err = await boardApi.applyStatusChangeAsync(projectPath, task.id, "ready");
        if (err) {
          result.errorMessage = err;
        } else {
          result.flashTaskId = task.id;
          result.needsRefresh = true;
        }
        break;
      }

      // ── Toggle sort mode ─────────────────────────────────────────────────────
      case KEY_o: {
        result.sortMode = state.sortMode === "updated" ? "priority" : "updated";
        break;
      }

      // ── Refresh ─────────────────────────────────────────────────────────────
      case KEY_r: {
        result.needsRefresh = true;
        break;
      }

      // ── Help ────────────────────────────────────────────────────────────────
      case KEY_QUESTION: {
        result.showHelp = true;
        break;
      }

      // ── Quit ────────────────────────────────────────────────────────────────
      case KEY_q:
      case KEY_ESC: {
        result.quit = true;
        break;
      }

      default:
        break;
    }

    // Clamp row index after any navigation that might change the column
    if (result.needsRefresh && !result.quit) {
      normalizeNavRowIndex(result.nav, state.tasks);
    }

    return result;
  };
}

// ── Static board snapshot renderer ────────────────────────────────────────────

/**
 * Render a static snapshot of the board to stdout (for script/non-TTY usage).
 * This is used by --all mode to render deterministic per-project snapshots.
 */
export async function renderBoardSnapshot(
  projectPath: string,
  projectName: string,
  options: { limit?: number; filter?: string } = {},
): Promise<void> {
  try {
    const tasks = await loadBoardTasks(projectPath, { filter: options.filter });
    const totalTasks = [...tasks.values()].reduce((sum, t) => sum + t.length, 0);
    const terminalWidth = getTerminalWidth();
    const sortMode: SortMode = "updated";
    const sortedTasks = sortBoardColumns(tasks, sortMode);
    const nav: NavigationState = { colIndex: 0, rowIndex: 0 };

    const state: RenderState = {
      tasks: sortedTasks,
      nav,
      totalTasks,
      errorMessage: null,
      flashTaskId: null,
      showHelp: false,
      showDetail: false,
      detailTask: null,
      detailNotesStatus: "idle",
      detailNotesError: null,
      sortMode,
      refreshStatus: undefined,
      refreshSpinnerFrame: undefined,
      refreshedAt: null,
    };

    const output = renderBoard(state, projectName, terminalWidth, options.limit, getTerminalHeight());
    process.stdout.write(output + "\n");

    if (options.filter) {
      const targetStatus = resolveFilterToBoardStatus(options.filter);
      if (targetStatus) {
        const filteredCount = sortedTasks.get(targetStatus)?.length ?? 0;
        console.log(chalk.dim(`Filtered to ${filteredCount} task(s) in ${STATUS_LABELS[targetStatus]}`));
      }
    }
  } catch (err) {
    console.error(chalk.red(`Failed to render board for ${projectName}: ${err instanceof Error ? err.message : String(err)}`));
  }
}

// ── Main board loop ────────────────────────────────────────────────────────────

export interface BoardOptions {
  projectPath: string;
  projectName: string;
  limit?: number;
  filter?: string;
}

/**
 * Read a line from stdin (for close reason prompt).
 */
async function readLine(prompt: string): Promise<string> {
  const wasRaw = process.stdin.isTTY && process.stdin.isRaw === true;
  // Temporarily disable raw mode to read input.
  if (process.stdin.isTTY && typeof process.stdin.setRawMode === "function") {
    process.stdin.setRawMode!(false);
  }

  const rl = createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  try {
    return await rl.question(prompt);
  } finally {
    rl.close();
    if (process.stdin.isTTY && typeof process.stdin.setRawMode === "function") {
      process.stdin.setRawMode!(wasRaw);
    }
  }
}

/**
 * Run the interactive kanban board TUI loop.
 */
export async function runBoard(opts: BoardOptions): Promise<void> {
  const { projectPath, projectName, limit, filter } = opts;

  let tasks: Map<BoardStatus, BoardTask[]>;
  try {
    tasks = await loadBoardTasks(projectPath, { filter });
  } catch (err) {
    console.error(chalk.red(`Failed to load tasks: ${err instanceof Error ? err.message : String(err)}`));
    return;
  }

  let nav: NavigationState = { colIndex: 0, rowIndex: 0 };
  let sortMode: SortMode = "updated"; // Default: sort by updated_at (most recent first)
  let showHelp = false;
  let showDetail = false;
  let detailTask: BoardTask | null = null;
  let detailNotesStatus: RenderState["detailNotesStatus"] = "idle";
  let detailNotesError: string | null = null;
  let detailNotesTaskId: string | null = null;
  let errorMessage: string | null = null;
  let flashTaskId: string | null = null;
  let refreshStatus: RenderState["refreshStatus"] = "idle";
  let refreshSpinnerFrame = 0;
  let refreshedAt: string | null = null;
  let refreshSpinnerTimer: NodeJS.Timeout | null = null;
  let inboxMonitorTimer: NodeJS.Timeout | null = null;
  let boardInboxLastSeenId: string | null = null;
  let boardInboxCursorTasked = false;
  let inboxUpdateInFlight = false;
  let quit = false;
  let stdinRawMode = false;

  // Apply default sorting (by updated_at descending)
  tasks = sortBoardColumns(tasks, sortMode);

  // Normalize initial navigation
  normalizeNavRowIndex(nav, tasks);

  const renderCurrentBoard = () => {
    const totalTasks = [...tasks.values()].reduce((sum, t) => sum + t.length, 0);
    const currentState: RenderState = {
      tasks,
      nav,
      totalTasks,
      errorMessage,
      flashTaskId,
      showHelp,
      showDetail,
      detailTask,
      detailNotesStatus,
      detailNotesError,
      sortMode,
      refreshStatus,
      refreshSpinnerFrame,
      refreshedAt,
    };

    process.stdout.write(renderBoard(currentState, projectName, getTerminalWidth(), limit, getTerminalHeight()));
  };

  const stopRefreshSpinner = () => {
    if (refreshSpinnerTimer) {
      clearInterval(refreshSpinnerTimer);
      refreshSpinnerTimer = null;
    }
  };

  const stopInboxMonitor = () => {
    if (inboxMonitorTimer) {
      clearInterval(inboxMonitorTimer);
      inboxMonitorTimer = null;
    }
  };

  const startRefreshSpinner = () => {
    stopRefreshSpinner();
    refreshStatus = "refreshing";
    refreshedAt = null;
    refreshSpinnerFrame = 0;
    renderCurrentBoard();
    refreshSpinnerTimer = setInterval(() => {
      refreshSpinnerFrame += 1;
      renderCurrentBoard();
    }, 120);
  };

  const handleKey = createKeyHandler(projectPath, {
    onDetailNotesLoaded: (taskId, notes, error) => {
      if (!showDetail || !detailTask || detailTask.id !== taskId || detailNotesTaskId !== taskId) {
        return;
      }

      if (error) {
        detailNotesStatus = "error";
        detailNotesError = error;
        detailTask = { ...detailTask, notes: [] };
      } else {
        detailNotesStatus = "loaded";
        detailNotesError = null;
        detailTask = { ...detailTask, notes: notes ?? [] };
      }

      renderCurrentBoard();
    },
  });

  process.stdout.write(HIDE_CURSOR);
  renderCurrentBoard();

  try {
    boardInboxLastSeenId = (await pollBoardInboxTaskUpdates(projectPath, null, 100, false)).newestId;
  } catch {
    boardInboxLastSeenId = null;
  }
  boardInboxCursorTasked = true;

  const processInboxTaskUpdates = async () => {
    if (quit || inboxUpdateInFlight) return;
    inboxUpdateInFlight = true;
    try {
      let updatedTaskIds: string[] = [];

      if (foremanBackendMode() === "elixir") {
        const update = await pollBoardTaskSnapshotUpdates(projectPath, tasks, sortMode);
        updatedTaskIds = update.taskIds;
        if (updatedTaskIds.length > 0) {
          tasks = update.tasks;
        }
      } else {
        const update = await pollBoardInboxTaskUpdates(projectPath, boardInboxLastSeenId, 100, boardInboxCursorTasked);
        if (update.newestId) {
          boardInboxLastSeenId = update.newestId;
        }
        if (update.taskIds.length > 0) {
          const refreshedTasks = await Promise.all(
            update.taskIds.map(async (taskId) => ({ taskId, task: await loadBoardTask(projectPath, taskId) })),
          );
          let nextTasks = tasks;
          for (const { taskId, task } of refreshedTasks) {
            nextTasks = applyBoardTaskUpdate(nextTasks, task, taskId, sortMode);
          }
          tasks = nextTasks;
          updatedTaskIds = update.taskIds;
        }
      }

      if (updatedTaskIds.length === 0) return;

      normalizeNavRowIndex(nav, tasks);
      flashTaskId = updatedTaskIds[0] ?? null;
      refreshedAt = new Date().toLocaleTimeString();
      refreshStatus = "refreshed";

      if (detailTask && updatedTaskIds.includes(detailTask.id)) {
        const refreshedDetail = getHighlightedTask(nav, tasks)?.id === detailTask.id
          ? getHighlightedTask(nav, tasks)
          : updatedTaskIds.includes(detailTask.id)
            ? await loadBoardTask(projectPath, detailTask.id)
            : null;
        if (refreshedDetail) {
          detailTask = { ...refreshedDetail, notes: detailTask.notes };
        }
      }

      renderCurrentBoard();
    } catch (err) {
      errorMessage = `Board monitor failed: ${err instanceof Error ? err.message : String(err)}`;
      renderCurrentBoard();
    } finally {
      inboxUpdateInFlight = false;
    }
  };

  inboxMonitorTimer = setInterval(() => {
    void processInboxTaskUpdates();
  }, 2000);

  const attachRawMode = () => {
    if (process.stdin.isTTY && typeof process.stdin.setRawMode === "function") {
      try {
        process.stdin.setRawMode!(true);
        process.stdin.resume();
        process.stdin.setEncoding("utf8");
        stdinRawMode = true;
      } catch {
        // Continue without keyboard handling
      }
    }
  };

  const detachRawMode = () => {
    if (stdinRawMode) {
      try {
        process.stdin.setRawMode!(false);
      } catch {
        // ignore
      }
      stdinRawMode = false;
    }
  };

  attachRawMode();

  const onData = async (chunk: Buffer | string) => {
    const key = chunk.toString();

    // Handle ESC sequences (arrow keys etc.) — map to vim keys
    let normalizedKey = key;
    if (key === "\x1B[A") normalizedKey = KEY_k; // arrow up
    else if (key === "\x1B[B") normalizedKey = KEY_j; // arrow down
    else if (key === "\x1B[C") normalizedKey = KEY_l; // arrow right
    else if (key === "\x1B[D") normalizedKey = KEY_h; // arrow left

    const currentState: RenderState = {
      tasks,
      nav,
      totalTasks: [...tasks.values()].reduce((sum, t) => sum + t.length, 0),
      errorMessage,
      flashTaskId,
      showHelp,
      showDetail,
      detailTask,
      detailNotesStatus,
      detailNotesError,
      sortMode,
      refreshStatus,
      refreshSpinnerFrame,
      refreshedAt,
    };

    const result = await handleKey(normalizedKey, currentState, projectPath);

    if (result.promptForCloseReason) {
      const task = getHighlightedTask(nav, tasks);
      if (task) {
        detachRawMode();
        try {
          const closeReason = await readLine("\nClose reason (optional, press Enter to skip): ");
          const err = await closeTaskAsync(projectPath, task.id, closeReason || undefined);
          if (!err) {
            result.flashTaskId = task.id;
            result.needsRefresh = true;
          } else {
            result.errorMessage = err;
          }
        } finally {
          attachRawMode();
        }
      }
    }

    // Apply navigation changes
    nav = result.nav;
    showHelp = result.showHelp;
    showDetail = result.showDetail;
    detailTask = result.detailTask;
    errorMessage = result.errorMessage;
    flashTaskId = result.flashTaskId;

    // Apply sort mode change (no reload needed, just re-sort in place)
    if (result.sortMode !== undefined && result.sortMode !== sortMode) {
      sortMode = result.sortMode;
      tasks = sortBoardColumns(tasks, sortMode);
      normalizeNavRowIndex(nav, tasks);
    }

    if (!showDetail) {
      detailNotesStatus = "idle";
      detailNotesError = null;
      detailNotesTaskId = null;
    } else if (normalizedKey === KEY_ENTER && detailTask) {
      detailNotesStatus = "loading";
      detailNotesError = null;
      detailNotesTaskId = detailTask.id;
    }

    // Refresh tasks if requested
    if (result.needsRefresh) {
      startRefreshSpinner();
      try {
        tasks = await loadBoardTasks(projectPath, { filter });
        tasks = sortBoardColumns(tasks, sortMode);
        normalizeNavRowIndex(nav, tasks);
        refreshStatus = "refreshed";
        refreshedAt = new Date().toLocaleTimeString();
      } catch (err) {
        errorMessage = `Failed to refresh: ${err instanceof Error ? err.message : String(err)}`;
        refreshStatus = "idle";
        refreshedAt = null;
      } finally {
        stopRefreshSpinner();
      }
      flashTaskId = null;
    }

    if (result.quit) {
      quit = true;
    }

    // Re-render
    renderCurrentBoard();

    if (quit) {
      process.stdout.write(SHOW_CURSOR + "\n");
      stopRefreshSpinner();
      stopInboxMonitor();
      detachRawMode();
      process.exit(0);
    }
  };

  process.stdin.on("data", onData);

  // Handle SIGINT gracefully
  const onSigint = () => {
    process.stdout.write(SHOW_CURSOR + "\n");
    stopRefreshSpinner();
    stopInboxMonitor();
    detachRawMode();
    process.exit(0);
  };
  process.on("SIGINT", onSigint);
}

// ── Command ────────────────────────────────────────────────────────────────────

export const boardCommand = new Command("board")
  .description("Unified cockpit board view for managing Foreman tasks")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .option("--all", "Use legacy/scriptable board output across all registered projects")
  .option("--limit <n>", "Maximum tasks per column / cockpit fetch limit (default: auto-fit terminal height)")
  .option("--filter <status>", "Use legacy/scriptable board output filtered by status")
  .action(async (opts: { project?: string; projectPath?: string; all?: boolean; limit?: string; filter?: string }) => {
    // Require --project or --all in multi-project mode
    if (!opts.all) {
      await requireProjectOrAllInMultiMode(opts.project, opts.all ?? false);
    }

    if (opts.all) {
      const projects = await listRegisteredProjects();
      if (projects.length === 0) {
        console.log(chalk.yellow("No registered projects found. Run 'foreman project add' to register projects."));
        return;
      }
      for (const project of projects) {
        const projectPath = project.path ?? await resolveProjectPathFromOptions({ project: project.name });
        console.log(chalk.bold(`\n=== ${project.name} ===`));
        await renderBoardSnapshot(projectPath, project.name, {
          limit: opts.limit ? parseInt(opts.limit, 10) : undefined,
          filter: opts.filter,
        });
      }
      return;
    }

    const projectPath = await resolveProjectPathFromOptions(opts);
    const projectName = opts.project ?? basename(projectPath);
    const parsedLimit = opts.limit == null ? undefined : parseInt(opts.limit, 10);
    const limit = parsedLimit == null || Number.isNaN(parsedLimit)
      ? undefined
      : Math.max(1, parsedLimit);
    const filter = opts.filter;

    if (resolveBoardCommandRoute(opts, process.stdout.isTTY) === "cockpit") {
      await runInboxSuperTuiForProject(projectPath, projectName, {
        projectSelector: opts.project,
        limit: limit ?? 50,
        eventsLimit: 50,
        scope: "attention",
        initialView: "board",
      });
      return;
    }

    try {
      runBoard({ projectPath, projectName, limit, filter });
    } catch (err) {
      console.error(chalk.red(`Fatal: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });
