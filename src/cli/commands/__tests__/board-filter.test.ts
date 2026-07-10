/**
 * Tests for board status filtering functionality.
 *
 * @module src/cli/commands/__tests__/board-filter.test
 */

import { describe, it, expect } from "vitest";
import {
  applyStatusFilter,
  boardColumnForTaskStatus,
  type BoardStatus,
  type BoardTask,
} from "../board.js";

// Constants matching board.ts
const BOARD_STATUSES: readonly BoardStatus[] = [
  "backlog",
  "ready",
  "in_progress",
  "needs_attention",
  "closed",
] as const;

describe("applyStatusFilter", () => {
  // Helper to create a board task
  const createTask = (
    id: string,
    status: string,
    overrides: Partial<BoardTask> = {},
  ): BoardTask => ({
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

  it("should filter to closed column for completed/closed/done/merged aliases", () => {
    const map = createTasksMap({
      backlog: [createTask("task-1", "backlog")],
      closed: [createTask("task-2", "completed"), createTask("task-3", "done")],
    });

    const filtered = applyStatusFilter(map, "completed");

    expect(filtered.get("closed")).toHaveLength(2);
    expect(filtered.get("backlog")).toHaveLength(0);
    expect(filtered.get("ready")).toHaveLength(0);
    expect(filtered.get("in_progress")).toHaveLength(0);
    expect(filtered.get("needs_attention")).toHaveLength(0);
  });

  it("should filter to in_progress for hyphenated in-progress", () => {
    const map = createTasksMap({
      backlog: [createTask("task-1", "backlog")],
      in_progress: [createTask("task-2", "developer")],
    });

    const filtered = applyStatusFilter(map, "in-progress");

    expect(filtered.get("in_progress")).toHaveLength(1);
    expect(filtered.get("backlog")).toHaveLength(0);
    expect(filtered.get("ready")).toHaveLength(0);
    expect(filtered.get("needs_attention")).toHaveLength(0);
    expect(filtered.get("closed")).toHaveLength(0);
  });

  it("should filter to needs_attention for needs-attention", () => {
    const map = createTasksMap({
      backlog: [createTask("task-1", "backlog")],
      needs_attention: [createTask("task-2", "failed"), createTask("task-3", "stuck")],
    });

    const filtered = applyStatusFilter(map, "needs-attention");

    expect(filtered.get("needs_attention")).toHaveLength(2);
    expect(filtered.get("backlog")).toHaveLength(0);
    expect(filtered.get("ready")).toHaveLength(0);
    expect(filtered.get("in_progress")).toHaveLength(0);
    expect(filtered.get("closed")).toHaveLength(0);
  });

  it("should filter to backlog for open/todo", () => {
    const map = createTasksMap({
      backlog: [createTask("task-1", "open"), createTask("task-2", "todo")],
      ready: [createTask("task-3", "ready")],
    });

    const filtered = applyStatusFilter(map, "open");

    expect(filtered.get("backlog")).toHaveLength(2);
    expect(filtered.get("ready")).toHaveLength(0);
    expect(filtered.get("in_progress")).toHaveLength(0);
    expect(filtered.get("needs_attention")).toHaveLength(0);
    expect(filtered.get("closed")).toHaveLength(0);
  });

  it("should handle unknown status filter by routing to closed", () => {
    const map = createTasksMap({
      backlog: [createTask("task-1", "backlog")],
      closed: [createTask("task-2", "completed")],
    });

    // Unknown status "xyz" should go to closed column
    const filtered = applyStatusFilter(map, "xyz");

    expect(filtered.get("closed")).toHaveLength(1);
    expect(filtered.get("backlog")).toHaveLength(0);
  });

  it("should preserve all columns in output map", () => {
    const map = createTasksMap({});
    const filtered = applyStatusFilter(map, "backlog");

    for (const status of BOARD_STATUSES) {
      expect(filtered.has(status)).toBe(true);
    }
  });

  it("should handle empty input map", () => {
    const map = createTasksMap({});
    const filtered = applyStatusFilter(map, "in_progress");

    for (const status of BOARD_STATUSES) {
      expect(filtered.get(status)).toEqual([]);
    }
  });

  it("should handle underscore variants", () => {
    const map = createTasksMap({
      in_progress: [createTask("task-1", "developer")],
      needs_attention: [createTask("task-2", "blocked")],
    });

    const filtered1 = applyStatusFilter(map, "in_progress");
    expect(filtered1.get("in_progress")).toHaveLength(1);

    const filtered2 = applyStatusFilter(map, "needs_attention");
    expect(filtered2.get("needs_attention")).toHaveLength(1);
  });
});

describe("boardColumnForTaskStatus status alias handling", () => {
  it("should map open/todo to backlog", () => {
    expect(boardColumnForTaskStatus("open")).toBe("backlog");
    expect(boardColumnForTaskStatus("todo")).toBe("backlog");
  });

  it("should map merged/completed/done to closed", () => {
    expect(boardColumnForTaskStatus("merged")).toBe("closed");
    expect(boardColumnForTaskStatus("completed")).toBe("closed");
    expect(boardColumnForTaskStatus("done")).toBe("closed");
  });

  it("should map hyphenated statuses correctly", () => {
    expect(boardColumnForTaskStatus("in-progress")).toBe("in_progress");
    expect(boardColumnForTaskStatus("needs-attention")).toBe("needs_attention");
  });

  it("should map unknown statuses to closed (not needs_attention)", () => {
    expect(boardColumnForTaskStatus("unknown-status")).toBe("closed");
    expect(boardColumnForTaskStatus("random-xyz")).toBe("closed");
  });
});
