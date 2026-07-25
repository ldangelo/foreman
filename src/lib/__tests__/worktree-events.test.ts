import { describe, expect, it, vi } from "vitest";

import { emitWorktreeCleaned, emitWorktreeCreated } from "../worktree-events.js";
import type { ElixirServerClient } from "../elixir-server-client.js";

interface CapturedCommand {
  command_id: string;
  command_type: string;
  payload: Record<string, unknown>;
}

function makeClient(): { client: ElixirServerClient; calls: CapturedCommand[] } {
  const calls: CapturedCommand[] = [];
  const client = {
    sendCommand: vi.fn(async (cmd: CapturedCommand) => {
      calls.push(cmd);
      return { ok: true, events: [], projection_version: 1, correlation_id: "c1" };
    }),
  } as unknown as ElixirServerClient;
  return { client, calls };
}

describe("worktree-events", () => {
  it("emitWorktreeCreated dispatches a vcs.worktree.create command", async () => {
    const { client, calls } = makeClient();
    const result = await emitWorktreeCreated(client, {
      projectId: "proj-1",
      runId: "run-abc",
      worktreePath: "/tmp/wt/run-abc",
      branchName: "foreman/run-abc",
      baseBranch: "main",
    });
    expect(result.ok).toBe(true);
    expect(calls).toHaveLength(1);
    const cmd = calls[0];
    expect(cmd.command_type).toBe("vcs.worktree.create");
    expect(cmd.payload.run_id).toBe("run-abc");
    expect(cmd.payload.project_id).toBe("proj-1");
    expect(cmd.payload.worktree_path).toBe("/tmp/wt/run-abc");
    expect(cmd.payload.branch_name).toBe("foreman/run-abc");
    expect(cmd.payload.base_branch).toBe("main");
    expect(typeof cmd.payload.operation_id).toBe("string");
    expect(cmd.command_id).toMatch(/^vcs\.worktree\.create-/);
  });

  it("emitWorktreeCreated omits base_branch when not provided", async () => {
    const { client, calls } = makeClient();
    await emitWorktreeCreated(client, {
      projectId: "proj-1",
      runId: "run-abc",
      worktreePath: "/tmp/wt/run-abc",
      branchName: "foreman/run-abc",
    });
    expect(calls[0].payload.base_branch).toBeNull();
  });

  it("emitWorktreeCleaned dispatches a vcs.worktree.clean command", async () => {
    const { client, calls } = makeClient();
    const result = await emitWorktreeCleaned(client, {
      projectId: "proj-1",
      runId: "run-abc",
      worktreePath: "/tmp/wt/run-abc",
      reason: "worktree clean",
    });
    expect(result.ok).toBe(true);
    expect(calls).toHaveLength(1);
    const cmd = calls[0];
    expect(cmd.command_type).toBe("vcs.worktree.clean");
    expect(cmd.payload.run_id).toBe("run-abc");
    expect(cmd.payload.worktree_path).toBe("/tmp/wt/run-abc");
    expect(cmd.payload.reason).toBe("worktree clean");
  });

  it("emitWorktreeCleaned uses default reason when omitted", async () => {
    const { client, calls } = makeClient();
    await emitWorktreeCleaned(client, {
      projectId: "proj-1",
      runId: "run-abc",
      worktreePath: "/tmp/wt/run-abc",
    });
    expect(calls[0].payload.reason).toBe("cleanup");
  });

  it("returns ok=false when the server rejects the command", async () => {
    const client = {
      sendCommand: vi.fn(async () => ({
        ok: false,
        error: { code: "INTERNAL", message: "boom", retryable: false },
        events: [],
        projection_version: 0,
        correlation_id: "c1",
      })),
    } as unknown as ElixirServerClient;
    const result = await emitWorktreeCreated(client, {
      projectId: "proj-1",
      runId: "run-abc",
      worktreePath: "/tmp/wt/run-abc",
      branchName: "foreman/run-abc",
    });
    expect(result.ok).toBe(false);
    expect(result.error?.message).toBe("boom");
  });
});
