/**
 * Tests for board column sorting functionality.
 *
 * @module src/cli/commands/__tests__/board-sorting.test
 */

import { describe, it, expect } from "vitest";
import {
  sortBoardTasks,
  sortBoardColumns,
  type BoardStatus,
  type BoardTask,
  type SortMode,
  SORT_MODE_LABELS,
} from "../board.js";

// Constants matching board.ts
const BOARD_STATUSES: readonly BoardStatus[] = [
  "backlog",
  "ready",
  "in_progress",
  "needs_attention",
  "closed",
] as const;

describe("sortBoardTasks", () => {
  // Helper to create a board task
  const createTask = (
    id: string,
    priority: number,
    updatedAt: string,
    overrides: Partial<BoardTask> = {},
  ): BoardTask => ({
    id,
    title: `Task ${id}`,
    description: null,
    type: "task",
    priority,
    status: "backlog",
    external_id: null,
    created_at: updatedAt,
    updated_at: updatedAt,
    approved_at: null,
    closed_at: null,
    ...overrides,
  });

  describe("'updated' sort mode (default)", () => {
    it("should sort tasks by updated_at descending (most recent first)", () => {
      const tasks: BoardTask[] = [
        createTask("task-1", 2, "2026-04-19T10:00:00Z"),
        createTask("task-2", 2, "2026-04-20T10:00:00Z"), // Most recent
        createTask("task-3", 2, "2026-04-18T10:00:00Z"),
      ];

      const sorted = sortBoardTasks(tasks, "updated");

      expect(sorted[0].id).toBe("task-2");
      expect(sorted[1].id).toBe("task-1");
      expect(sorted[2].id).toBe("task-3");
    });

    it("should handle empty array", () => {
      const tasks: BoardTask[] = [];
      const sorted = sortBoardTasks(tasks, "updated");
      expect(sorted).toEqual([]);
    });

    it("should handle single task", () => {
      const tasks = [createTask("task-1", 2, "2026-04-19T10:00:00Z")];
      const sorted = sortBoardTasks(tasks, "updated");
      expect(sorted).toHaveLength(1);
      expect(sorted[0].id).toBe("task-1");
    });

    it("should treat invalid updated_at values as oldest", () => {
      const tasks: BoardTask[] = [
        createTask("task-invalid", 2, "not-a-date"),
        createTask("task-valid", 2, "2026-04-20T10:00:00Z"),
      ];

      const sorted = sortBoardTasks(tasks, "updated");

      expect(sorted.map((t) => t.id)).toEqual(["task-valid", "task-invalid"]);
    });

    it("should maintain relative order for same updated_at", () => {
      const sameTime = "2026-04-19T10:00:00Z";
      const tasks: BoardTask[] = [
        createTask("task-1", 2, sameTime),
        createTask("task-2", 2, sameTime),
        createTask("task-3", 2, sameTime),
      ];

      const sorted = sortBoardTasks(tasks, "updated");

      // Should maintain original relative order (stable sort)
      expect(sorted.map((t) => t.id)).toEqual(["task-1", "task-2", "task-3"]);
    });
  });

  describe("'priority' sort mode", () => {
    it("should sort tasks by priority ascending (P0 first)", () => {
      const tasks: BoardTask[] = [
        createTask("task-1", 2, "2026-04-19T10:00:00Z"),
        createTask("task-2", 0, "2026-04-19T10:00:00Z"), // P0
        createTask("task-3", 1, "2026-04-19T10:00:00Z"), // P1
      ];

      const sorted = sortBoardTasks(tasks, "priority");

      expect(sorted[0].id).toBe("task-2"); // P0
      expect(sorted[1].id).toBe("task-3"); // P1
      expect(sorted[2].id).toBe("task-1"); // P2
    });

    it("should sort invalid updated_at values last within same priority", () => {
      const tasks: BoardTask[] = [
        createTask("task-invalid", 2, "not-a-date"),
        createTask("task-valid", 2, "2026-04-20T10:00:00Z"),
      ];

      const sorted = sortBoardTasks(tasks, "priority");

      expect(sorted.map((t) => t.id)).toEqual(["task-valid", "task-invalid"]);
    });

    it("should sort by updated_at descending within same priority", () => {
      const tasks: BoardTask[] = [
        createTask("task-1", 2, "2026-04-18T10:00:00Z"),
        createTask("task-2", 2, "2026-04-20T10:00:00Z"), // Most recent, same priority
        createTask("task-3", 2, "2026-04-19T10:00:00Z"),
      ];

      const sorted = sortBoardTasks(tasks, "priority");

      expect(sorted[0].id).toBe("task-2"); // Most recent first
      expect(sorted[1].id).toBe("task-3");
      expect(sorted[2].id).toBe("task-1");
    });

    it("should handle all priority levels", () => {
      const tasks: BoardTask[] = [
        createTask("task-0", 0, "2026-04-19T10:00:00Z"), // P0
        createTask("task-4", 4, "2026-04-19T10:00:00Z"), // P4
        createTask("task-1", 1, "2026-04-19T10:00:00Z"), // P1
        createTask("task-3", 3, "2026-04-19T10:00:00Z"), // P3
        createTask("task-2", 2, "2026-04-19T10:00:00Z"), // P2
      ];

      const sorted = sortBoardTasks(tasks, "priority");

      expect(sorted.map((t) => t.priority)).toEqual([0, 1, 2, 3, 4]);
    });
  });

  describe("does not mutate original array", () => {
    it("should return a new sorted array", () => {
      const tasks: BoardTask[] = [
        createTask("task-1", 2, "2026-04-19T10:00:00Z"),
        createTask("task-2", 1, "2026-04-20T10:00:00Z"),
      ];

      const sorted = sortBoardTasks(tasks, "priority");

      expect(sorted).not.toBe(tasks);
      expect(tasks[0].id).toBe("task-1");
      expect(sorted[0].id).toBe("task-2");
    });
  });
});

