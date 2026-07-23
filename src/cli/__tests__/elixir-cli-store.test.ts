import { beforeEach, describe, expect, it, vi } from "vitest";

const { mockElixirClient } = vi.hoisted(() => ({
  mockElixirClient: {
    sendCommand: vi.fn(),
    listRuns: vi.fn(),
    listTasks: vi.fn(),
  },
}));

vi.mock("../commands/project-task-support.js", () => ({
  elixirClient: vi.fn(async () => mockElixirClient),
}));

import { ElixirCliStore } from "../commands/elixir-cli-store.js";

describe("ElixirCliStore", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockElixirClient.sendCommand.mockResolvedValue({ ok: true });
    mockElixirClient.listRuns.mockResolvedValue([]);
    mockElixirClient.listTasks.mockResolvedValue([]);
  });

  it("uses lifecycle commands for terminal run status updates", async () => {
    const store = ElixirCliStore.forProject({ id: "proj-1", name: "Proj", path: "/tmp/proj" });

    await store.updateRun("run-1", { status: "failed", completed_at: "2026-01-01T00:00:00.000Z" });

    expect(mockElixirClient.sendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "run.fail",
      payload: expect.objectContaining({
        run_id: "run-1",
        project_id: "proj-1",
        status: "failed",
        completed_at: "2026-01-01T00:00:00.000Z",
      }),
    }));
  });

  it("keeps nonterminal run updates on run.update", async () => {
    const store = ElixirCliStore.forProject({ id: "proj-1", name: "Proj", path: "/tmp/proj" });

    await store.updateRun("run-1", { worktree_path: "/tmp/wt" });

    expect(mockElixirClient.sendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "run.update",
      payload: expect.objectContaining({
        run_id: "run-1",
        project_id: "proj-1",
        worktree_path: "/tmp/wt",
      }),
    }));
  });

  it("terminal task updates fail the active run before updating task status", async () => {
    const store = ElixirCliStore.forProject({ id: "proj-1", name: "Proj", path: "/tmp/proj" });
    mockElixirClient.listRuns.mockResolvedValue([
      { run_id: "run-1", task_id: "task-1", status: "in_progress" },
    ]);

    await store.updateTaskStatus("task-1", "failed");

    expect(mockElixirClient.sendCommand).toHaveBeenNthCalledWith(1, expect.objectContaining({
      command_type: "run.fail",
      payload: expect.objectContaining({
        run_id: "run-1",
        task_id: "task-1",
        project_id: "proj-1",
        status: "failed",
      }),
    }));
    expect(mockElixirClient.sendCommand).toHaveBeenNthCalledWith(2, expect.objectContaining({
      command_type: "task.update",
      payload: expect.objectContaining({
        task_id: "task-1",
        project_id: "proj-1",
        status: "failed",
      }),
    }));
  });

  it("filters active runs whose task is already terminal", async () => {
    const store = ElixirCliStore.forProject({ id: "proj-1", name: "Proj", path: "/tmp/proj" });
    mockElixirClient.listRuns.mockResolvedValue([
      { run_id: "run-stale", task_id: "task-failed", status: "in_progress" },
      { run_id: "run-active", task_id: "task-active", status: "in_progress" },
    ]);
    mockElixirClient.listTasks.mockResolvedValue([
      { task_id: "task-failed", status: "failed" },
      { task_id: "task-active", status: "in_progress" },
    ]);

    const activeRuns = await store.getActiveRuns();

    expect(activeRuns.map((run) => run.id)).toEqual(["run-active"]);
  });
});
