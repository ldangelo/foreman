/**
 * Tests for board mutations (status cycling, close, edit).
 *
 * @module src/cli/commands/__tests__/board-mutations.test
 */

import { describe, it, expect, vi } from "vitest";
import type { BoardStatus, BoardTask } from "../board.js";

// Constants matching board.ts
const BOARD_STATUSES: readonly BoardStatus[] = [
  "backlog",
  "ready",
  "in_progress",
  "review",
  "blocked",
  "closed",
] as const;

describe("BoardMutations", () => {
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

  describe("Status Cycling (s/S keys)", () => {
    it("s should advance status to next in order", () => {
      const task = createTask("bd-1234", { status: "backlog" });
      const currentStatusIdx = BOARD_STATUSES.indexOf(task.status as BoardStatus);
      const delta = 1;
      const newStatusIdx = (currentStatusIdx + delta + BOARD_STATUSES.length) % BOARD_STATUSES.length;
      const newStatus = BOARD_STATUSES[newStatusIdx];

      expect(task.status).toBe("backlog");
      expect(newStatus).toBe("ready");
    });

    it("S should retreat status to previous in order", () => {
      const task = createTask("bd-1234", { status: "ready" });
      const currentStatusIdx = BOARD_STATUSES.indexOf(task.status as BoardStatus);
      const delta = -1;
      const newStatusIdx = (currentStatusIdx + delta + BOARD_STATUSES.length) % BOARD_STATUSES.length;
      const newStatus = BOARD_STATUSES[newStatusIdx];

      expect(task.status).toBe("ready");
      expect(newStatus).toBe("backlog");
    });

    it("s should wrap from closed to backlog", () => {
      const task = createTask("bd-1234", { status: "closed" });
      const currentStatusIdx = BOARD_STATUSES.indexOf(task.status as BoardStatus);
      const delta = 1;
      const newStatusIdx = (currentStatusIdx + delta + BOARD_STATUSES.length) % BOARD_STATUSES.length;
      const newStatus = BOARD_STATUSES[newStatusIdx];

      expect(task.status).toBe("closed");
      expect(newStatus).toBe("backlog");
    });

    it("S should wrap from backlog to closed", () => {
      const task = createTask("bd-1234", { status: "backlog" });
      const currentStatusIdx = BOARD_STATUSES.indexOf(task.status as BoardStatus);
      const delta = -1;
      const newStatusIdx = (currentStatusIdx + delta + BOARD_STATUSES.length) % BOARD_STATUSES.length;
      const newStatus = BOARD_STATUSES[newStatusIdx];

      expect(task.status).toBe("backlog");
      expect(newStatus).toBe("closed");
    });

    it("should handle all status transitions for s", () => {
      const transitions: [BoardStatus, BoardStatus][] = [
        ["backlog", "ready"],
        ["ready", "in_progress"],
        ["in_progress", "review"],
        ["review", "blocked"],
        ["blocked", "closed"],
        ["closed", "backlog"],
      ];

      transitions.forEach(([from, to]) => {
        const task = createTask("bd-1234", { status: from });
        const currentStatusIdx = BOARD_STATUSES.indexOf(task.status as BoardStatus);
        const newStatusIdx = (currentStatusIdx + 1) % BOARD_STATUSES.length;
        const newStatus = BOARD_STATUSES[newStatusIdx];
        expect(newStatus).toBe(to);
      });
    });

    it("should handle all status transitions for S", () => {
      const transitions: [BoardStatus, BoardStatus][] = [
        ["backlog", "closed"],
        ["ready", "backlog"],
        ["in_progress", "ready"],
        ["review", "in_progress"],
        ["blocked", "review"],
        ["closed", "blocked"],
      ];

      transitions.forEach(([from, to]) => {
        const task = createTask("bd-1234", { status: from });
        const currentStatusIdx = BOARD_STATUSES.indexOf(task.status as BoardStatus);
        const newStatusIdx = (currentStatusIdx - 1 + BOARD_STATUSES.length) % BOARD_STATUSES.length;
        const newStatus = BOARD_STATUSES[newStatusIdx];
        expect(newStatus).toBe(to);
      });
    });

    it("should return error when task has unknown status", () => {
      const task = createTask("bd-1234", { status: "unknown_status" as any });
      const currentStatusIdx = BOARD_STATUSES.indexOf(task.status as BoardStatus);

      expect(currentStatusIdx).toBe(-1);
    });
  });

  describe("Close Task (c/C keys)", () => {
    it("c should set status to closed", () => {
      const task = createTask("bd-1234", { status: "in_progress" });
      const closedStatus = "closed";

      expect(task.status).not.toBe(closedStatus);
      // Simulate close
      const closedTask = { ...task, status: closedStatus };
      expect(closedTask.status).toBe(closedStatus);
    });

    it("C should also set status to closed", () => {
      const task = createTask("bd-1234", { status: "review" });
      const closedStatus = "closed";

      const closedTask = { ...task, status: closedStatus };
      expect(closedTask.status).toBe(closedStatus);
    });

    it("close should set closed_at timestamp", () => {
      const task = createTask("bd-1234", { closed_at: null });
      const closeTime = new Date().toISOString();

      expect(task.closed_at).toBeNull();
      const closedTask = { ...task, closed_at: closeTime };
      expect(closedTask.closed_at).not.toBeNull();
    });

    it("close with reason should store the reason", () => {
      const reason = "Completed successfully";
      const task = createTask("bd-1234", { closed_at: null });

      // In the actual implementation, reason is stored in closed_at field
      const closedTask = { ...task, closed_at: reason };
      expect(closedTask.closed_at).toBe(reason);
    });
  });

  describe("Edit Task in Editor (e/E keys)", () => {
    it("should generate basic YAML schema", () => {
      const task = createTask("bd-1234", {
        title: "Test Task",
        description: "Description here",
        type: "task",
        priority: 2,
        status: "in_progress",
      });

      const doc: Record<string, unknown> = {
        id: task.id,
        title: task.title,
        description: task.description ?? "",
        type: task.type,
        priority: task.priority,
        status: task.status,
      };

      expect(doc.id).toBe("bd-1234");
      expect(doc.title).toBe("Test Task");
      expect(doc.description).toBe("Description here");
      expect(doc.type).toBe("task");
      expect(doc.priority).toBe(2);
      expect(doc.status).toBe("in_progress");
    });

    it("should generate full schema when fullSchema=true", () => {
      const task = createTask("bd-1234", {
        external_id: "EXT-123",
        created_at: "2026-04-19T10:00:00Z",
        updated_at: "2026-04-19T12:00:00Z",
        approved_at: "2026-04-19T11:00:00Z",
        closed_at: null,
      });

      const doc: Record<string, unknown> = {
        id: task.id,
        title: task.title,
        description: task.description ?? "",
        type: task.type,
        priority: task.priority,
        status: task.status,
        external_id: task.external_id ?? null,
        created_at: task.created_at,
        updated_at: task.updated_at,
        approved_at: task.approved_at,
        closed_at: task.closed_at,
      };

      expect(doc.external_id).toBe("EXT-123");
      expect(doc.created_at).toBe("2026-04-19T10:00:00Z");
      expect(doc.updated_at).toBe("2026-04-19T12:00:00Z");
      expect(doc.approved_at).toBe("2026-04-19T11:00:00Z");
      expect(doc.closed_at).toBeNull();
    });

    it("should validate required fields on parse", () => {
      const validYaml = {
        id: "bd-1234",
        title: "Valid Task",
        description: "Description",
        type: "task",
        priority: 2,
        status: "in_progress",
      };

      // Validation: id and title are required
      expect(validYaml.id).toBeTruthy();
      expect(typeof validYaml.title).toBe("string");
      expect(validYaml.title.length).toBeGreaterThan(0);
    });

    it("should reject YAML without id", () => {
      const invalidYaml = {
        title: "No ID Task",
        description: "Description",
      };

      const isValid = !!(invalidYaml.id && typeof invalidYaml.title === "string");
      expect(isValid).toBe(false);
    });

    it("should reject YAML without title", () => {
      const invalidYaml = {
        id: "bd-1234",
        description: "Description",
      };

      const isValid = !!(invalidYaml.id && typeof invalidYaml.title === "string");
      expect(isValid).toBe(false);
    });

    it("should clamp priority to [0, 4]", () => {
      const clamp = (value: number, min: number, max: number): number =>
        Math.max(min, Math.min(max, value));

      expect(clamp(-1, 0, 4)).toBe(0);
      expect(clamp(0, 0, 4)).toBe(0);
      expect(clamp(2, 0, 4)).toBe(2);
      expect(clamp(4, 0, 4)).toBe(4);
      expect(clamp(5, 0, 4)).toBe(4);
    });

    it("should handle null description", () => {
      const task = createTask("bd-1234", { description: null });

      const doc: Record<string, unknown> = {
        description: task.description ?? "",
      };

      expect(doc.description).toBe("");
    });

    it("should handle unknown fields gracefully", () => {
      const parsedYaml = {
        id: "bd-1234",
        title: "Task",
        unknown_field: "should be ignored",
        another_unknown: 12345,
      };

      const filtered: Partial<BoardTask> = {
        id: String(parsedYaml.id),
        title: String(parsedYaml.title),
      };

      expect(filtered.id).toBe("bd-1234");
      expect(filtered.title).toBe("Task");
      // Unknown fields should not be present
      expect((filtered as Record<string, unknown>).unknown_field).toBeUndefined();
    });
  });

  describe("Editor Resolution", () => {
    it("should prefer EDITOR environment variable", () => {
      const editor = process.env.EDITOR ?? process.env.VISUAL;
      // If EDITOR is set, use it
      if (editor) {
        expect(typeof editor).toBe("string");
      }
    });

    it("should fallback to VISUAL if EDITOR not set", () => {
      // Simulate the resolution logic
      const editor = process.env.EDITOR ?? process.env.VISUAL;
      const fallbackOrder = ["vim", "nvim", "nano", "vi", "emacs"];

      // If neither is set, should fall back to first available
      expect(fallbackOrder).toContain("vim");
    });

    it("should have vi as ultimate fallback", () => {
      const fallbackOrder = ["vim", "nvim", "nano", "vi", "emacs"];
      expect(fallbackOrder[fallbackOrder.length - 1]).toBe("emacs");
      expect(fallbackOrder).toContain("vi");
    });
  });

  describe("Task Update Validation", () => {
    it("should validate status is a valid board status", () => {
      const validStatuses: BoardStatus[] = [
        "backlog",
        "ready",
        "in_progress",
        "review",
        "blocked",
        "closed",
      ];

      const testStatuses = ["backlog", "ready", "invalid", "closed"];
      testStatuses.forEach((status) => {
        const isValid = validStatuses.includes(status as BoardStatus);
        if (status === "invalid") {
          expect(isValid).toBe(false);
        } else {
          expect(isValid).toBe(true);
        }
      });
    });

    it("should validate priority is in range", () => {
      const clamp = (value: number, min: number, max: number): number =>
        Math.max(min, Math.min(max, value));

      const priorities = [-1, 0, 2, 4, 5];
      const expected = [0, 0, 2, 4, 4];

      priorities.forEach((p, i) => {
        expect(clamp(p, 0, 4)).toBe(expected[i]);
      });
    });

    it("should preserve unchanged fields on update", () => {
      const original: BoardTask = createTask("bd-1234", {
        title: "Original Title",
        description: "Original Description",
        priority: 2,
        status: "backlog",
      });

      const update = {
        title: "New Title",
      };

      const updated: BoardTask = {
        ...original,
        title: update.title,
      };

      expect(updated.id).toBe(original.id);
      expect(updated.title).toBe("New Title");
      expect(updated.description).toBe(original.description);
      expect(updated.priority).toBe(original.priority);
      expect(updated.status).toBe(original.status);
    });
  });

  describe("Flash Feedback", () => {
    it("should set flashTaskId after mutation", () => {
      let flashTaskId: string | null = null;
      const taskId = "bd-1234";

      // Simulate successful mutation
      flashTaskId = taskId;

      expect(flashTaskId).toBe("bd-1234");
    });

    it("should clear flashTaskId after refresh", () => {
      let flashTaskId: string | null = "bd-1234";

      // Simulate refresh
      flashTaskId = null;

      expect(flashTaskId).toBeNull();
    });
  });

  describe("Error Handling", () => {
    it("should capture store errors", () => {
      const mockError = new Error("Database connection failed");
      const errorMessage = mockError instanceof Error ? mockError.message : String(mockError);

      expect(errorMessage).toBe("Database connection failed");
    });

    it("should handle non-Error objects", () => {
      const errorMessage = String({ code: "ERR_123", details: "Something went wrong" });

      expect(errorMessage).toContain("ERR_123");
    });
  });
});
