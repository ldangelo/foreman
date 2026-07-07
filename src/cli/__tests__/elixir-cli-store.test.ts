import { beforeEach, describe, expect, it, vi } from "vitest";

const { mockElixirClient } = vi.hoisted(() => ({
  mockElixirClient: {
    sendCommand: vi.fn(),
    listRuns: vi.fn(),
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
});
