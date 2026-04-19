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
import { basename } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join as joinPath } from "node:path";
import * as yaml from "js-yaml";
import { ForemanStore } from "../../lib/store.js";
import {
  NativeTaskStore,
  priorityLabel,
  formatTaskIdDisplay,
  parsePriority,
  type TaskRow,
} from "../../lib/task-store.js";
import { resolveProjectPathFromOptions } from "./project-task-support.js";

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

/** Priority badge colors. */
const PRIORITY_COLORS: Record<number, (text: string) => string> = {
  0: chalk.bgRed.white,
  1: chalk.bgYellow.black,
  2: chalk.bgCyan.black,
  3: chalk.bgGray.white,
  4: chalk.bgBlackBright.white,
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
      const status = BOARD_STATUSES.includes(row.status as BoardStatus)
        ? (row.status as BoardStatus)
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

/** Move cursor to (row, col) using 1-based coordinates. */
function moveTo(row: number, col: number): string {
  return `\x1B[${row};${col}H`;
}

/** Get the terminal width. */
function getTerminalWidth(): number {
  return process.stdout.columns || 80;
}

/**
 * Clamp a value to [min, max] inclusive.
 */
function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

// ── Board renderer ────────────────────────────────────────────────────────────

const MIN_COL_WIDTH = 12;
const TASK_CARD_HEIGHT = 3;
const MAX_VISIBLE_PER_COL = 5;

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
): string {
  const lines: string[] = [];

  // ── Header ────────────────────────────────────────────────────────────────
  const title = ` Foreman Kanban Board — ${projectName} `;
  const taskCount = ` ${state.totalTasks} task${state.totalTasks !== 1 ? "s" : ""} `;
  const headerLine = chalk.bgBlue.white(title) + chalk.bgBlue.dim(taskCount);
  lines.push(CLEAR_SCREEN + headerLine);
  lines.push("");

  // ── Column number row ────────────────────────────────────────────────────
  const colNumbers = BOARD_STATUSES.map((s, i) => {
    const num = chalk.dim(`[${i + 1}]`);
    return `${num} ${chalk.bold(STATUS_LABELS[s])}`;
  });
  lines.push("  " + colNumbers.join(chalk.dim("   ")));
  lines.push("");

  // ── Task columns ──────────────────────────────────────────────────────────
  const numCols = BOARD_STATUSES.length;
  const colWidth = Math.max(MIN_COL_WIDTH, Math.floor((terminalWidth - 4) / numCols));
  const columnHeights: number[] = [];

  for (let ci = 0; ci < numCols; ci++) {
    const status = BOARD_STATUSES[ci];
    const tasks = state.tasks.get(status) ?? [];
    const isNavCol = ci === state.nav.colIndex;
    columnHeights.push(tasks.length);

    // Column header
    const countStr = tasks.length === 0
      ? chalk.dim("(empty)")
      : chalk.white(`${tasks.length}`);
    const headerText = `${STATUS_LABELS[status]} ${chalk.dim("(")}${countStr}${chalk.dim(")")}`;
    lines.push(`  ${chalk.underline(headerText)}`);

    // Task cards
    const visibleTasks = tasks.slice(0, MAX_VISIBLE_PER_COL);
    const extraCount = Math.max(0, tasks.length - MAX_VISIBLE_PER_COL);

    for (let ti = 0; ti < MAX_VISIBLE_PER_COL; ti++) {
      const isNavRow = isNavCol && ti === state.nav.rowIndex;
      const task = visibleTasks[ti] ?? null;

      if (task) {
        const isFlash = task.id === state.flashTaskId;
        const cardLines = renderTaskCard(task, colWidth, isNavRow, isFlash, state.showDetail && state.detailTask?.id === task.id);
        for (const line of cardLines) {
          lines.push(line);
        }
      } else {
        // Empty slot
        const emptyLine = "  " + " ".repeat(colWidth);
        lines.push(emptyLine);
      }
    }

    // "+N more" indicator
    if (extraCount > 0) {
      lines.push(`  ${chalk.dim(`+${extraCount} more`)}`);
    }

    lines.push(""); // gap between columns
  }

  // ── Footer ────────────────────────────────────────────────────────────────
  lines.push(chalk.dim("─".repeat(terminalWidth)));
  lines.push(
    `  ${chalk.dim("j/k")} up/down  ${chalk.dim("h/l")} left/right  ${chalk.dim("s/S")} cycle status  ${chalk.dim("c/C")} close  ${chalk.dim("e/E")} edit  ${chalk.dim("Enter")} detail  ${chalk.dim("?")} help  ${chalk.dim("r")} refresh  ${chalk.dim("q")} quit`,
  );

  // ── Error banner ──────────────────────────────────────────────────────────
  if (state.errorMessage) {
    lines.push("");
    lines.push(chalk.bgRed.white(" ERROR ") + " " + chalk.red(state.errorMessage));
  }

  // ── Help overlay ─────────────────────────────────────────────────────────
  if (state.showHelp) {
    const helpLines = renderHelpOverlay(terminalWidth);
    const startRow = Math.floor(terminalWidth / 2) - Math.floor(helpLines.length / 2);
    for (let i = 0; i < helpLines.length; i++) {
      lines.push(moveTo(startRow + i, 1) + helpLines[i]);
    }
  }

  // ── Task detail panel ─────────────────────────────────────────────────────
  if (state.showDetail && state.detailTask) {
    const detailLines = renderTaskDetail(state.detailTask, terminalWidth);
    const startRow = 3;
    for (let i = 0; i < detailLines.length; i++) {
      lines.push(moveTo(startRow + i, 1) + detailLines[i]);
    }
  }

  return lines.join("\n");
}

