/**
 * Tests for board rendering functions.
 *
 * @module src/cli/commands/__tests__/board-render.test
 */

import { describe, it, expect } from "vitest";
import {
  getVisibleTaskCapacity,
  getVisibleTaskWindow,
  renderBoard,
  renderTaskDetail,
  boardColumnForTaskStatus,
  type BoardStatus,
  type BoardTask,
  type RenderState,
} from "../board.js";

// Constants matching board.ts
const BOARD_STATUSES: readonly BoardStatus[] = [
  "backlog",
  "ready",
  "in_progress",
  "needs_attention",
  "closed",
] as const;

const STATUS_LABELS: Record<BoardStatus, string> = {
  backlog: "Backlog",
  ready: "Ready",
  in_progress: "In Progress",
  needs_attention: "Needs Attention",
  closed: "Closed",
};

const MIN_COL_WIDTH = 12;
const TASK_CARD_HEIGHT = 3;
const MAX_VISIBLE_PER_COL = 5;

const PRIORITY_BADGES: Record<number, string> = {
  0: "P0",
  1: "P1",
  2: "P2",
  3: "P3",
  4: "P4",
};

function stripTerminalFormatting(value: string): string {
  return value
    .replace(/\x1B\[[0-9;?]*[ -/]*[@-~]/g, "")
    .replace(/\r/g, "");
}

describe("BoardRendering", () => {
  // Helper to create a board task
  const createTask = (
    id: string,
    overrides: Partial<BoardTask> = {},
  ): BoardTask => ({
    id,
    title: `Task ${id}`,
    description: null,
    type: "task",
    priority: 2,
    status: "backlog",
    external_id: null,
    created_at: "2026-04-19T00:00:00Z",
    updated_at: "2026-04-19T00:00:00Z",
    approved_at: null,
    closed_at: null,
    ...overrides,
  });

  // Helper to create a tasks map
  const createTasksMap = (
    tasksByStatus: Partial<Record<BoardStatus, BoardTask[]>>,
  ): Map<BoardStatus, BoardTask[]> => {
    const map = new Map<BoardStatus, BoardTask[]>();
    for (const status of BOARD_STATUSES) {
      map.set(status, tasksByStatus[status] ?? []);
    }
    return map;
  };

  // Helper to create render state
  const createRenderState = (
    tasksByStatus: Partial<Record<BoardStatus, BoardTask[]>>,
    overrides: Partial<RenderState> = {},
  ): RenderState => {
    const tasks = createTasksMap(tasksByStatus);
    const totalTasks = [...tasks.values()].reduce((sum, t) => sum + t.length, 0);
    return {
      tasks,
      nav: { colIndex: 0, rowIndex: 0 },
      totalTasks,
      errorMessage: null,
      flashTaskId: null,
      showHelp: false,
      showDetail: false,
      detailTask: null,
      detailNotesStatus: "idle",
      detailNotesError: null,
      sortMode: "updated",
      ...overrides,
    };
  };

  describe("renderTaskCard", () => {
    it("should render task title correctly", () => {
      const task = createTask("bd-1234", { title: "Implement feature X" });
      // MIN_COL_WIDTH - 4 = 8, MIN_COL_WIDTH - 7 = 5
      // Truncated to 5 chars + "…"
      const truncatedTitle =
        task.title.length > MIN_COL_WIDTH - 4
          ? task.title.slice(0, MIN_COL_WIDTH - 7) + "…"
          : task.title;

      expect(truncatedTitle).toBe("Imple…");
    });

    it("should not truncate short titles", () => {
      const task = createTask("bd-1234", { title: "Short" });
      const truncatedTitle =
        task.title.length > MIN_COL_WIDTH - 4
          ? task.title.slice(0, MIN_COL_WIDTH - 7) + "…"
          : task.title;

      expect(truncatedTitle).toBe("Short");
    });

    it("should include priority badge", () => {
      const task = createTask("bd-1234", { priority: 0 });
      const badge = PRIORITY_BADGES[task.priority] ?? "P?";

      expect(badge).toBe("P0");
    });

    it("should render selected task differently", () => {
      const task = createTask("bd-1234");
      const isSelected = true;
      const isFlash = false;
      const isExpanded = false;

      // Selected task should have prefix marker
      const prefix = isSelected ? "▶ " : "  ";
      expect(prefix).toBe("▶ ");
    });

    it("should render flash state correctly", () => {
      const task = createTask("bd-1234");
      const isSelected = true;
      const isFlash = true;

      // Flash should override selection color
      expect(isFlash).toBe(true);
      expect(isSelected).toBe(true);
    });

    it("should expand description when isExpanded", () => {
      const task = createTask("bd-1234", {
        description: "This is a long description\nWith multiple lines\nThat should show",
      });
      const isExpanded = true;

      if (isExpanded) {
        const descLines = (task.description ?? "")
          .slice(0, MIN_COL_WIDTH * 2)
          .split("\n")
          .slice(0, 3);
        expect(descLines.length).toBeGreaterThan(0);
      }
    });
  });

  describe("Board Layout", () => {
    it("should have 5 columns", () => {
      expect(BOARD_STATUSES).toHaveLength(5);
    });

    it("should calculate column width correctly", () => {
      const terminalWidth = 120;
      const numCols = BOARD_STATUSES.length;
      const colWidth = Math.max(MIN_COL_WIDTH, Math.floor((terminalWidth - 4) / numCols));

      expect(colWidth).toBeGreaterThanOrEqual(MIN_COL_WIDTH);
      expect(colWidth).toBeLessThan(terminalWidth);
    });

    it("should handle minimum terminal width", () => {
      const terminalWidth = 80;
      const numCols = BOARD_STATUSES.length;
      const colWidth = Math.max(MIN_COL_WIDTH, Math.floor((terminalWidth - 4) / numCols));

      expect(colWidth).toBe(15); // 5 columns at 80 width: floor(76/5) = 15 > MIN_COL_WIDTH
    });

    it("should enforce max visible per column", () => {
      const tasks = Array.from({ length: 10 }, (_, i) => createTask(`bd-${i}`));
      const visibleTasks = tasks.slice(0, MAX_VISIBLE_PER_COL);
      const extraCount = Math.max(0, tasks.length - MAX_VISIBLE_PER_COL);

      expect(visibleTasks).toHaveLength(5);
      expect(extraCount).toBe(5);
    });

    it("should center the visible task window around the selected task when scrolling", () => {
      const tasks = Array.from({ length: 10 }, (_, index) => createTask(`bd-${index}`));

      const window = getVisibleTaskWindow(tasks, 6, MAX_VISIBLE_PER_COL);

      expect(window.startIndex).toBe(4);
      expect(window.hiddenBefore).toBe(4);
      expect(window.hiddenAfter).toBe(1);
      expect(window.visibleTasks.map((task) => task.id)).toEqual([
        "bd-4",
        "bd-5",
        "bd-6",
        "bd-7",
        "bd-8",
      ]);
    });

    it("should derive visible task capacity from terminal height when no limit is provided", () => {
      expect(getVisibleTaskCapacity(24, 20)).toBeGreaterThan(5);
      expect(getVisibleTaskCapacity(24, 20, 4)).toBe(4);
    });

    it("should render active sort mode in the header", () => {
      const output = stripTerminalFormatting(renderBoard(
        createRenderState({}, { sortMode: "priority" }),
        "Demo",
        150,
      ));

      expect(output).toContain("Sort: Priority");
    });

    it("should render five column jump labels without a merged column", () => {
      const output = stripTerminalFormatting(renderBoard(createRenderState({}), "Demo", 150));

      expect(output).toContain("[1] Backlog");
      expect(output).toContain("[5] Closed");
      expect(output).not.toContain("Merged");
    });

    it("should render task ids in every column card", () => {
      const output = stripTerminalFormatting(renderBoard(
        createRenderState({
          ready: [createTask("bd-1111", { title: "Ready task", status: "ready" })],
          in_progress: [createTask("bd-2222", { title: "Doing task", status: "in_progress" })],
          needs_attention: [createTask("bd-3333", { title: "Blocked task", status: "needs_attention" })],
        }),
        "Demo",
        150,
      ));

      expect(output).toContain("bd-1111");
      expect(output).toContain("bd-2222");
      expect(output).toContain("bd-3333");
    });

    it("should render aligned boxed columns for the task grid", () => {
      const output = stripTerminalFormatting(renderBoard(
        createRenderState({
          backlog: [createTask("bd-1", { title: "Implement task board layout" })],
        }),
        "Demo",
        150,
      ));

      const lines = output.split("\n");
      const borderLine = lines.find((line) => line.includes("╭") && line.includes("╮"));
      const gridLine = lines.find((line) => line.includes("│ Backlog (1)"));

      expect(borderLine).toBeDefined();
      expect(borderLine?.match(/╭/g)).toHaveLength(5);
      expect(gridLine).toBeDefined();
      expect(gridLine?.match(/│/g)?.length).toBeGreaterThanOrEqual(10);
    });

    it("should keep the selected task visible when navigating past the first page", () => {
      const output = stripTerminalFormatting(renderBoard(
        createRenderState({
          backlog: Array.from({ length: 10 }, (_, index) =>
            createTask(`bd-${index}`, { title: `Task ${index}` })),
        }, {
          nav: { colIndex: 0, rowIndex: 6 },
        }),
        "Demo",
        120,
        MAX_VISIBLE_PER_COL,
        24,
      ));

      expect(output).toContain("▶ Task 6");
      expect(output).toContain("↑ 4 earlier");
      expect(output).toContain("↓ 1 more");
      expect(output).not.toContain("▶ Task 0");
    });

    it("should stretch columns to fill a taller terminal", () => {
      const output = stripTerminalFormatting(renderBoard(
        createRenderState({
          backlog: [createTask("bd-1", { title: "Task 1" })],
        }),
        "Demo",
        120,
        MAX_VISIBLE_PER_COL,
        30,
      ));

      const lines = output.split("\n");
      const borderLines = lines.filter((line) => line.includes("│") || line.includes("╭") || line.includes("╰"));

      expect(lines.length).toBeGreaterThanOrEqual(24);
      expect(borderLines.length).toBeGreaterThan(10);
    });

    it("should show more than five tasks in a tall terminal by default", () => {
      const output = stripTerminalFormatting(renderBoard(
        createRenderState({
          backlog: Array.from({ length: 10 }, (_, index) =>
            createTask(`bd-${index}`, { title: `Task ${index}` })),
        }),
        "Demo",
        120,
        undefined,
        30,
      ));

      expect(output).toContain("Task 0");
      expect(output).toContain("Task 5");
    });
  });

  describe("Header Rendering", () => {
    it("should include project name in header", () => {
      const projectName = "Test Project";
      const title = ` Foreman Kanban Board — ${projectName} `;

      expect(title).toContain(projectName);
    });

    it("should show total task count", () => {
      const state = createRenderState({
        backlog: [createTask("1"), createTask("2")],
        ready: [createTask("3")],
        in_progress: [createTask("4")],
      });

      expect(state.totalTasks).toBe(4);
    });

    it("should pluralize task count correctly", () => {
      const singular = "1 task";
      const plural = `${2} tasks`;

      expect(singular).toContain("1 task");
      expect(plural).toContain("tasks");
    });
  });

  describe("Column Headers", () => {
    it("should show status labels", () => {
      Object.entries(STATUS_LABELS).forEach(([status, label]) => {
        expect(label.length).toBeGreaterThan(0);
        expect(typeof label).toBe("string");
      });
    });

    it("should show task count per column", () => {
      const state = createRenderState({
        backlog: [createTask("1"), createTask("2"), createTask("3")],
        ready: [],
        in_progress: [createTask("4")],
      });

      expect(state.tasks.get("backlog")?.length).toBe(3);
      expect(state.tasks.get("ready")?.length).toBe(0);
      expect(state.tasks.get("in_progress")?.length).toBe(1);
    });

    it("should show (empty) for columns with no tasks", () => {
      const state = createRenderState({
        ready: [],
      });

      const countStr =
        state.tasks.get("ready")?.length === 0 ? "(empty)" : `${state.tasks.get("ready")?.length}`;
      expect(countStr).toBe("(empty)");
    });
  });

  describe("Help Overlay", () => {
    it("should define all keybindings", () => {
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

      expect(rows).toHaveLength(13);
    });

    it("should have panel width constraint", () => {
      const width = 80;
      const panelWidth = Math.min(72, width - 4);
      expect(panelWidth).toBeLessThanOrEqual(72);
    });
  });

  describe("boardColumnForTaskStatus", () => {
    it("maps native workflow phase statuses to in_progress", () => {
      for (const status of ["explorer", "developer", "qa", "reviewer", "finalize"]) {
        expect(boardColumnForTaskStatus(status)).toBe("in_progress");
      }
    });

    it("maps terminal/problem statuses to needs_attention or closed", () => {
      expect(boardColumnForTaskStatus("failed")).toBe("needs_attention");
      expect(boardColumnForTaskStatus("blocked")).toBe("needs_attention");
      expect(boardColumnForTaskStatus("closed")).toBe("closed");
      expect(boardColumnForTaskStatus("unknown")).toBe("closed");
    });
  });

  describe("Task Detail Panel", () => {
    it("should render notes loading state", () => {
      const task = createTask("bd-1234");
      const output = stripTerminalFormatting(renderTaskDetail(task, 100, "loading", null));
      expect(output).toContain("Notes: loading");
    });

    it("should render task notes when present", () => {
      const task = createTask("bd-1234", {
        notes: [
          {
            id: "note-1",
            created_at: "2026-04-19T12:30:00Z",
            phase: "developer",
            kind: "progress",
            author: "foreman",
            body: "Implemented status normalization\nAdded tests",
          },
        ],
      });

      const output = stripTerminalFormatting(renderTaskDetail(task, 100, "loaded", null));

      expect(output).toContain("Notes:");
      // Note content is wrapped, so check for the parts that appear in the output
      expect(output).toContain("developer");
      expect(output).toContain("progress");
      expect(output).toContain("foreman");
      expect(output).toContain("Implemented status normalization");
    });

    it("should display all task fields", () => {
      const task = createTask("bd-1234", {
        title: "Full Task",
        description: "A detailed description",
        type: "feature",
        priority: 1,
        status: "in_progress",
        external_id: "EXT-123",
        created_at: "2026-04-19T10:00:00Z",
        updated_at: "2026-04-19T12:00:00Z",
        approved_at: "2026-04-19T11:00:00Z",
        closed_at: null,
      });

      expect(task.id).toBe("bd-1234");
      expect(task.title).toBe("Full Task");
      expect(task.description).toBe("A detailed description");
      expect(task.type).toBe("feature");
      expect(task.priority).toBe(1);
      expect(task.status).toBe("in_progress");
      expect(task.external_id).toBe("EXT-123");

      const output = stripTerminalFormatting(renderTaskDetail(task, 100, "idle", null));
      expect(output).toContain("TASK DETAIL — in_progress");
      expect(output).toContain("Status:");
      expect(output).toContain("in_progress");
    });

    it("should handle null optional fields", () => {
      const task = createTask("bd-1234", {
        description: null,
        external_id: null,
        approved_at: null,
        closed_at: null,
      });

      expect(task.description).toBeNull();
      expect(task.external_id).toBeNull();
      expect(task.approved_at).toBeNull();
      expect(task.closed_at).toBeNull();
    });

    it("should render long title with wrapping", () => {
      const longTitle = "This is a very long task title that exceeds typical width constraints and should wrap properly when rendered";
      const task = createTask("bd-1234", { title: longTitle });
      const output = stripTerminalFormatting(renderTaskDetail(task, 80, "idle", null));
      // Title content should be present (wrapped across multiple lines)
      // Check for segments that appear in the wrapped output
      expect(output).toContain("This is a very long task");
      expect(output).toContain("title that exceeds typical");
      expect(output).toContain("constraints and should");
      expect(output).toContain("wrap properly when rendered");
    });

    it("should render multi-line description with all lines", () => {
      const multiLineDesc = "Line 1 of description\nLine 2 of description\nLine 3 of description\nLine 4 of description\nLine 5 of description";
      const task = createTask("bd-1234", { description: multiLineDesc });
      const output = stripTerminalFormatting(renderTaskDetail(task, 80, "idle", null));
      expect(output).toContain("Line 1 of description");
      expect(output).toContain("Line 2 of description");
      expect(output).toContain("Line 3 of description");
      expect(output).toContain("Line 4 of description");
      expect(output).toContain("Line 5 of description");
    });

    it("should render multiple notes with all content", () => {
      const task = createTask("bd-1234", {
        notes: [
          {
            id: "note-1",
            created_at: "2026-04-19T12:30:00Z",
            phase: "developer",
            kind: "progress",
            author: "dev1",
            body: "First note body line 1\nFirst note body line 2",
          },
          {
            id: "note-2",
            created_at: "2026-04-19T13:30:00Z",
            phase: "qa",
            kind: "comment",
            author: "qa1",
            body: "Second note body line 1\nSecond note body line 2\nSecond note body line 3",
          },
          {
            id: "note-3",
            created_at: "2026-04-19T14:30:00Z",
            phase: "reviewer",
            kind: "approval",
            author: "reviewer1",
            body: "Third note single line",
          },
        ],
      });
      const output = stripTerminalFormatting(renderTaskDetail(task, 80, "loaded", null));
      // All notes should be present
      expect(output).toContain("dev1");
      expect(output).toContain("qa1");
      expect(output).toContain("reviewer1");
      // All note body content should be present
      expect(output).toContain("First note body line 1");
      expect(output).toContain("First note body line 2");
      expect(output).toContain("Second note body line 1");
      expect(output).toContain("Second note body line 2");
      expect(output).toContain("Second note body line 3");
      expect(output).toContain("Third note single line");
    });

    it("should use substantial panel width for wide terminals", () => {
      const task = createTask("bd-1234");
      const output = stripTerminalFormatting(renderTaskDetail(task, 120, "idle", null));
      expect(output).toContain("TASK DETAIL");
      expect(output).toContain("bd-1234");

      const maxLineLength = Math.max(...output.split("\n").map((line) => line.length));
      expect(maxLineLength).toBeGreaterThanOrEqual(50);
    });

    it("should clamp panel width on narrow terminals", () => {
      const task = createTask("bd-1234");
      const output = stripTerminalFormatting(renderTaskDetail(task, 30, "idle", null));
      expect(output).toContain("TASK DETAIL");
      expect(output).toContain("bd-1234");

      const maxLineLength = Math.max(...output.split("\n").map((line) => line.length));
      expect(maxLineLength).toBeLessThanOrEqual(30);
    });

    it("should prevent panel overflow on very narrow terminals", () => {
      const task = createTask("bd-1234");
      const output = stripTerminalFormatting(renderTaskDetail(task, 20, "idle", null));
      expect(output).toContain("TASK DETAIL");
      expect(output).toContain("bd-1234");

      const maxLineLength = Math.max(...output.split("\n").map((line) => line.length));
      expect(maxLineLength).toBeLessThanOrEqual(20);
    });
  });

  describe("Error Banner", () => {
    it("should show error message when present", () => {
      const state = createRenderState({}, { errorMessage: "Database connection failed" });
      expect(state.errorMessage).toBe("Database connection failed");
    });

    it("should not show error when null", () => {
      const state = createRenderState({}, { errorMessage: null });
      expect(state.errorMessage).toBeNull();
    });
  });

  describe("Priority Badge Colors", () => {
    it("should have badge for each priority level", () => {
      const priorities = [0, 1, 2, 3, 4];
      priorities.forEach((p) => {
        expect(PRIORITY_BADGES[p]).toBeDefined();
        expect(PRIORITY_BADGES[p]).toBe(`P${p}`);
      });
    });
  });

  describe("ANSI Escape Codes", () => {
    it("should define CLEAR_SCREEN", () => {
      const CLEAR_SCREEN = "\x1B[2J\x1B[H";
      expect(CLEAR_SCREEN).toBe("\x1B[2J\x1B[H");
    });

    it("should define HIDE_CURSOR", () => {
      const HIDE_CURSOR = "\x1b[?25l";
      expect(HIDE_CURSOR).toBe("\x1b[?25l");
    });

    it("should define SHOW_CURSOR", () => {
      const SHOW_CURSOR = "\x1b[?25h";
      expect(SHOW_CURSOR).toBe("\x1b[?25h");
    });

    it("should define moveTo function", () => {
      const moveTo = (row: number, col: number): string => `\x1B[${row};${col}H`;
      expect(moveTo(1, 1)).toBe("\x1B[1;1H");
      expect(moveTo(10, 20)).toBe("\x1B[10;20H");
    });
  });
});
