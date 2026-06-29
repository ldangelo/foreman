import { afterEach, describe, expect, it, vi } from "vitest";

const { mockStatus, mockHealth, mockListRuns, mockListTasks, mockArchiveRun, mockPurgeRun, mockElixirClientCtor } = vi.hoisted(() => ({
  mockStatus: vi.fn(() => ({ running: true, url: "http://127.0.0.1:4777", pidPath: "/tmp/pid" })),
  mockHealth: vi.fn(async () => ({ ok: true })),
  mockListRuns: vi.fn(async () => []),
  mockListTasks: vi.fn(async () => []),
  mockArchiveRun: vi.fn(async () => ({ ok: true })),
  mockPurgeRun: vi.fn(async () => ({ ok: true })),
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
    archiveRun = mockArchiveRun;
    purgeRun = mockPurgeRun;
  },
}));

import { purgeZombieRunsElixirAction, purgeZombieRunsElixirDryRun } from "../purge-zombie-runs.js";

describe("Elixir purge runs dry-run", () => {
  afterEach(() => {
    vi.clearAllMocks();
    vi.restoreAllMocks();
  });

  it("archives failed Elixir runs whose tasks are closed", async () => {
    mockListRuns.mockResolvedValue([
      { run_id: "run-1", task_id: "task-1", status: "failed" },
      { run_id: "run-2", task_id: "task-2", status: "failed" },
    ] as never);
    mockListTasks.mockResolvedValue([
      { task_id: "task-1", status: "closed" },
      { task_id: "task-2", status: "ready" },
    ] as never);
    vi.spyOn(console, "log").mockImplementation(() => undefined);

    const exitCode = await purgeZombieRunsElixirAction({});

    expect(exitCode).toBe(0);
    expect(mockArchiveRun).toHaveBeenCalledWith("run-1");
    expect(mockArchiveRun).not.toHaveBeenCalledWith("run-2");
    expect(mockPurgeRun).not.toHaveBeenCalled();
  });

  it("purges failed Elixir runs when requested", async () => {
    mockListRuns.mockResolvedValue([{ run_id: "run-1", task_id: "task-1", status: "failed" }] as never);
    mockListTasks.mockResolvedValue([{ task_id: "task-1", status: "closed" }] as never);
    vi.spyOn(console, "log").mockImplementation(() => undefined);

    const exitCode = await purgeZombieRunsElixirAction({ purge: true });

    expect(exitCode).toBe(0);
    expect(mockPurgeRun).toHaveBeenCalledWith("run-1");
    expect(mockArchiveRun).not.toHaveBeenCalled();
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
