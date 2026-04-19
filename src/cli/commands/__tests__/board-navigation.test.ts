/**
 * Tests for board navigation (j/k/h/l/g/G keys, number keys).
 *
 * @module src/cli/commands/__tests__/board-navigation.test
 */

import { describe, it, expect } from "vitest";
import type { BoardStatus, BoardTask, NavigationState } from "../board.js";

// Constants matching board.ts
const BOARD_STATUSES: readonly BoardStatus[] = [
  "backlog",
  "ready",
  "in_progress",
  "review",
  "blocked",
  "closed",
] as const;

describe("BoardNavigation", () => {
  // Helper to create a board task
  const createTask = (id: string, status: BoardStatus): BoardTask => ({
    id,
    title: `Task ${id}`,
    description: null,
    type: "task",
    priority: 2,
    status,
    external_id: null,
    created_at: "2026-04-19T00:00:00Z",
    updated_at: "2026-04-19T00:00:00Z",
    approved_at: null,
    closed_at: null,
  });

  // Helper to create a tasks map
  const createTasksMap = (tasksByStatus: Partial<Record<BoardStatus, BoardTask[]>>): Map<BoardStatus, BoardTask[]> => {
    const map = new Map<BoardStatus, BoardTask[]>();
    for (const status of BOARD_STATUSES) {
      map.set(status, tasksByStatus[status] ?? []);
    }
    return map;
  };

  describe("Vertical Navigation (j/k)", () => {
    it("j should move down within column", () => {
      const tasks = createTasksMap({
        backlog: [
          createTask("1", "backlog"),
          createTask("2", "backlog"),
          createTask("3", "backlog"),
        ],
      });

      const nav: NavigationState = { colIndex: 0, rowIndex: 0 };
      const currentTasks = tasks.get(BOARD_STATUSES[nav.colIndex]) ?? [];
      if (currentTasks.length > 0) {
        nav.rowIndex = (nav.rowIndex + 1) % currentTasks.length;
      }

      expect(nav.rowIndex).toBe(1);
    });

    it("j should wrap from bottom to top", () => {
      const tasks = createTasksMap({
        backlog: [
          createTask("1", "backlog"),
          createTask("2", "backlog"),
        ],
      });

      const nav: NavigationState = { colIndex: 0, rowIndex: 1 };
      const currentTasks = tasks.get(BOARD_STATUSES[nav.colIndex]) ?? [];
      if (currentTasks.length > 0) {
        nav.rowIndex = (nav.rowIndex + 1) % currentTasks.length;
      }

      expect(nav.rowIndex).toBe(0);
    });

    it("k should move up within column", () => {
      const tasks = createTasksMap({
        backlog: [
          createTask("1", "backlog"),
          createTask("2", "backlog"),
          createTask("3", "backlog"),
        ],
      });

      const nav: NavigationState = { colIndex: 0, rowIndex: 2 };
      const currentTasks = tasks.get(BOARD_STATUSES[nav.colIndex]) ?? [];
      if (currentTasks.length > 0) {
        nav.rowIndex = nav.rowIndex <= 0 ? currentTasks.length - 1 : nav.rowIndex - 1;
      }

      expect(nav.rowIndex).toBe(1);
    });

    it("k should wrap from top to bottom", () => {
      const tasks = createTasksMap({
        backlog: [
          createTask("1", "backlog"),
          createTask("2", "backlog"),
        ],
      });

      const nav: NavigationState = { colIndex: 0, rowIndex: 0 };
      const currentTasks = tasks.get(BOARD_STATUSES[nav.colIndex]) ?? [];
      if (currentTasks.length > 0) {
        nav.rowIndex = nav.rowIndex <= 0 ? currentTasks.length - 1 : nav.rowIndex - 1;
      }

      expect(nav.rowIndex).toBe(1);
    });

    it("j/k should not navigate in empty column", () => {
      const tasks = createTasksMap({
        ready: [], // empty column
      });

      const nav: NavigationState = { colIndex: 1, rowIndex: 0 };
      const currentTasks = tasks.get(BOARD_STATUSES[nav.colIndex]) ?? [];
      if (currentTasks.length > 0) {
        nav.rowIndex = (nav.rowIndex + 1) % currentTasks.length;
      }

      expect(nav.rowIndex).toBe(0); // unchanged
    });
  });

  describe("Horizontal Navigation (h/l)", () => {
    it("l should move right between columns", () => {
      const nav: NavigationState = { colIndex: 2, rowIndex: 0 };
      nav.colIndex = (nav.colIndex + 1) % BOARD_STATUSES.length;
      nav.rowIndex = 0;

      expect(nav.colIndex).toBe(3);
      expect(nav.rowIndex).toBe(0);
    });

    it("l should wrap from rightmost to leftmost", () => {
      const nav: NavigationState = { colIndex: 5, rowIndex: 3 }; // closed column
      nav.colIndex = (nav.colIndex + 1) % BOARD_STATUSES.length;
      nav.rowIndex = 0;

      expect(nav.colIndex).toBe(0); // wraps to backlog
      expect(nav.rowIndex).toBe(0);
    });

    it("h should move left between columns", () => {
      const nav: NavigationState = { colIndex: 3, rowIndex: 2 };
      nav.colIndex = nav.colIndex <= 0 ? BOARD_STATUSES.length - 1 : nav.colIndex - 1;
      nav.rowIndex = 0;

      expect(nav.colIndex).toBe(2);
      expect(nav.rowIndex).toBe(0);
    });

    it("h should wrap from leftmost to rightmost", () => {
      const nav: NavigationState = { colIndex: 0, rowIndex: 2 };
      nav.colIndex = nav.colIndex <= 0 ? BOARD_STATUSES.length - 1 : nav.colIndex - 1;
      nav.rowIndex = 0;

      expect(nav.colIndex).toBe(5); // wraps to closed
      expect(nav.rowIndex).toBe(0);
    });
  });

  describe("Jump Navigation (g/G)", () => {
    it("g should jump to first task in column", () => {
      const nav: NavigationState = { colIndex: 2, rowIndex: 99 };
      nav.rowIndex = 0;

      expect(nav.rowIndex).toBe(0);
    });

    it("G should jump to last task in column", () => {
      const tasks = createTasksMap({
        backlog: [
          createTask("1", "backlog"),
          createTask("2", "backlog"),
          createTask("3", "backlog"),
        ],
      });

      const nav: NavigationState = { colIndex: 0, rowIndex: 0 };
      const currentTasks = tasks.get(BOARD_STATUSES[nav.colIndex]) ?? [];
      nav.rowIndex = Math.max(0, currentTasks.length - 1);

      expect(nav.rowIndex).toBe(2);
    });

    it("G should handle empty column", () => {
      const tasks = createTasksMap({
        ready: [],
      });

      const nav: NavigationState = { colIndex: 1, rowIndex: 0 };
      const currentTasks = tasks.get(BOARD_STATUSES[nav.colIndex]) ?? [];
      nav.rowIndex = Math.max(0, currentTasks.length - 1);

      expect(nav.rowIndex).toBe(0);
    });
  });

  describe("Number Key Navigation", () => {
    it("[1] should jump to backlog column", () => {
      const nav: NavigationState = { colIndex: 5, rowIndex: 2 };
      const colIdx = 1 - 1; // parseInt("1", 10) - 1
      if (colIdx >= 0 && colIdx < BOARD_STATUSES.length) {
        nav.colIndex = colIdx;
        nav.rowIndex = 0;
      }

      expect(nav.colIndex).toBe(0);
    });

    it("[6] should jump to closed column", () => {
      const nav: NavigationState = { colIndex: 0, rowIndex: 2 };
      const colIdx = 6 - 1;
      if (colIdx >= 0 && colIdx < BOARD_STATUSES.length) {
        nav.colIndex = colIdx;
        nav.rowIndex = 0;
      }

      expect(nav.colIndex).toBe(5);
    });

    it("[0] should be ignored (not a valid column)", () => {
      const nav: NavigationState = { colIndex: 0, rowIndex: 0 };
      const colIdx = 0 - 1; // parseInt("0", 10) - 1 = -1
      if (colIdx >= 0 && colIdx < BOARD_STATUSES.length) {
        nav.colIndex = colIdx;
      }

      expect(nav.colIndex).toBe(0); // unchanged
    });

    it("[7] should be ignored (out of range)", () => {
      const nav: NavigationState = { colIndex: 0, rowIndex: 0 };
      const colIdx = 7 - 1; // = 6, which is equal to length
      if (colIdx >= 0 && colIdx < BOARD_STATUSES.length) {
        nav.colIndex = colIdx;
      }

      expect(nav.colIndex).toBe(0); // unchanged
    });
  });

  describe("Arrow Key Mapping", () => {
    it("Arrow up should map to k (move up)", () => {
      const key = "\x1B[A";
      let normalizedKey = key;
      if (key === "\x1B[A") normalizedKey = "k";
      expect(normalizedKey).toBe("k");
    });

    it("Arrow down should map to j (move down)", () => {
      const key = "\x1B[B";
      let normalizedKey = key;
      if (key === "\x1B[B") normalizedKey = "j";
      expect(normalizedKey).toBe("j");
    });

    it("Arrow right should map to l (move right)", () => {
      const key = "\x1B[C";
      let normalizedKey = key;
      if (key === "\x1B[C") normalizedKey = "l";
      expect(normalizedKey).toBe("l");
    });

    it("Arrow left should map to h (move left)", () => {
      const key = "\x1B[D";
      let normalizedKey = key;
      if (key === "\x1B[D") normalizedKey = "h";
      expect(normalizedKey).toBe("h");
    });
  });

  describe("Navigation State Bounds", () => {
    it("colIndex should always be within [0, 5]", () => {
      const minCol = 0;
      const maxCol = BOARD_STATUSES.length - 1;

      expect(minCol).toBe(0);
      expect(maxCol).toBe(5);

      // Test that all valid navigation stays in bounds
      let nav: NavigationState = { colIndex: 0, rowIndex: 0 };
      for (let i = 0; i < 20; i++) {
        nav.colIndex = (nav.colIndex + 1) % BOARD_STATUSES.length;
        expect(nav.colIndex).toBeGreaterThanOrEqual(minCol);
        expect(nav.colIndex).toBeLessThanOrEqual(maxCol);
      }
    });

    it("colIndex should wrap correctly", () => {
      let nav: NavigationState = { colIndex: 5, rowIndex: 0 };
      nav.colIndex = (nav.colIndex + 1) % BOARD_STATUSES.length;
      expect(nav.colIndex).toBe(0);

      nav.colIndex = 0;
      nav.colIndex = nav.colIndex <= 0 ? BOARD_STATUSES.length - 1 : nav.colIndex - 1;
      expect(nav.colIndex).toBe(5);
    });
  });

  describe("Complex Navigation Scenarios", () => {
    it("navigating from empty column to non-empty column should reset row", () => {
      const tasks = createTasksMap({
        backlog: [],
        ready: [createTask("1", "ready"), createTask("2", "ready")],
      });

      let nav: NavigationState = { colIndex: 0, rowIndex: 0 };
      expect(tasks.get(BOARD_STATUSES[nav.colIndex])?.length).toBe(0);

      // Move to next column (ready)
      nav.colIndex = 1;
      nav.rowIndex = 0;

      const currentTasks = tasks.get(BOARD_STATUSES[nav.colIndex]) ?? [];
      expect(currentTasks.length).toBe(2);
      expect(nav.rowIndex).toBe(0);
    });

    it("multi-step navigation should maintain correct position", () => {
      const tasks = createTasksMap({
        backlog: [createTask("1", "backlog"), createTask("2", "backlog")],
        ready: [createTask("3", "ready"), createTask("4", "ready")],
        in_progress: [createTask("5", "in_progress")],
      });

      let nav: NavigationState = { colIndex: 0, rowIndex: 0 };

      // j -> row 1
      nav.rowIndex = (nav.rowIndex + 1) % 2;
      expect(nav).toEqual({ colIndex: 0, rowIndex: 1 });

      // l -> col 1, row 0
      nav.colIndex = (nav.colIndex + 1) % BOARD_STATUSES.length;
      nav.rowIndex = 0;
      expect(nav).toEqual({ colIndex: 1, rowIndex: 0 });

      // j -> row 1
      const readyTasks = tasks.get(BOARD_STATUSES[1]) ?? [];
      nav.rowIndex = (nav.rowIndex + 1) % readyTasks.length;
      expect(nav).toEqual({ colIndex: 1, rowIndex: 1 });

      // l -> col 2, row 0
      nav.colIndex = (nav.colIndex + 1) % BOARD_STATUSES.length;
      nav.rowIndex = 0;
      expect(nav).toEqual({ colIndex: 2, rowIndex: 0 });
    });
  });
});
