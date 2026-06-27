import { afterEach, describe, expect, it, vi } from "vitest";

const {
  mockRequireProjectOrAll,
  mockResolveProjectContext,
  mockStatus,
  mockHealth,
  mockEnsureRunning,
  mockListRuns,
  mockListTasks,
  mockSendCommand,
  mockElixirClientCtor,
} = vi.hoisted(() => ({
  mockRequireProjectOrAll: vi.fn(async () => undefined),
  mockResolveProjectContext: vi.fn(async () => ({ projectPath: "/repo", registered: { id: "proj-1", name: "test", path: "/repo" } })),
  mockStatus: vi.fn(() => ({ running: true, url: "http://127.0.0.1:4777", pidPath: "/tmp/pid" })),
  mockHealth: vi.fn(async () => ({ ok: true })),
  mockEnsureRunning: vi.fn(async () => ({ running: true, url: "http://127.0.0.1:4777", pidPath: "/tmp/pid" })),
  mockListRuns: vi.fn(async () => []),
  mockListTasks: vi.fn(async () => []),
  mockSendCommand: vi.fn(async () => ({ ok: true, events: ["event-1"], projection_version: 1, correlation_id: "c1" })),
  mockElixirClientCtor: vi.fn(),
}));

vi.mock("../project-task-support.js", () => ({
  requireProjectOrAllInMultiMode: mockRequireProjectOrAll,
}));

vi.mock("../project-context.js", () => ({
  resolveProjectContext: mockResolveProjectContext,
}));

vi.mock("../../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: class MockElixirServerManager {
    authToken = "token";
    status = mockStatus;
    health = mockHealth;
    ensureRunning = mockEnsureRunning;
  },
}));

vi.mock("../../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: class MockElixirServerClient {
    constructor(url: string, token?: string) {
      mockElixirClientCtor(url, token);
    }
    listRuns = mockListRuns;
    listTasks = mockListTasks;
    sendCommand = mockSendCommand;
  },
}));

import { resetElixirDryRun, resetElixirRuns } from "../reset.js";

describe("Elixir reset dry-run", () => {
  afterEach(() => {
    vi.clearAllMocks();
    vi.restoreAllMocks();
  });

  it("previews failed/stuck Elixir runs without mutation", async () => {
    mockListRuns.mockResolvedValue([
      { run_id: "run-1", task_id: "task-1", status: "failed" },
      { run_id: "run-2", task_id: "task-2", status: "running" },
    ] as never);
    mockListTasks.mockResolvedValue([
      { task_id: "task-1", status: "failed" },
      { task_id: "task-2", status: "in_progress" },
    ] as never);
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    const exitCode = await resetElixirDryRun({});

    expect(exitCode).toBe(0);
    expect(mockStatus.mock.invocationCallOrder[0]).toBeLessThan(mockResolveProjectContext.mock.invocationCallOrder[0]);
    expect(mockResolveProjectContext).toHaveBeenCalledWith({ project: undefined, projectPath: undefined }, { initPool: false, matchProjectFlagByIdOrName: true });
    expect(mockElixirClientCtor).toHaveBeenCalledWith("http://127.0.0.1:4777", "token");
    const output = logSpy.mock.calls.map((call) => call.join(" ")).join("\n");
    expect(output).toContain("would inspect  run run-1");
    expect(output).not.toContain("would inspect  run run-2");
  });

  it("records reset events and requeues failed tasks", async () => {
    mockListRuns.mockResolvedValue([{ run_id: "run-1", task_id: "task-1", status: "failed" }] as never);
    mockListTasks.mockResolvedValue([{ task_id: "task-1", status: "failed" }] as never);
    vi.spyOn(console, "log").mockImplementation(() => undefined);

    const exitCode = await resetElixirRuns({});

    expect(exitCode).toBe(0);
    expect(mockEnsureRunning).toHaveBeenCalledOnce();
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "run.reset",
      payload: expect.objectContaining({ run_id: "run-1", reason: "foreman reset" }),
    }));
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "task.update",
      payload: expect.objectContaining({ task_id: "task-1", status: "ready" }),
    }));
  });
});
