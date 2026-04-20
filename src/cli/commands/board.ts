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
import blessed from "blessed";
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
 */
export function loadBoardTasks(projectPath: string): Map<BoardStatus, BoardTask[]> {
  const { store, taskStore } = getTaskStore(projectPath);
  try {
    const db = store.getDb();
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

// ── Key handling helpers ──────────────────────────────────────────────────────

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
const KEY_ENTER = "enter";
const KEY_r = "r";
const KEY_QUESTION = "?";
const KEY_ESC = "escape";
const KEY_q = "q";

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

export function normalizeNavRowIndex(nav: NavigationState, tasks: Map<BoardStatus, BoardTask[]>): void {
  const currentTasks = tasks.get(BOARD_STATUSES[nav.colIndex]) ?? [];
  nav.rowIndex = clamp(nav.rowIndex, 0, Math.max(0, currentTasks.length - 1));
}

export function getHighlightedTask(nav: NavigationState, tasks: Map<BoardStatus, BoardTask[]>): BoardTask | null {
  const currentTasks = tasks.get(BOARD_STATUSES[nav.colIndex]) ?? [];
  return currentTasks[nav.rowIndex] ?? null;
}

export interface KeyHandlerResult {
  nav: NavigationState;
  errorMessage: string | null;
  flashTaskId: string | null;
  showHelp: boolean;
  showDetail: boolean;
  detailTask: BoardTask | null;
  needsRefresh: boolean;
  quit: boolean;
}

export type KeyHandler = (
  key: string,
  state: RenderState,
) => KeyHandlerResult;

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
      case KEY_c:
      case KEY_C: {
        const task = getHighlightedTask(result.nav, state.tasks);
        if (!task) break;

        const err = closeTask(projectPath, task.id, key === KEY_C ? undefined : undefined);
        if (err) {
          result.errorMessage = err;
        } else {
          result.flashTaskId = task.id;
          result.needsRefresh = true;
        }
        break;
      }
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
      case KEY_ENTER: {
        const task = getHighlightedTask(result.nav, state.tasks);
        if (task) {
          result.showDetail = true;
          result.detailTask = task;
          result.needsRefresh = true;
        }
        break;
      }
      case KEY_r: {
        result.needsRefresh = true;
        break;
      }
      case KEY_QUESTION: {
        result.showHelp = true;
        result.needsRefresh = true;
        break;
      }
      case KEY_q:
      case KEY_ESC: {
        result.quit = true;
        break;
      }
      default:
        break;
    }

    if (result.needsRefresh && !result.quit) {
      normalizeNavRowIndex(result.nav, state.tasks);
    }

    return result;
  };
}

// ── Task operations ──────────────────────────────────────────────────────────

export function resolveEditor(): string {
  return process.env.VISUAL ?? process.env.EDITOR ?? "vi";
}

export function editTaskInEditor(
  task: BoardTask,
  fullSchema: boolean,
  onError: (msg: string) => void,
): BoardTask | null {
  const editor = resolveEditor();
  const schema: Record<string, unknown> = {
    id: task.id,
    title: task.title,
    description: task.description ?? "",
    type: task.type,
    priority: task.priority,
    status: task.status,
  };

  if (fullSchema) {
    schema.external_id = task.external_id ?? "";
    schema.created_at = task.created_at;
    schema.updated_at = task.updated_at;
    schema.approved_at = task.approved_at ?? "";
    schema.closed_at = task.closed_at ?? "";
  }

  const yamlContent = yaml.dump(schema);
  const tmpFile = joinPath(tmpdir(), `foreman-task-edit-${randomUUID()}.yaml`);
  writeFileSync(tmpFile, yamlContent, "utf8");

  try {
    const result = spawnSync(editor, [tmpFile], { stdio: "inherit" });
    if (result.status !== 0) {
      return null;
    }

    const editedContent = readFileSync(tmpFile, "utf8");
    const parsed = yaml.load(editedContent) as Record<string, unknown>;

    return {
      id: String(parsed.id ?? task.id),
      title: String(parsed.title ?? task.title),
      description: parsed.description != null ? String(parsed.description) : null,
      type: String(parsed.type ?? task.type),
      priority: Number(parsed.priority ?? task.priority),
      status: String(parsed.status ?? task.status),
      external_id: parsed.external_id != null ? String(parsed.external_id) : null,
      created_at: String(parsed.created_at ?? task.created_at),
      updated_at: String(parsed.updated_at ?? task.updated_at),
      approved_at: parsed.approved_at != null ? String(parsed.approved_at) : null,
      closed_at: parsed.closed_at != null ? String(parsed.closed_at) : null,
    };
  } catch (err) {
    onError(`Editor error: ${err instanceof Error ? err.message : String(err)}`);
    return null;
  } finally {
    try { unlinkSync(tmpFile); } catch { /* ignore */ }
  }
}

