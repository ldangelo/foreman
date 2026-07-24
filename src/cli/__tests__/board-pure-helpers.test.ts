import { afterEach, describe, expect, it, vi } from "vitest";

import {
  BOARD_STATUSES,
  boardColumnForTaskStatus,
  diffBoardTaskSnapshots,
  getTerminalWidth,
  getVisibleStatuses,
  normalizeStatusForBoard,
  normalizeStatusForStore,
  runBoard,
  type BoardStatus,
  type BoardTask,
} from "../commands/board.js";

function createTask(id: string, overrides: Partial<BoardTask> = {}): BoardTask {
  return {
    id,
    title: `Task ${id}`,
    description: null,
    type: "task",
    priority: 2,
    status: "backlog",
    external_id: null,
    created_at: "2026-01-01T00:00:00.000Z",
    updated_at: "2026-01-01T00:00:00.000Z",
    approved_at: null,
    closed_at: null,
    ...overrides,
  };
}

function createTasksMap(tasksByStatus: Partial<Record<BoardStatus, BoardTask[]>>): Map<BoardStatus, BoardTask[]> {
  const map = new Map<BoardStatus, BoardTask[]>();
  for (const status of BOARD_STATUSES) {
    map.set(status, tasksByStatus[status] ?? []);
  }
  return map;
}

describe("board pure helpers", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("normalizes store/user status variants for the board and store", () => {
    expect(normalizeStatusForBoard("in-progress")).toBe("in_progress");
    expect(normalizeStatusForBoard("needs_attention")).toBe("needs_attention");
    expect(normalizeStatusForBoard("mystery")).toBeNull();

    expect(normalizeStatusForStore("in_progress")).toBe("in-progress");
    expect(normalizeStatusForStore("needs_attention")).toBe("blocked");
    expect(normalizeStatusForStore("custom-status")).toBe("custom-status");
  });

  it("maps task statuses into board columns", () => {
    expect(boardColumnForTaskStatus("open")).toBe("backlog");
    // Phase names (developer/qa/reviewer/finalize/explorer) are NOT
    // accepted as task statuses. They belong to runs, not tasks. The
    // legacy CLI route falls through to `needs_attention` for unknown
    // values so the ambiguous state is visible to the operator.
    expect(boardColumnForTaskStatus("reviewer")).toBe("needs_attention");
    expect(boardColumnForTaskStatus("developer")).toBe("needs_attention");
    expect(boardColumnForTaskStatus("failed")).toBe("needs_attention");
    // The legacy CLI column key for terminal is `closed`; the Go
    // cockpit uses `done`. The shared state machine in the server
    // maps both forms correctly at the source.
    expect(boardColumnForTaskStatus("done")).toBe("closed");
    expect(boardColumnForTaskStatus("unknown-status")).toBe("needs_attention");
  });

  it("detects board snapshot additions, changes, and removals", () => {
    const before = createTasksMap({
      backlog: [createTask("task-1")],
      ready: [createTask("task-2", { status: "ready" })],
    });
    const after = createTasksMap({
      backlog: [createTask("task-1", { updated_at: "2026-01-01T00:01:00.000Z" })],
      closed: [createTask("task-3", { status: "closed" })],
    });

    expect(diffBoardTaskSnapshots(before, after).sort()).toEqual(["task-1", "task-2", "task-3"]);
  });

  it("does not report unchanged board snapshots", () => {
    const before = createTasksMap({ backlog: [createTask("task-1")] });
    const after = createTasksMap({ backlog: [createTask("task-1")] });

    expect(diffBoardTaskSnapshots(before, after)).toEqual([]);
  });

  it("computes visible status windows for narrow and wide terminals", () => {
    expect(getVisibleStatuses(500, 0)).toEqual([
      "backlog",
      "ready",
      "in_progress",
      "needs_attention",
      "closed",
    ]);
    expect(getVisibleStatuses(20, 0)).toEqual(["backlog"]);
    expect(getVisibleStatuses(26, 2)).toEqual(["in_progress"]);
    expect(getVisibleStatuses(40, 4)).toEqual(["closed"]);
  });

  it("returns the current terminal width when available", () => {
    expect(typeof getTerminalWidth()).toBe("number");
    expect(getTerminalWidth()).toBeGreaterThan(0);
  });

  it("runBoard reports load failures and returns without entering the TUI loop", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    await expect(runBoard({ projectPath: "/definitely/missing", projectName: "missing" })).resolves.toBeUndefined();

    expect(errorSpy.mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("Failed to load tasks:");
  });
});
