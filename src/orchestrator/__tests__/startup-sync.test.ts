import { describe, expect, it, vi } from "vitest";
import { syncTaskStatusOnStartup } from "../task-backend-ops.js";

type MinimalRun = {
  id: string;
  task_id: string;
  status: "completed" | "merged" | "failed" | "stuck";
  created_at: string;
};

function makeRun(overrides: Partial<MinimalRun> = {}): MinimalRun {
  return {
    id: "run-1",
    task_id: "task-1",
    status: "completed",
    created_at: "2026-01-01T00:00:00.000Z",
    ...overrides,
  };
}

describe("syncTaskStatusOnStartup", () => {
  it("returns an empty result when no terminal runs exist", async () => {
    const store = {
      getRunsByStatuses: vi.fn(() => []),
      getTaskById: vi.fn(),
      updateTaskStatus: vi.fn(),
    };

    const result = await syncTaskStatusOnStartup(store as any, "project-1");

    expect(result).toEqual({ synced: 0, mismatches: [], errors: [] });
    expect(store.getRunsByStatuses).toHaveBeenCalledWith(expect.any(Array), "project-1");
    expect(store.getTaskById).not.toHaveBeenCalled();
  });

  it("dry-runs native task status mismatches without updating", async () => {
    const run = makeRun({ status: "completed" });
    const store = {
      getRunsByStatuses: vi.fn(() => [run]),
      getTaskById: vi.fn(() => ({ id: "task-1", status: "ready" })),
      updateTaskStatus: vi.fn(),
    };

    const result = await syncTaskStatusOnStartup(store as any, "project-1", { dryRun: true });

    expect(result.synced).toBe(0);
    expect(result.mismatches).toEqual([
      {
        taskId: "task-1",
        runId: "run-1",
        runStatus: "completed",
        actualTaskStatus: "ready",
        expectedTaskStatus: "review",
      },
    ]);
    expect(store.updateTaskStatus).not.toHaveBeenCalled();
  });

  it("updates mismatched native task statuses when not dry-running", async () => {
    const run = makeRun({ status: "merged" });
    const store = {
      getRunsByStatuses: vi.fn(() => [run]),
      getTaskById: vi.fn(() => ({ id: "task-1", status: "review" })),
      updateTaskStatus: vi.fn(),
    };

    const result = await syncTaskStatusOnStartup(store as any, "project-1");

    expect(result.synced).toBe(1);
    expect(store.updateTaskStatus).toHaveBeenCalledWith("task-1", "closed");
  });
});
