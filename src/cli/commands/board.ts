/**
 * `foreman board` — Terminal UI kanban board for managing Foreman tasks.
 *
 * Features:
 * - 6 status columns: backlog, ready, in_progress, review, blocked, closed
 * - vim-style navigation: j/k (vertical), h/l (horizontal)
 * - Status cycling: s (forward), S (backward)
 * - Close task: c / C (with reason)
 * - Edit in $EDITOR: e / E (full schema)
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
import { basename } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join as joinPath } from "node:path";
import { createInterface } from "node:readline/promises";
import * as yaml from "js-yaml";
import { ForemanStore } from "../../lib/store.js";
import {
  NativeTaskStore,
  priorityLabel,
  formatTaskIdDisplay,
  parsePriority,
  type TaskRow,
} from "../../lib/task-store.js";
import { resolveProjectPathFromOptions, requireProjectOrAllInMultiMode } from "./project-task-support.js";
import { ProjectRegistry } from "../../lib/project-registry.js";

// ── Types ─────────────────────────────────────────────────────────────────────────

/** The 6 fixed status columns. */
export const BOARD_STATUSES = [
  "backlog",
  "ready",
  "in_progress",
  "review",
  "blocked",
  "closed",
] as const;
export type BoardStatus = (typeof BOARD_STATUSES)[number];

const STATUS_LABELS: Record<BoardStatus, string> = {
  backlog: "Backlog",
  ready: "Ready",
  in_progress: "In Progress",
  review: "Review",
  blocked: "Blocked",
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
}

export interface NavigationState {
  colIndex: number;       // 0-5 for status columns
  rowIndex: number;       // position within the column's task list
}

export interface RenderState {
  tasks: Map<BoardStatus, BoardTask[]>;
  nav: NavigationState;
  totalTasks: number;
  errorMessage: string | null;
  flashTaskId: string | null;
  showHelp: boolean;
  showDetail: boolean;
  detailTask: BoardTask | null;
}

// ── Board data loading ───────────────────────────────────────────────────────

function getTaskStore(projectPath: string): { store: ForemanStore; taskStore: NativeTaskStore } {
  const store = ForemanStore.forProject(projectPath);
  const project = store.getProjectByPath(projectPath);
  const taskStore = new NativeTaskStore(store.getDb(), {
    projectKey: project?.name ?? basename(projectPath),
  });
  return { store, taskStore };
}

/**
 * Load all tasks from the native task store, grouped by status.
 * Tasks with unknown statuses are placed in the rightmost column (closed).
 */
export function loadBoardTasks(projectPath: string): Map<BoardStatus, BoardTask[]> {
  const { store, taskStore } = getTaskStore(projectPath);
  try {
    const db = store.getDb();
    // Load all tasks ordered by priority and created_at
    const rows = db.prepare(
      "SELECT * FROM tasks ORDER BY priority ASC, created_at ASC",
    ).all() as TaskRow[];

    const map = new Map<BoardStatus, BoardTask[]>();
    for (const status of BOARD_STATUSES) {
      map.set(status, []);
    }

    for (const row of rows) {
      // Normalize status: convert hyphens to underscores for matching
      const normalizedStatus = row.status.replace(/-/g, "_") as BoardStatus;
      const status = BOARD_STATUSES.includes(normalizedStatus)
        ? normalizedStatus
        : "closed";
      const tasks = map.get(status)!;
      tasks.push({
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
      });
    }

    return map;
  } finally {
    store.close();
  }
}

// ── ANSI rendering helpers ────────────────────────────────────────────────────

/** Clear the entire screen and move cursor to top-left. */
const CLEAR_SCREEN = "\x1B[2J\x1B[H";

/** Hide the cursor. */
const HIDE_CURSOR = "\x1b[?25l";

/** Show the cursor. */
const SHOW_CURSOR = "\x1b[?25h";