/**
 * Render a single task card as 3 lines (truncated title, ID, priority badge).
 */
export function renderTaskCard(
  task: BoardTask,
  width: number,
  isSelected: boolean,
  isFlash: boolean,
  isExpanded: boolean,
): string[] {
  const idDisplay = formatTaskIdDisplay(task.id);
  const truncatedTitle = task.title.length > width - 4
    ? task.title.slice(0, width - 7) + "…"
    : task.title;

  const badge = PRIORITY_BADGES[task.priority] ?? "P?";
  const badgeColorFn = PRIORITY_COLORS[task.priority] ?? chalk.bgGray;
  const badgeStr = badgeColorFn(` ${badge} `);

  // Determine highlight style
  let prefix: string;
  if (isSelected) {
    if (isFlash) {
      prefix = chalk.bgGreen.black("▶ ");
    } else {
      prefix = chalk.bgCyan.black("▶ ");
    }
  } else {
    prefix = "  ";
  }

  const idStr = chalk.dim(idDisplay);
  const titleStr = isSelected ? chalk.blackBright(truncatedTitle) : chalk.white(truncatedTitle);
  const line1 = prefix + titleStr.padEnd(width - 2) + badgeStr;

  const typeStr = chalk.dim(task.type);
  const statusStr = chalk.dim(task.status);
  const line2 = "  " + typeStr.padEnd(Math.floor(width / 2)) + statusStr.padEnd(Math.floor(width / 2));

  if (isExpanded) {
    const descLines = (task.description ?? "").slice(0, width * 2).split("\n").slice(0, 3);
    const expanded: string[] = [];
    for (const dl of descLines) {
      const truncated = dl.length > width - 4 ? dl.slice(0, width - 7) + "…" : dl;
      expanded.push("  " + chalk.dim(truncated));
    }
    return [line1, line2, ...expanded];
  }

  return [line1, line2];
}

/**
 * Render the help overlay panel.
 */
export function renderHelpOverlay(width: number): string[] {
  const panelWidth = Math.min(72, width - 4);
  const col1 = Math.floor(panelWidth * 0.4);
  const col2 = panelWidth - col1;

  const rows: [string, string][] = [
    ["j / k", "Move up / down in column"],
    ["h / l", "Move left / right between columns"],
    ["g / G", "Jump to first / last task in column"],
    ["[1]…[6]", "Jump to column by number"],
    ["s / S", "Cycle status forward / backward"],
    ["c", "Close task (status → closed)"],
    ["C", "Close task with reason prompt"],
    ["e", "Edit task in $EDITOR (basic YAML)"],
    ["E", "Edit task in $EDITOR (full schema)"],
    ["Enter", "Show task detail panel"],
    ["Esc", "Dismiss detail / help overlay"],
    ["r", "Refresh board from store"],
    ["q", "Quit board"],
  ];

  const lines: string[] = [];
  const border = "─".repeat(panelWidth);

  lines.push(chalk.bgYellow.black(` ${chalk.bold("HELP — Key Bindings")} `) + "─".repeat(panelWidth - 22));
  lines.push(chalk.bgBlack(" " + "Key".padEnd(col1) + " " + "Action".padEnd(col2) + " "));
  lines.push(chalk.bgBlack(border));

  for (const [key, action] of rows) {
    const keyStr = chalk.cyan(key.padEnd(col1));
    const actionStr = chalk.white(action);
    lines.push(` ${keyStr} ${actionStr.padEnd(col2)} `);
  }

  lines.push(chalk.bgBlack(border));
  lines.push(chalk.bgBlack(" " + chalk.dim("Press ? or Esc to close").padEnd(panelWidth - 2) + " "));

  return lines;
}

/**
 * Render the task detail panel (full metadata).
 */
