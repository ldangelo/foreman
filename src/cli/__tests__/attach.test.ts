import { describe, expect, it, vi } from "vitest";
import { attachCommand, handleKillElixir, type ElixirAttachContext } from "../commands/attach.js";
import type { Run } from "../../lib/store.js";

describe("attach command", () => {
  it("loads the production command", () => {
    expect(attachCommand.name()).toBe("attach");
  });

  it("records attach --kill through Elixir run events", async () => {
    const sendCommand = vi.fn().mockResolvedValue({ ok: true, events: ["event-1"], projection_version: 1, correlation_id: "c-1" });
    const context = {
      client: { sendCommand },
      projectId: "proj-1",
      projectPath: "/repo",
    } as unknown as ElixirAttachContext;
    const run = {
      id: "run-1",
      project_id: "proj-1",
      seed_id: "task-1",
      agent_type: "elixir",
      session_key: null,
      worktree_path: null,
      status: "running",
      started_at: null,
      completed_at: null,
      created_at: new Date(0).toISOString(),
      progress: null,
      base_branch: null,
      merge_strategy: null,
    } satisfies Run;

    const outputSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const exitCode = await handleKillElixir(run, context);

    expect(exitCode).toBe(0);
    expect(sendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "run.fail",
      payload: expect.objectContaining({
        run_id: "run-1",
        reason: "foreman attach --kill",
        actor: "operator",
      }),
    }));
    expect(outputSpy.mock.calls.map((call) => call.join(" ")).join("\n")).toContain("Elixir run stopped");
    outputSpy.mockRestore();
  });
});
