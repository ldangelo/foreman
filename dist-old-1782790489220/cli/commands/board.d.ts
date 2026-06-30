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
/** The 6 fixed status columns. */
export declare const BOARD_STATUSES: readonly ["backlog", "ready", "in_progress", "needs_attention", "closed"];
export type BoardStatus = (typeof BOARD_STATUSES)[number];
export declare function normalizeStatusForBoard(status: string): BoardStatus | null;
export declare function boardColumnForTaskStatus(status: string): BoardStatus;
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
    notes?: BoardTaskNote[];
}
export interface NavigationState {
    colIndex: number;
    rowIndex: number;
}
/** Sort modes for board columns. */
export type SortMode = "updated" | "priority";
/** Sort mode display labels. */
export declare const SORT_MODE_LABELS: Record<SortMode, string>;
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
export declare function sortBoardTasks(tasks: BoardTask[], sortMode: SortMode): BoardTask[];
/**
 * Sort all tasks in a column map based on the selected sort mode.
 */
export declare function sortBoardColumns(taskMap: Map<BoardStatus, BoardTask[]>, sortMode: SortMode): Map<BoardStatus, BoardTask[]>;
export declare function loadBoardTasks(projectPath: string): Promise<Map<BoardStatus, BoardTask[]>>;
export declare function loadBoardTask(projectPath: string, taskId: string): Promise<BoardTask | null>;
export interface BoardInboxUpdateResult {
    taskIds: string[];
    newestId: string | null;
}
export declare function pollBoardInboxTaskUpdates(projectPath: string, lastSeenId: string | null, limit?: number, cursorSeeded?: boolean): Promise<BoardInboxUpdateResult>;
export declare function applyBoardTaskUpdate(taskMap: Map<BoardStatus, BoardTask[]>, task: BoardTask | null, taskId: string, sortMode: SortMode): Map<BoardStatus, BoardTask[]>;
export declare function refreshBoardTasksById(projectPath: string, taskMap: Map<BoardStatus, BoardTask[]>, taskIds: Iterable<string>, sortMode: SortMode): Promise<Map<BoardStatus, BoardTask[]>>;
export declare function loadBoardTaskNotes(projectPath: string, taskId: string): Promise<BoardTaskNote[]>;
export interface VisibleTaskWindow {
    startIndex: number;
    visibleTasks: BoardTask[];
    hiddenBefore: number;
    hiddenAfter: number;
}
export declare function getVisibleTaskCapacity(columnHeight: number, taskCount: number, userLimit?: number): number;
export declare function getVisibleTaskWindow(tasks: readonly BoardTask[], selectedIndex: number, maxVisiblePerCol: number): VisibleTaskWindow;
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
export declare function renderBoard(state: RenderState, projectName: string, terminalWidth: number, userVisibleLimit?: number, terminalHeight?: number): string;
/**
 * Render the help overlay panel.
 */
export declare function renderHelpOverlay(width: number): string;
/**
 * Render the task detail panel (full metadata).
 */
export declare function renderTaskDetail(task: BoardTask, width: number, notesStatus?: RenderState["detailNotesStatus"], notesError?: string | null, terminalHeight?: number): string;
/** Resolve the $EDITOR environment variable with fallbacks. */
export declare function resolveEditor(): string;
/**
 * Open the task YAML in $EDITOR and return the parsed content on success.
 * On error or non-zero exit, returns null and sets errorMessage.
 */
export declare function editTaskInEditor(task: BoardTask, fullSchema: boolean, onError: (msg: string) => void): BoardTask | null;
/**
 * Write a status change to the store.
 */
export declare function applyStatusChange(projectPath: string, taskId: string, newStatus: string): string | null;
export declare function applyStatusChangeAsync(projectPath: string, taskId: string, newStatus: string): Promise<string | null>;
/**
 * Close a task (status → closed, optionally with a reason stored in closed_at).
 */
export declare function closeTask(projectPath: string, taskId: string, reason?: string): string | null;
export declare function closeTaskAsync(projectPath: string, taskId: string, _reason?: string): Promise<string | null>;
/**
 * Save an edited task back to the store (title, description, priority, status).
 */
export declare function saveEditedTask(projectPath: string, originalId: string, updated: BoardTask): string | null;
export declare function saveEditedTaskAsync(projectPath: string, originalId: string, updated: BoardTask): Promise<string | null>;
/** Copy text to the system clipboard using the platform clipboard command. */
export declare function copyToClipboard(text: string): string | null;
/**
 * Normalize nav.rowIndex to be within the bounds of the current column.
 * If the column is empty, set rowIndex = 0.
 */
export declare function normalizeNavRowIndex(nav: NavigationState, tasks: Map<BoardStatus, BoardTask[]>): void;
/**
 * Get the currently highlighted task, or null if the column is empty.
 */
export declare function getHighlightedTask(nav: NavigationState, tasks: Map<BoardStatus, BoardTask[]>): BoardTask | null;
/**
 * Open the editor with a new task template and return the parsed content on success.
 * On error or non-zero exit, returns null and sets errorMessage.
 */
export declare function createTaskInEditor(onError: (msg: string) => void): {
    id?: string;
    title: string;
    description: string | null;
    type: string;
    priority: number;
    status: string;
} | null;
/**
 * Create a new task via the tRPC API.
 */
export declare function createTaskAsync(projectPath: string, taskData: {
    id?: string;
    title: string;
    description?: string | null;
    type?: string;
    priority?: number;
    status?: string;
}): Promise<{
    taskId: string;
} | string>;
export declare const boardApi: {
    createTaskInEditor: typeof createTaskInEditor;
    createTaskAsync: typeof createTaskAsync;
    applyStatusChangeAsync: typeof applyStatusChangeAsync;
    loadTaskNotesAsync: typeof loadBoardTaskNotes;
    copyToClipboard: typeof copyToClipboard;
};
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
    onDetailNotesLoaded?: (taskId: string, notes: BoardTaskNote[] | null, error: string | null) => void;
}
export type KeyHandler = (key: string, state: RenderState, projectPath: string) => Promise<KeyHandlerResult>;
/**
 * Create the key handler closure that captures projectPath.
 */
export declare function createKeyHandler(projectPath: string, callbacks?: KeyHandlerCallbacks): KeyHandler;
export interface BoardOptions {
    projectPath: string;
    projectName: string;
    limit?: number;
    filter?: string;
}
/**
 * Run the interactive kanban board TUI loop.
 */
export declare function runBoard(opts: BoardOptions): Promise<void>;
export declare const boardCommand: Command;
//# sourceMappingURL=board.d.ts.map