describe("sortBoardColumns", () => {
  // Helper to create a board task
  const createTask = (
    id: string,
    priority: number,
    updatedAt: string,
    overrides: Partial<BoardTask> = {},
  ): BoardTask => ({
    id,
    title: `Task ${id}`,
    description: null,
    type: "task",
    priority,
    status: "backlog",
    external_id: null,
    created_at: updatedAt,
    updated_at: updatedAt,
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

  it("should sort tasks in each column", () => {
    const map = createTasksMap({
      backlog: [
        createTask("task-1", 2, "2026-04-19T10:00:00Z"),
        createTask("task-2", 1, "2026-04-20T10:00:00Z"), // More recent
      ],
      ready: [
        createTask("task-3", 0, "2026-04-19T10:00:00Z"), // P0
        createTask("task-4", 2, "2026-04-21T10:00:00Z"), // Most recent
      ],
    });

    const sorted = sortBoardColumns(map, "updated");

    // Backlog: task-2 (most recent) should be first
    expect(sorted.get("backlog")![0].id).toBe("task-2");
    expect(sorted.get("backlog")![1].id).toBe("task-1");

    // Ready: task-4 (most recent) should be first
    expect(sorted.get("ready")![0].id).toBe("task-4");
    expect(sorted.get("ready")![1].id).toBe("task-3");
  });

  it("should sort by priority when mode is 'priority'", () => {
    const map = createTasksMap({
      backlog: [
        createTask("task-1", 2, "2026-04-19T10:00:00Z"),
        createTask("task-2", 0, "2026-04-19T10:00:00Z"), // P0
      ],
    });

    const sorted = sortBoardColumns(map, "priority");

    expect(sorted.get("backlog")![0].id).toBe("task-2"); // P0 first
    expect(sorted.get("backlog")![1].id).toBe("task-1"); // P2 second
  });

  it("should preserve empty columns", () => {
    const map = createTasksMap({
      backlog: [],
      ready: [createTask("task-1", 2, "2026-04-19T10:00:00Z")],
    });

    const sorted = sortBoardColumns(map, "updated");

    expect(sorted.get("backlog")).toEqual([]);
    expect(sorted.get("ready")).toHaveLength(1);
  });

  it("should not mutate original map", () => {
    const map = createTasksMap({
      backlog: [createTask("task-1", 2, "2026-04-19T10:00:00Z")],
    });

    const sorted = sortBoardColumns(map, "priority");

    expect(sorted).not.toBe(map);
    expect(map.get("backlog")![0].id).toBe("task-1");
  });

  it("should include all board status columns", () => {
    const map = createTasksMap({});
    const sorted = sortBoardColumns(map, "updated");

    for (const status of BOARD_STATUSES) {
      expect(sorted.has(status)).toBe(true);
    }
  });
});

describe("SORT_MODE_LABELS", () => {
  it("should have labels for both sort modes", () => {
    expect(SORT_MODE_LABELS["updated"]).toBe("Updated");
    expect(SORT_MODE_LABELS["priority"]).toBe("Priority");
  });

  it("should cover all SortMode values", () => {
    const sortModes: SortMode[] = ["updated", "priority"];
    for (const mode of sortModes) {
      expect(SORT_MODE_LABELS[mode]).toBeDefined();
    }
  });
});

describe("Sort mode toggle behavior", () => {
  it("should toggle from 'updated' to 'priority'", () => {
    const currentMode: SortMode = "updated";
    const toggleMode = (mode: SortMode): SortMode => mode === "updated" ? "priority" : "updated";
    const nextMode = toggleMode(currentMode);
    expect(nextMode).toBe("priority");
  });

  it("should toggle from 'priority' to 'updated'", () => {
    const currentMode: SortMode = "priority";
    const toggleMode = (mode: SortMode): SortMode => mode === "updated" ? "priority" : "updated";
    const nextMode = toggleMode(currentMode);
    expect(nextMode).toBe("updated");
  });
});