export function applyStatusChange(projectPath: string, taskId: string, newStatus: string): string | null {
  const { store, taskStore } = getTaskStore(projectPath);
  try {
    taskStore.updateStatus(taskId, newStatus);
    return null;
  } catch (err) {
    return err instanceof Error ? err.message : String(err);
  } finally {
    store.close();
  }
}

export function closeTask(projectPath: string, taskId: string, reason?: string): string | null {
  const { store, taskStore } = getTaskStore(projectPath);
  try {
    taskStore.updateStatus(taskId, "closed");
    return null;
  } catch (err) {
    return err instanceof Error ? err.message : String(err);
  } finally {
    store.close();
  }
}

export function saveEditedTask(projectPath: string, originalId: string, updated: BoardTask): string | null {
  const { store, taskStore } = getTaskStore(projectPath);
  try {
    taskStore.updateStatus(originalId, updated.status);
    taskStore.update(originalId, {
      title: updated.title,
      description: updated.description,
      priority: updated.priority,
    });
    return null;
  } catch (err) {
    return err instanceof Error ? err.message : String(err);
  } finally {
    store.close();
  }
}

// ── Blessed rendering ────────────────────────────────────────────────────────

/** Priority colors for task cards */
const PRIORITY_FG: Record<number, string> = {
  0: "red",
  1: "yellow",
  2: "cyan",
  3: "white",
  4: "gray",
};

/** Background colors for column headers */
const COL_COLORS: Record<BoardStatus, string> = {
  backlog: "blue",
  ready: "green",
  in_progress: "yellow",
  review: "magenta",
  blocked: "red",
  closed: "gray",
};

function truncate(str: string, max: number): string {
  return str.length > max - 1 ? str.slice(0, max - 2) + "…" : str;
}

function taskCardText(task: BoardTask, width: number, isSelected: boolean): string[] {
  const id = formatTaskIdDisplay(task.id);
  const badge = PRIORITY_BADGES[task.priority] ?? "P?";
  const title = truncate(task.title, width - 8);
  const type = task.type;
  const prefix = isSelected ? "▶ " : "  ";
  
  const lines: string[] = [];
  lines.push(
    `{${isSelected ? "bold" : ""}${isSelected ? " white" : ""}}${prefix}${title}${/} {${PRIORITY_FG[task.priority] || "white"}}${badge}${/}`
  );
  lines.push(`{dim}${id}  ${type}{/}`);
  return lines;
}

