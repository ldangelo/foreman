import { afterEach, describe, expect, it, vi } from "vitest";

const { mockStatus, mockHealth, mockListRuns, mockListTasks, mockElixirClientCtor } = vi.hoisted(() => ({
  mockStatus: vi.fn(() => ({ running: true, url: "http://127.0.0.1:4777", pidPath: "/tmp/pid" })),
  mockHealth: vi.fn(async () => ({ ok: true })),
  mockListRuns: vi.fn(async () => []),
  mockListTasks: vi.fn(async () => []),
  mockElixirClientCtor: vi.fn(),
}));

vi.mock("../../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: class MockElixirServerManager {
    authToken = "token";
    status = mockStatus;
    health = mockHealth;
  },
}));

vi.mock("../../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: class MockElixirServerClient {
    constructor(url: string, token?: string) {
      mockElixirClientCtor(url, token);
    }
    listRuns = mockListRuns;
    listTasks = mockListTasks;
  },
}));

import { purgeZombieRunsElixirDryRun } from "../purge-zombie-runs.js";

describe("Elixir purge runs dry-run", () => {
  afterEach(() => {
    vi.clearAllMocks();
    vi.restoreAllMocks();
  });

  it("previews failed Elixir runs whose tasks are closed", async () => {
    mockListRuns.mockResolvedValue([
      { run_id: "run-1", task_id: "task-1", status: "failed" },
      { run_id: "run-2", task_id: "task-2", status: "failed" },
      { run_id: "run-3", task_id: "task-3", status: "running" },
    ] as never);
    mockListTasks.mockResolvedValue([
      { task_id: "task-1", status: "closed" },
      { task_id: "task-2", status: "ready" },
    ] as never);
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    const exitCode = await purgeZombieRunsElixirDryRun({ dryRun: true });

    expect(exitCode).toBe(0);
    expect(mockElixirClientCtor).toHaveBeenCalledWith("http://127.0.0.1:4777", "token");
    const output = logSpy.mock.calls.map((call) => call.join(" ")).join("\n");
    expect(output).toContain("would archive  run run-1");
    expect(output).not.toContain("would archive  run run-2");
  });
});
