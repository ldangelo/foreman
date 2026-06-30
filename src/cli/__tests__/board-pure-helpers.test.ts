import { afterEach, describe, expect, it, vi } from "vitest";

import {
  boardColumnForTaskStatus,
  getTerminalWidth,
  getVisibleStatuses,
  normalizeStatusForBoard,
  normalizeStatusForStore,
  runBoard,
} from "../commands/board.js";

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
    expect(boardColumnForTaskStatus("reviewer")).toBe("in_progress");
    expect(boardColumnForTaskStatus("failed")).toBe("needs_attention");
    expect(boardColumnForTaskStatus("done")).toBe("closed");
    expect(boardColumnForTaskStatus("unknown-status")).toBe("needs_attention");
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