function buildBoard(screen: blessed.Widgets.Screen, tasks: Map<BoardStatus, BoardTask[]>, nav: NavigationState, projectName: string, totalTasks: number) {
  const numCols = BOARD_STATUSES.length;
  const width = Math.floor(100 / numCols);
  const cols: blessed.Widgets.BoxElement[] = [];
  
  // Title bar
  const sw = 120; // screen width fallback
  const title = blessed.box({
    parent: screen,
    top: 0,
    left: 0,
    width: "100%",
    height: 1,
    content: ` Foreman Kanban Board — ${projectName} `,
    style: { bg: "blue", fg: "white", bold: true },
    tags: true,
  });

  // Column headers row
  let left = 0;
  for (let i = 0; i < numCols; i++) {
    const status = BOARD_STATUSES[i];
    const colTasks = tasks.get(status) ?? [];
    const label = STATUS_LABELS[status];
    const count = colTasks.length;
    const headerWidth = Math.floor(sw / numCols) - 1;

    const header = blessed.box({
      parent: screen,
      top: 1,
      left,
      width: headerWidth,
      height: 1,
      content: ` ${label} (${count}) `,
      style: { bg: COL_COLORS[status], fg: "white", bold: true },
      align: "left",
      tags: true,
    });

    cols.push(header);
    left += headerWidth + 1;
  }

  // Task lists
  const listTop = 2;
  const listHeight = 26;
  left = 0;

  for (let ci = 0; ci < numCols; ci++) {
    const status = BOARD_STATUSES[ci];
    const colTasks = tasks.get(status) ?? [];
    const listWidth = Math.floor(sw / numCols) - 1;
    const isNavCol = ci === nav.colIndex;

    const list = blessed.box({
      parent: screen,
      top: listTop,
      left,
      width: listWidth,
      height: listHeight,
      style: { border: { fg: COL_COLORS[status] } },
      scrollable: true,
      alwaysScroll: false,
      tags: true,
    });

    // Build content
    let content = "";
    for (let ti = 0; ti < colTasks.length; ti++) {
      const task = colTasks[ti];
      const isNavRow = isNavCol && ti === nav.rowIndex;
      const lines = taskCardText(task, listWidth - 2, isNavRow);
      content += lines.join("\n") + "\n";
    }

    if (colTasks.length === 0) {
      content = "{dim}(empty){/}";
    }

    list.setContent(content);
    cols.push(list);
    left += listWidth + 1;
  }

  // Footer
  const footer = blessed.box({
    parent: screen,
    bottom: 0,
    left: 0,
    width: "100%",
    height: 1,
    content: " {bold}j/k{/} up/down  {bold}h/l{/} left/right  {bold}s/S{/} cycle  {bold}c{/} close  {bold}e{/} edit  {bold}Enter{/} detail  {bold}?{/} help  {bold}r{/} refresh  {bold}q{/} quit ",
    style: { bg: "black", fg: "gray" },
    tags: true,
  });

  return { title, cols, footer };
}

// ── Main board loop ──────────────────────────────────────────────────────────

export interface BoardOptions {
  projectPath: string;
  projectName: string;
  limit?: number;
  filter?: string;
}

export function runBoard(opts: BoardOptions): void {
  const { projectPath, projectName } = opts;

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
  let helpOverlay: blessed.Widgets.BoxElement | null = null;
  let detailOverlay: blessed.Widgets.BoxElement | null = null;
  let errorOverlay: blessed.Widgets.BoxElement | null = null;

  normalizeNavRowIndex(nav, tasks);
  const handleKey = createKeyHandler(projectPath);
  const totalTasks = [...tasks.values()].reduce((sum, t) => sum + t.length, 0);

  // Create screen
  const screen = blessed.screen({
    smartCSR: true,
    autoPadding: false,
    title: "Foreman Kanban Board",
  });

  // Build initial board
  let widgets = buildBoard(screen, tasks, nav, projectName, totalTasks);

  // Render initial state
  screen.render();

  // Key handling
  screen.on("keypress", (ch, key) => {
    let normalizedKey = key.name;

    // Arrow keys → vim keys
    if (key.name === "up") normalizedKey = KEY_k;
    else if (key.name === "down") normalizedKey = KEY_j;
    else if (key.name === "left") normalizedKey = KEY_h;
    else if (key.name === "right") normalizedKey = KEY_l;

    const state: RenderState = {
      tasks,
      nav,
      totalTasks,
      errorMessage,
      flashTaskId,
      showHelp,
      showDetail,
      detailTask,
    };

    const result = handleKey(normalizedKey, state);
    applyResult(result);
    screen.render();
  });

  function applyResult(result: KeyHandlerResult) {
    nav = result.nav;
    showHelp = result.showHelp;
    showDetail = result.showDetail;
    detailTask = result.detailTask;
    errorMessage = result.errorMessage;
    flashTaskId = result.flashTaskId;

    // Refresh tasks
    if (result.needsRefresh && !(showHelp || showDetail)) {
      try {
        tasks = loadBoardTasks(projectPath);
        normalizeNavRowIndex(nav, tasks);
        errorMessage = null;
        flashTaskId = null;
      } catch (err) {
        errorMessage = `Failed to refresh: ${err instanceof Error ? err.message : String(err)}`;
      }
    }

    // Rebuild widgets
    widgets.cols.forEach(w => w.detach());
    widgets = buildBoard(screen, tasks, nav, projectName, [...tasks.values()].reduce((s, t) => s + t.length, 0));

    // Show help overlay
    if (showHelp) {
      if (helpOverlay) helpOverlay.detach();
      helpOverlay = blessed.box({
        parent: screen,
        top: "center",
        left: "center",
        width: "60%",
        height: "60%",
        border: "line",
        label: " Help ",
        style: { bg: "black", fg: "white", border: { fg: "cyan" } },
        content: [
          " {bold}Navigation{/}",
          " {cyan}j/k{/}  Move up/down in column",
          " {cyan}h/l{/}  Move between columns",
          " {cyan}1-6{/}  Jump to column",
          " {cyan}g/G{/}  Go to first/last task",
          "",
          " {bold}Actions{/}",
          " {cyan}s/S{/}  Cycle task status forward/back",
          " {cyan}c{/}    Close task",
          " {cyan}C{/}    Close with reason",
          " {cyan}e/E{/}  Edit task (basic/extended)",
          " {cyan}Enter{/}  Task detail view",
          "",
          " {bold}Other{/}",
          " {cyan}r{/}    Refresh board",
          " {cyan}?{/}    Toggle this help",
          " {cyan}q{/}    Quit",
          "",
          " {dim}Press ? or Esc to close{/}",
        ].join("\n"),
      });
    } else if (helpOverlay) {
      helpOverlay.detach();
      helpOverlay = null;
    }

    // Show detail overlay
    if (showDetail && detailTask) {
      if (detailOverlay) detailOverlay.detach();
      const lines = [
        ` {bold}${detailTask.title}{/}`,
        "",
        ` {dim}ID:{/} ${detailTask.id}`,
        ` {dim}Type:{/} ${detailTask.type}`,
        ` {dim}Priority:{/} ${PRIORITY_BADGES[detailTask.priority] ?? "P?"}`,
        ` {dim}Status:{/} ${detailTask.status}`,
        "",
      ];
      if (detailTask.description) {
        lines.push(` {dim}Description{/}`);
        lines.push(...detailTask.description.split("\n").slice(0, 10).map(l => `  ${l}`));
      }
      lines.push("");
      lines.push(" {dim}Press Enter or Esc to close{/}");
      detailOverlay = blessed.box({
        parent: screen,
        top: "center",
        left: "center",
        width: "60%",
        height: "shrink",
        border: "line",
        label: " Task Detail ",
        style: { bg: "black", fg: "white", border: { fg: "green" } },
        content: lines.join("\n"),
        tags: true,
      });
    } else if (detailOverlay) {
      detailOverlay.detach();
      detailOverlay = null;
    }

    // Show error
    if (errorMessage) {
      if (errorOverlay) errorOverlay.detach();
      errorOverlay = blessed.box({
        parent: screen,
        bottom: 1,
        left: "center",
        width: "80%",
        height: 3,
        border: "line",
        style: { bg: "black", fg: "red", border: { fg: "red" } },
        content: ` {red}{bold}ERROR:{/} ${errorMessage}{/}`,
        tags: true,
      });
    } else if (errorOverlay) {
      errorOverlay.detach();
      errorOverlay = null;
    }
  }

  // Quit on Ctrl+C
  screen.key(["C-c"], () => {
    process.exit(0);
  });
}

// ── Command ──────────────────────────────────────────────────────────────────


export const boardCommand = new Command("board")
  .description("Terminal UI kanban board for managing Foreman tasks")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .option("--limit <n>", "Maximum tasks per column to display", "200")
  .option("--filter <status>", "Filter by status (e.g., backlog, ready, in_progress)")
  .action(async (opts: Record<string, string>) => {
    const projectPath = resolveProjectPathFromOptions({ project: opts.project, projectPath: opts["project-path"] });
    const store = ForemanStore.forProject(projectPath);
    const project = store.getProjectByPath(projectPath);
    const projectName = project?.name ?? basename(projectPath);
    runBoard({ projectPath, projectName, limit: parseInt(opts.limit ?? "200", 10), filter: opts.filter });
  });