export function renderTaskDetail(task: BoardTask, width: number): string[] {
  const panelWidth = Math.min(64, width - 4);
  const lines: string[] = [];

  const border = "─".repeat(panelWidth);
  lines.push(chalk.bgBlue.white(" TASK DETAIL ") + "─".repeat(panelWidth - 14));
  lines.push("");

  const fieldWidth = 12;
  const valueWidth = panelWidth - fieldWidth - 2;

  function fieldRow(label: string, value: string): string {
    const truncated = value.length > valueWidth ? value.slice(0, valueWidth - 1) + "…" : value;
    return `  ${chalk.bold(label.padEnd(fieldWidth))} ${truncated}`;
  }

  lines.push(fieldRow("ID:", task.id));
  lines.push(fieldRow("Title:", task.title));
  if (task.description) {
    // Description may span multiple lines
    const descLines = task.description.split("\n").slice(0, 5);
    lines.push(fieldRow("Description:", descLines[0] ?? ""));
    for (const dl of descLines.slice(1)) {
      lines.push("  " + " ".repeat(fieldWidth) + " " + chalk.dim(dl));
    }
  }
  lines.push(fieldRow("Type:", task.type));
  lines.push(fieldRow("Priority:", `${priorityLabel(task.priority)} (P${task.priority})`));
  lines.push(fieldRow("Status:", task.status));
  if (task.external_id) {
    lines.push(fieldRow("External ID:", task.external_id));
  }
  lines.push(fieldRow("Created:", new Date(task.created_at).toLocaleString()));
  lines.push(fieldRow("Updated:", new Date(task.updated_at).toLocaleString()));
  if (task.approved_at) {
    lines.push(fieldRow("Approved:", new Date(task.approved_at).toLocaleString()));
  }
  if (task.closed_at) {
    lines.push(fieldRow("Closed:", new Date(task.closed_at).toLocaleString()));
  }

  lines.push("");
  lines.push(chalk.dim("─".repeat(panelWidth)));
  lines.push(chalk.dim("  Press Enter or Esc to close"));

  return lines;
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
      case KEY_c:
      case KEY_C: {
        const task = getHighlightedTask(result.nav, state.tasks);
        if (!task) break;

        // For C key, prompt for reason (handled by caller)
        const err = closeTask(projectPath, task.id, key === KEY_C ? undefined : undefined);
        if (err) {
          result.errorMessage = err;
        } else {
          result.flashTaskId = task.id;
          result.needsRefresh = true;
        }
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
 * Read a line from stdin synchronously (for close reason prompt).
 */
function readLineSync(prompt: string): string {
  // Temporarily disable raw mode to read input
  if (process.stdin.isTTY && typeof process.stdin.setRawMode === "function") {
    process.stdin.setRawMode!(false);
  }

  const readline = require("readline");
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  return new Promise<string>((resolve) => {
    rl.question(prompt, (answer: string) => {
      rl.close();
      // Re-enable raw mode
      if (process.stdin.isTTY && typeof process.stdin.setRawMode === "function") {
        process.stdin.setRawMode!(true);
      }
      resolve(answer);
    });
  }) as unknown as string;
}

/**
 * Run the interactive kanban board TUI loop.
 */
export function runBoard(opts: BoardOptions): void {
  const { projectPath, projectName, limit = 200 } = opts;

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
  process.stdout.write(renderBoard(initialState, projectName, getTerminalWidth()));

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

    // Handle C key (close with reason) specially
    let closeReason: string | undefined;
    if (normalizedKey === KEY_C) {
      // Dismiss raw mode temporarily to read the reason
      detachRawMode();
      process.stdout.write("\n" + chalk.bold("Close reason (optional, press Enter to skip): ") + "");
      closeReason = await readLineSync("");
      attachRawMode();
    }

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

    // Apply close reason if this was a C key press
    if (normalizedKey === KEY_C && closeReason !== undefined) {
      const task = getHighlightedTask(nav, tasks);
      if (task) {
        const err = closeTask(projectPath, task.id, closeReason || undefined);
        if (!err) {
          result.flashTaskId = task.id;
          result.needsRefresh = true;
        } else {
          result.errorMessage = err;
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

    process.stdout.write(renderBoard(newState, projectName, getTerminalWidth()));

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
  .option("--limit <n>", "Maximum tasks per column to display", "5")
  .option("--filter <status>", "Filter by status (e.g., backlog, ready, in_progress)")
  .action((opts: { project?: string; projectPath?: string; limit?: string; filter?: string }) => {
    const projectPath = resolveProjectPathFromOptions(opts);
    const projectName = opts.project ?? basename(projectPath);
    const limit = Math.max(1, parseInt(opts.limit ?? "5", 10) || 5);
    const filter = opts.filter;

    try {
      runBoard({ projectPath, projectName, limit, filter });
    } catch (err) {
      console.error(chalk.red(`Fatal: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });
