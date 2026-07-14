import { describe, expect, it, vi } from "vitest";

import { ElixirTaskClient } from "../elixir-task-client.js";

describe("ElixirTaskClient", () => {
  it("includes run ownership metadata on task updates", async () => {
    const sendCommand = vi.fn().mockResolvedValue({ ok: true, events: [], projection_version: 1, correlation_id: "corr-1" });
    const client = new ElixirTaskClient("/repo", "proj-1", { sendCommand } as never);

    await client.update("task-1", { status: "in_progress", runId: "run-1", source: "agent-worker-phase" });

    expect(sendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "task.update",
      payload: expect.objectContaining({
        project_id: "proj-1",
        task_id: "task-1",
        status: "in-progress",
        run_id: "run-1",
        source: "agent-worker-phase",
      }),
    }));
  });
});