/** Get the terminal width. */
function getTerminalWidth(): number {
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

function getVisibleStatuses(
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
        h(Text, { color: metaTextColor, dimColor: !rowBackgroundColor, wrap: "truncate-end" }, task.type),
      ),
      h(
        Box,
        { width: "50%", minWidth: 0 },
        h(Text, { color: metaTextColor, dimColor: !rowBackgroundColor, wrap: "truncate-end" }, task.status),
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
  const slots: Array<ReturnType<typeof h>> = [];

  if (taskWindow.hiddenBefore > 0) {
    slots.push(
      h(
        Text,
        { dimColor: true, wrap: "truncate-end" },
        `↑ ${taskWindow.hiddenBefore} earlier`,
      ),
    );
  }

  for (let index = 0; index < visibleLimit; index += 1) {
    const task = taskWindow.visibleTasks[index];
    if (!task) {
      slots.push(renderEmptyTaskSlot());
      continue;
    }

    slots.push(
      renderTaskCardView(
        task,
        isSelectedColumn && taskWindow.startIndex + index === state.nav.rowIndex,
        task.id === state.flashTaskId,
      ),
    );
  }

  if (taskWindow.hiddenAfter > 0) {
    slots.push(h(Text, { dimColor: true, wrap: "truncate-end" }, `↓ ${taskWindow.hiddenAfter} more`));
  }

  return h(
    Box,
    {
      borderStyle: "round",
      borderColor: isSelectedColumn ? "cyan" : "gray",
      flexDirection: "column",
      height: columnHeight,
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
    ["[1]…[6]", "Jump to column by number"],
    ["s / S", "Cycle status forward / backward"],
    ["c", "Close task"],
    ["C", "Close task with reason"],
    ["e / E", "Edit task in editor"],
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

function renderTaskDetailView(task: BoardTask, width: number): ReturnType<typeof h> {
  const panelWidth = Math.max(24, Math.min(64, width));
  const fieldWidth = Math.max(8, Math.min(14, Math.floor(panelWidth * 0.28)));

  const rows: Array<[string, string | null]> = [
    ["ID:", task.id],
    ["Title:", task.title],
    ["Type:", task.type],
    ["Priority:", `${priorityLabel(task.priority)} (P${task.priority})`],
    ["Status:", task.status],
    ["External ID:", task.external_id],
    ["Created:", new Date(task.created_at).toLocaleString()],
    ["Updated:", new Date(task.updated_at).toLocaleString()],
    ["Approved:", task.approved_at ? new Date(task.approved_at).toLocaleString() : null],
    ["Closed:", task.closed_at ? new Date(task.closed_at).toLocaleString() : null],
  ];

  const children: Array<ReturnType<typeof h>> = [
    h(Text, { key: "detail-title", color: "blue", bold: true }, "TASK DETAIL"),
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
          h(Text, { bold: true, wrap: "truncate-end" }, "Description:"),
        ),
        h(
          Box,
          { flexGrow: 1, minWidth: 0 },
          h(Text, { wrap: "truncate-end" }, firstLine ?? ""),
        ),
      ),
    );

    for (const [index, line] of rest.slice(0, 4).entries()) {
      children.push(
        h(
          Box,
          { key: `desc:${index}`, width: "100%" },
          h(Box, { width: fieldWidth }, h(Text, null, " ")),
          h(
            Box,
            { flexGrow: 1, minWidth: 0 },
            h(Text, { dimColor: true, wrap: "truncate-end" }, line),
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
          h(Text, { bold: true, wrap: "truncate-end" }, label),
        ),
        h(
          Box,
          { flexGrow: 1, minWidth: 0 },
          h(Text, { wrap: "truncate-end" }, value),
        ),
      ),
    );
  }

  children.push(h(Text, { key: "detail-hint", dimColor: true }, "Press Enter or Esc to close"));

  return h(
    Box,
    { borderStyle: "round", borderColor: "blue", flexDirection: "column", width: panelWidth },
    ...children,
  );
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
  const reservedRows =
    5
    + (state.errorMessage ? 2 : 0)
    + (state.showHelp ? 16 : 0)
    + (state.showDetail && state.detailTask ? 14 : 0);
  const columnHeight = Math.max(8, terminalHeight - reservedRows);

  const tree = h(
    Box,
    { flexDirection: "column", width: terminalWidth },
    h(
      Box,
      { width: "100%", marginBottom: 1 },
      h(Text, { color: "blue", bold: true, wrap: "truncate-end" }, `Foreman Kanban Board — ${projectName}`),
      h(Spacer, null),
      h(
        Text,
        { dimColor: true },
        `${totalTasks} task${totalTasks === 1 ? "" : "s"}`,
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
    h(Text, { dimColor: true }, "j/k up/down  h/l left/right  s/S cycle status  c/C close  e/E edit  Enter detail  ? help  r refresh  q quit"),
    state.errorMessage
      ? h(
        Box,
        { marginTop: 1 },
        h(Text, { color: "red", bold: true }, "ERROR "),
        h(Text, { color: "red", wrap: "truncate-end" }, state.errorMessage),
      )
      : null,
    state.showHelp
      ? h(Box, { marginTop: 1 }, renderHelpOverlayView(Math.max(24, terminalWidth - 2)))
      : null,
    state.showDetail && state.detailTask
      ? h(Box, { marginTop: 1 }, renderTaskDetailView(state.detailTask, Math.max(24, terminalWidth - 2)))
      : null,
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
export function renderTaskDetail(task: BoardTask, width: number): string {
  return renderToString(renderTaskDetailView(task, width), { columns: width });
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
  const { store, taskStore } = getTaskStore(projectPath);
  try {
    taskStore.update(taskId, { status: newStatus });
    return null;
  } catch (err) {
    return err instanceof Error ? err.message : String(err);
  } finally {
    store.close();
  }
}

/**
 * Close a task (status → closed, optionally with a reason stored in closed_at).
 */
export function closeTask(projectPath: string, taskId: string, reason?: string): string | null {
  const { store, taskStore } = getTaskStore(projectPath);
  try {
    taskStore.close(taskId);
    if (reason) {
      // Store reason in closed_at (we reuse this field; a real implementation might use a separate field)
      const db = store.getDb();
      db.prepare("UPDATE tasks SET closed_at = ? WHERE id = ?").run(reason, taskId);
    }
    return null;
  } catch (err) {
    return err instanceof Error ? err.message : String(err);
  } finally {
    store.close();
  }
}

/**
 * Save an edited task back to the store (title, description, priority, status).
 */
export function saveEditedTask(projectPath: string, originalId: string, updated: BoardTask): string | null {
  const { store, taskStore } = getTaskStore(projectPath);
  try {
    const db = store.getDb();
    db.prepare(
      `UPDATE tasks SET title = ?, description = ?, type = ?, priority = ?, status = ?, updated_at = ? WHERE id = ?`,
    ).run(
      updated.title,
      updated.description ?? null,
      updated.type,
      updated.priority,
      updated.status,
      new Date().toISOString(),
      originalId,
    );
    return null;
  } catch (err) {
    return err instanceof Error ? err.message : String(err);
  } finally {
    store.close();
  }
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
const KEY_q = "q";
const KEY_QUESTION = "?";

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
}

export type KeyHandler = (
  key: string,
  state: RenderState,
  projectPath: string,
) => KeyHandlerResult;

/**
 * Create the key handler closure that captures projectPath.
 */
export function createKeyHandler(projectPath: string): KeyHandler {
  return function handleKey(
    key: string,
    state: RenderState,
  ): KeyHandlerResult {
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
        result.needsRefresh = true;
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
        result.needsRefresh = true;
        break;
      }
      case KEY_l: {
        result.nav.colIndex = (result.nav.colIndex + 1) % BOARD_STATUSES.length;
        result.nav.rowIndex = 0;
        result.needsRefresh = true;
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
      case "1": case "2": case "3": case "4": case "5": case "6": {
        const colIdx = parseInt(key, 10) - 1;
        if (colIdx >= 0 && colIdx < BOARD_STATUSES.length) {
          result.nav.colIndex = colIdx;
          result.nav.rowIndex = 0;
          result.needsRefresh = true;
        }
        break;
      }

      // ── Status cycling ─────────────────────────────────────────────────────
      case KEY_s:
      case KEY_S: {
        const task = getHighlightedTask(result.nav, state.tasks);
        if (!task) break;

        const currentStatusIdx = BOARD_STATUSES.indexOf(task.status as BoardStatus);
        if (currentStatusIdx === -1) break;

        const delta = key === KEY_s ? 1 : -1;
        const newStatusIdx = (currentStatusIdx + delta + BOARD_STATUSES.length) % BOARD_STATUSES.length;
        const newStatus = BOARD_STATUSES[newStatusIdx];

        const err = applyStatusChange(projectPath, task.id, newStatus);
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

        const err = closeTask(projectPath, task.id);
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

      // ── Edit in editor ──────────────────────────────────────────────────────
      case KEY_e:
      case KEY_E: {
        const task = getHighlightedTask(result.nav, state.tasks);
        if (!task) break;

        const fullSchema = key === KEY_E;
        const updated = editTaskInEditor(task, fullSchema, (msg) => {
          result.errorMessage = msg;
        });

        if (updated && updated.id === task.id) {
          const saveErr = saveEditedTask(projectPath, task.id, updated);
          if (saveErr) {
            result.errorMessage = saveErr;
          } else {
            result.flashTaskId = task.id;
            result.needsRefresh = true;
          }
        }
        break;
      }

      // ── Task detail ─────────────────────────────────────────────────────────
      case KEY_ENTER: {
        const task = getHighlightedTask(result.nav, state.tasks);
        if (task) {
          result.showDetail = true;
          result.detailTask = task;
          result.needsRefresh = true;
        }
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
        result.needsRefresh = true;
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
  // Temporarily disable raw mode to read input
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
      process.stdin.setRawMode!(true);
    }
  }
}

/**
 * Run the interactive kanban board TUI loop.
 */
export function runBoard(opts: BoardOptions): void {
  const { projectPath, projectName, limit } = opts;

  let tasks: Map<BoardStatus, BoardTask[]>;
  try {
    tasks = loadBoardTasks(projectPath);
  } catch (err) {
    console.error(chalk.red(`Failed to load tasks: ${err instanceof Error ? err.message : String(err)}`));
    return;
  }

  let nav: NavigationState = { colIndex: 0, rowIndex: 0 };
  let showHelp = false;
  let showDetail = false;
  let detailTask: BoardTask | null = null;
  let errorMessage: string | null = null;
  let flashTaskId: string | null = null;
  let quit = false;
  let stdinRawMode = false;

  // Normalize initial navigation
  normalizeNavRowIndex(nav, tasks);

  const handleKey = createKeyHandler(projectPath);

  // Render initial state
  const totalTasks = [...tasks.values()].reduce((sum, t) => sum + t.length, 0);
  let initialState: RenderState = {
    tasks,
    nav,
    totalTasks,
    errorMessage,
    flashTaskId,
    showHelp,
    showDetail,
    detailTask,
  };

  process.stdout.write(HIDE_CURSOR);
  process.stdout.write(renderBoard(initialState, projectName, getTerminalWidth(), limit, getTerminalHeight()));

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
    };

    const result = handleKey(normalizedKey, currentState, projectPath);

    if (result.promptForCloseReason) {
      const task = getHighlightedTask(nav, tasks);
      if (task) {
        detachRawMode();
        try {
          const closeReason = await readLine("\nClose reason (optional, press Enter to skip): ");
          const err = closeTask(projectPath, task.id, closeReason || undefined);
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

    // Refresh tasks if requested
    if (result.needsRefresh) {
      try {
        tasks = loadBoardTasks(projectPath);
        normalizeNavRowIndex(nav, tasks);
      } catch (err) {
        errorMessage = `Failed to refresh: ${err instanceof Error ? err.message : String(err)}`;
      }
      flashTaskId = null;
    }

    if (result.quit) {
      quit = true;
    }

    // Re-render
    const newState: RenderState = {
      tasks,
      nav,
      totalTasks: [...tasks.values()].reduce((sum, t) => sum + t.length, 0),
      errorMessage,
      flashTaskId,
      showHelp,
      showDetail,
      detailTask,
    };

    process.stdout.write(renderBoard(newState, projectName, getTerminalWidth(), limit, getTerminalHeight()));

    if (quit) {
      process.stdout.write(SHOW_CURSOR + "\n");
      detachRawMode();
      process.exit(0);
    }
  };

  process.stdin.on("data", onData);

  // Handle SIGINT gracefully
  const onSigint = () => {
    process.stdout.write(SHOW_CURSOR + "\n");
    detachRawMode();
    process.exit(0);
  };
  process.on("SIGINT", onSigint);
}

// ── Command ────────────────────────────────────────────────────────────────────

export const boardCommand = new Command("board")
  .description("Terminal UI kanban board for managing Foreman tasks")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .option("--all", "Show board across all registered projects")
  .option("--limit <n>", "Maximum tasks per column to display (default: auto-fit terminal height)")
  .option("--filter <status>", "Filter by status (e.g., backlog, ready, in_progress)")
  .action(async (opts: { project?: string; projectPath?: string; all?: boolean; limit?: string; filter?: string }) => {
    // Require --project or --all in multi-project mode
    if (!opts.all) {
      await requireProjectOrAllInMultiMode(opts.project, opts.all ?? false);
    }

    if (opts.all) {
      const registry = new ProjectRegistry();
      const projects = await registry.list();
      if (projects.length === 0) {
        console.log(chalk.yellow("No registered projects found. Run 'foreman project add' to register projects."));
        return;
      }
      for (const project of projects) {
        const projectPath = project.path ?? resolveProjectPathFromOptions({ project: project.name });
        console.log(chalk.bold(`\n=== ${project.name} ===`));
        try {
          runBoard({ projectPath, projectName: project.name, limit: opts.limit ? parseInt(opts.limit, 10) : undefined, filter: opts.filter });
        } catch (err) {
          console.error(chalk.red(`Board error for ${project.name}: ${err instanceof Error ? err.message : String(err)}`));
        }
      }
      return;
    }

    const projectPath = resolveProjectPathFromOptions(opts);
    const projectName = opts.project ?? basename(projectPath);
    const parsedLimit = opts.limit == null ? undefined : parseInt(opts.limit, 10);
    const limit = parsedLimit == null || Number.isNaN(parsedLimit)
      ? undefined
      : Math.max(1, parsedLimit);
    const filter = opts.filter;

    try {
      runBoard({ projectPath, projectName, limit, filter });
    } catch (err) {
      console.error(chalk.red(`Fatal: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });
