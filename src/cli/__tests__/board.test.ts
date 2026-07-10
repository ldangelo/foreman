/**
 * Tests for Foreman board functionality.
 *
 * @module src/cli/__tests__/board.test
 */

import { afterEach, describe, expect, it, vi } from "vitest";
import {
  applyStatusFilter,
  boardColumnForTaskStatus,
  loadBoardTasks,
  type BoardStatus,
  type BoardTask,
} from "../commands/board.js";

// Constants matching board.ts
const BOARD_STATUSES: readonly BoardStatus[] = [
  "backlog",
  "ready",
  "in_progress",
  "needs_attention",
  "closed",
] as const;

// Helper to create a board task (module-scoped for reuse across describe blocks)
const createTestTask = (
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

describe("boardColumnForTaskStatus canonical status mapping", () => {
  it("should map completed, closed, merged, and done to closed column", () => {
    expect(boardColumnForTaskStatus("completed")).toBe("closed");
    expect(boardColumnForTaskStatus("closed")).toBe("closed");
    expect(boardColumnForTaskStatus("merged")).toBe("closed");
    expect(boardColumnForTaskStatus("done")).toBe("closed");
  });

  it("should map in_progress statuses correctly", () => {
    expect(boardColumnForTaskStatus("explorer")).toBe("in_progress");
    expect(boardColumnForTaskStatus("developer")).toBe("in_progress");
    expect(boardColumnForTaskStatus("qa")).toBe("in_progress");
    expect(boardColumnForTaskStatus("reviewer")).toBe("in_progress");
    expect(boardColumnForTaskStatus("finalize")).toBe("in_progress");
  });

  it("should map needs_attention statuses correctly", () => {
    expect(boardColumnForTaskStatus("failed")).toBe("needs_attention");
    expect(boardColumnForTaskStatus("stuck")).toBe("needs_attention");
    expect(boardColumnForTaskStatus("conflict")).toBe("needs_attention");
    expect(boardColumnForTaskStatus("blocked")).toBe("needs_attention");
    expect(boardColumnForTaskStatus("review")).toBe("needs_attention");
  });

  it("should map backlog statuses correctly", () => {
    expect(boardColumnForTaskStatus("open")).toBe("backlog");
    expect(boardColumnForTaskStatus("todo")).toBe("backlog");
  });

  it("should route unknown/unmapped statuses to closed (terminal bucket)", () => {
    // Unknown statuses should NOT appear in needs_attention (actionable)
    expect(boardColumnForTaskStatus("unknown")).toBe("closed");
    expect(boardColumnForTaskStatus("unmapped")).toBe("closed");
    expect(boardColumnForTaskStatus("weird-status")).toBe("closed");
    expect(boardColumnForTaskStatus("random-xyz")).toBe("closed");
  });

  it("should handle hyphenated status aliases", () => {
    expect(boardColumnForTaskStatus("in-progress")).toBe("in_progress");
    expect(boardColumnForTaskStatus("needs-attention")).toBe("needs_attention");
  });
});

describe("applyStatusFilter", () => {
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

  it("should accept completed/closed alias for closed column filter", () => {
    // Include tasks in multiple columns to prove filtering actually works
    const map = createTasksMap({
      closed: [createTestTask("task-1", "completed"), createTestTask("task-2", "done")],
      backlog: [createTestTask("task-3", "open"), createTestTask("task-4", "todo")],
      needs_attention: [createTestTask("task-5", "failed")],
    });

    const filtered = applyStatusFilter(map, "completed");
    // Only closed tasks should be present
    expect(filtered.get("closed")).toHaveLength(2);
    // Non-target columns should be empty
    expect(filtered.get("backlog")).toHaveLength(0);
    expect(filtered.get("needs_attention")).toHaveLength(0);
  });

  it("should accept in-progress/in_progress alias for in_progress column filter", () => {
    const map = createTasksMap({
      in_progress: [createTestTask("task-1", "developer")],
      closed: [createTestTask("task-2", "completed")],
      backlog: [createTestTask("task-3", "open")],
    });

    const filtered = applyStatusFilter(map, "in-progress");
    expect(filtered.get("in_progress")).toHaveLength(1);
    // Non-target columns should be empty
    expect(filtered.get("closed")).toHaveLength(0);
    expect(filtered.get("backlog")).toHaveLength(0);
  });

  it("should accept needs-attention/needs_attention alias for needs_attention column filter", () => {
    const map = createTasksMap({
      needs_attention: [createTestTask("task-1", "failed"), createTestTask("task-2", "stuck")],
      ready: [createTestTask("task-3", "ready")],
      in_progress: [createTestTask("task-4", "explorer")],
    });

    const filtered = applyStatusFilter(map, "needs-attention");
    expect(filtered.get("needs_attention")).toHaveLength(2);
    // Non-target columns should be empty
    expect(filtered.get("ready")).toHaveLength(0);
    expect(filtered.get("in_progress")).toHaveLength(0);
  });

  it("should accept in_progress underscore variant for filter", () => {
    const map = createTasksMap({
      in_progress: [createTestTask("task-1", "qa")],
      closed: [createTestTask("task-2", "done")],
    });

    const filtered = applyStatusFilter(map, "in_progress");
    expect(filtered.get("in_progress")).toHaveLength(1);
    expect(filtered.get("closed")).toHaveLength(0);
  });

  it("should route unknown filter to closed column", () => {
    const map = createTasksMap({
      closed: [createTestTask("task-1", "completed")],
      backlog: [createTestTask("task-2", "open")],
      needs_attention: [createTestTask("task-3", "failed")],
    });

    const filtered = applyStatusFilter(map, "unknown-status");
    expect(filtered.get("closed")).toHaveLength(1);
    expect(filtered.get("backlog")).toHaveLength(0);
    expect(filtered.get("needs_attention")).toHaveLength(0);
  });

  it("should preserve all columns in output map and empty non-target columns", () => {
    const map = createTasksMap({
      backlog: [createTestTask("task-1", "open")],
      ready: [createTestTask("task-2", "ready")],
      in_progress: [createTestTask("task-3", "explorer")],
      needs_attention: [createTestTask("task-4", "failed")],
      closed: [createTestTask("task-5", "completed")],
    });

    const filtered = applyStatusFilter(map, "backlog");

    for (const status of BOARD_STATUSES) {
      expect(filtered.has(status)).toBe(true);
    }
    // Only backlog should have tasks
    expect(filtered.get("backlog")).toHaveLength(1);
    // All other columns should be empty
    expect(filtered.get("ready")).toHaveLength(0);
    expect(filtered.get("in_progress")).toHaveLength(0);
    expect(filtered.get("needs_attention")).toHaveLength(0);
    expect(filtered.get("closed")).toHaveLength(0);
  });
});

describe("loadBoardTasks project scoping", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("should only include tasks matching the projectId in Elixir path", async () => {
    // Mock the Elixir server manager and client to test loadBoardTasks directly
    const mockProjectId = "proj-target";

    // Mock tasks with various project_ids
    const mockTasks = [
      { task_id: "task-1", project_id: mockProjectId, status: "backlog", title: "Matching task" },
      { task_id: "task-2", project_id: "proj-other", status: "backlog", title: "Other project" },
      { task_id: "task-3", project_id: null, status: "backlog", title: "Null project" },
      { task_id: "task-4", project_id: undefined, status: "backlog", title: "Undefined project" },
      { task_id: "task-5", project_id: mockProjectId, status: "in-progress", title: "Another matching" },
    ];

    // Mock the elixir server manager module
    vi.mock("../../lib/elixir-server-manager.js", () => ({
      ElixirServerManager: vi.fn().mockImplementation(() => ({
        ensureRunning: vi.fn().mockResolvedValue({ running: true, url: "http://localhost:4000" }),
      })),
    }));

    // Mock the elixir server client module
    vi.mock("../../lib/elixir-server-client.js", () => ({
      ElixirServerClient: vi.fn().mockImplementation(() => ({
        listTasks: vi.fn().mockResolvedValue(mockTasks),
      })),
    }));

    // Mock foremanBackendMode to return 'elixir'
    vi.mock("../../lib/backend-mode.js", () => ({
      foremanBackendMode: vi.fn().mockReturnValue("elixir"),
    }));

    // Mock listRegisteredProjects to return our test project
    const mockProject = { id: mockProjectId, name: "test-project", path: "/test/path" };
    vi.spyOn(
      await import("../commands/project-task-support.js"),
      "listRegisteredProjects"
    ).mockResolvedValue([mockProject]);

    // Call loadBoardTasks with our test project
    const result = await loadBoardTasks("/test/path");

    // Verify only matching tasks are included
    const backlogTasks = result.get("backlog") ?? [];
    const inProgressTasks = result.get("in_progress") ?? [];

    // Should include only tasks with matching project_id
    const allResultTasks = [...backlogTasks, ...inProgressTasks];
    expect(allResultTasks).toHaveLength(2);
    expect(allResultTasks.map(t => t.id)).toContain("task-1");
    expect(allResultTasks.map(t => t.id)).toContain("task-5");

    // Should exclude tasks from other projects
    const resultIds = allResultTasks.map(t => t.id);
    expect(resultIds).not.toContain("task-2"); // Other project
    expect(resultIds).not.toContain("task-3"); // Null project
    expect(resultIds).not.toContain("task-4"); // Undefined project
  });
});

describe("--all mode non-interleaving behavior", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("should render static snapshots sequentially using actual command handler", async () => {
    // Mock listRegisteredProjects to return multiple projects
    const mockProjects = [
      { id: "proj-1", name: "project-a", path: "/path/to/project-a" },
      { id: "proj-2", name: "project-b", path: "/path/to/project-b" },
      { id: "proj-3", name: "project-c", path: "/path/to/project-c" },
    ];

    vi.spyOn(
      await import("../commands/project-task-support.js"),
      "listRegisteredProjects"
    ).mockResolvedValue(mockProjects);

    // Create mock task maps for each project
    const createMockTasks = (projectId: string): Map<BoardStatus, BoardTask[]> => {
      const map = new Map<BoardStatus, BoardTask[]>();
      for (const status of BOARD_STATUSES) {
        map.set(status, []);
      }
      map.get("backlog")!.push(createTestTask(`task-${projectId}`, "open"));
      return map;
    };

    vi.spyOn(
      await import("../commands/board.js"),
      "loadBoardTasks"
    ).mockImplementation(async (projectPath: string) => {
      // Return different tasks based on project path to verify correct loading
      if (projectPath.includes("project-a")) return createMockTasks("1");
      if (projectPath.includes("project-b")) return createMockTasks("2");
      return createMockTasks("3");
    });

    // Capture console.log output
    const consoleOutputs: string[] = [];
    const originalLog = console.log;
    vi.spyOn(console, "log").mockImplementation((...args: unknown[]) => {
      consoleOutputs.push(args.map(a => String(a)).join(" "));
    });

    // Call the actual command handler with --all
    const { boardCommand } = await import("../commands/board.js");
    await boardCommand.parseAsync(["node", "foreman", "board", "--all"], { from: "user" });

    // Verify sequential output order - all project-a output should come before project-b
    const projectAOutputs = consoleOutputs.filter(o => o.includes("project-a") || o.includes("proj-1"));
    const projectBOutputs = consoleOutputs.filter(o => o.includes("project-b") || o.includes("proj-2"));
    const projectCOutputs = consoleOutputs.filter(o => o.includes("project-c") || o.includes("proj-3"));

    // Find the first index of each project's output
    const firstA = consoleOutputs.findIndex(o => o.includes("project-a") || o.includes("proj-1"));
    const firstB = consoleOutputs.findIndex(o => o.includes("project-b") || o.includes("proj-2"));
    const firstC = consoleOutputs.findIndex(o => o.includes("project-c") || o.includes("proj-3"));

    // Verify order: A < B < C (sequential, no interleaving)
    expect(firstA).toBeLessThan(firstB);
    expect(firstB).toBeLessThan(firstC);

    // Verify loadBoardTasks was called for each project
    const loadBoardTasks = vi.mocked(await import("../commands/board.js")).loadBoardTasks;
    expect(loadBoardTasks).toHaveBeenCalledTimes(3);

    console.log = originalLog;
  });

  it("should continue processing projects when one fails", async () => {
    // Mock listRegisteredProjects
    const mockProjects = [
      { id: "proj-1", name: "project-a", path: "/path/to/project-a" },
      { id: "proj-2", name: "project-b", path: "/path/to/project-b" },
      { id: "proj-3", name: "project-c", path: "/path/to/project-c" },
    ];

    vi.spyOn(
      await import("../commands/project-task-support.js"),
      "listRegisteredProjects"
    ).mockResolvedValue(mockProjects);

    // Mock loadBoardTasks to fail for project-b
    const loadBoardTasksMock = vi.fn().mockImplementation(async (projectPath: string) => {
      if (projectPath.includes("project-b")) {
        throw new Error("Simulated failure for project-b");
      }
      const map = new Map<BoardStatus, BoardTask[]>();
      for (const status of BOARD_STATUSES) {
        map.set(status, []);
      }
      return map;
    });

    vi.spyOn(
      await import("../commands/board.js"),
      "loadBoardTasks"
    ).mockImplementation(loadBoardTasksMock);

    // Capture console output
    const consoleOutputs: string[] = [];
    const originalLog = console.log;
    const originalError = console.error;
    vi.spyOn(console, "log").mockImplementation((...args: unknown[]) => {
      consoleOutputs.push(args.map(a => String(a)).join(" "));
    });
    vi.spyOn(console, "error").mockImplementation((...args: unknown[]) => {
      consoleOutputs.push("ERROR: " + args.map(a => String(a)).join(" "));
    });

    // Call the command
    const { boardCommand } = await import("../commands/board.js");
    await boardCommand.parseAsync(["node", "foreman", "board", "--all"], { from: "user" });

    // Verify project-a and project-c were processed
    expect(consoleOutputs.some(o => o.includes("project-a"))).toBe(true);
    expect(consoleOutputs.some(o => o.includes("project-c"))).toBe(true);

    // Verify project-b error was logged but didn't stop processing
    expect(consoleOutputs.some(o => o.includes("project-b") && o.includes("error"))).toBe(true);

    // Verify loadBoardTasks was called 3 times (once for each project)
    expect(loadBoardTasksMock).toHaveBeenCalledTimes(3);

    console.log = originalLog;
    console.error = originalError;
  });
});
