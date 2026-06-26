import { afterEach, describe, expect, it, vi } from "vitest";

const {
  mockResolveRepoRootProjectPath,
  mockRequireProjectOrAll,
  mockListRegisteredProjects,
  mockStatus,
  mockHealth,
  mockListProjects,
  mockListTasks,
  mockListDispatchableTasks,
  mockListRuns,
  mockListSchedulerSkips,
  mockElixirClientCtor,
} = vi.hoisted(() => ({
  mockResolveRepoRootProjectPath: vi.fn(async () => "/repo"),
  mockRequireProjectOrAll: vi.fn(async () => undefined),
  mockListRegisteredProjects: vi.fn(async () => [{ id: "proj-1", name: "test", path: "/repo" }]),
  mockStatus: vi.fn(() => ({ running: true, url: "http://127.0.0.1:4777", pidPath: "/tmp/pid" })),
  mockHealth: vi.fn(async () => ({ ok: true })),
  mockListProjects: vi.fn(async () => [{ id: "proj-1", name: "test", path: "/repo" }]),
  mockListTasks: vi.fn(async () => []),
  mockListDispatchableTasks: vi.fn(async () => []),
  mockListRuns: vi.fn(async () => []),
  mockListSchedulerSkips: vi.fn(async () => []),
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
    listProjects = mockListProjects;
    listTasks = mockListTasks;
    listDispatchableTasks = mockListDispatchableTasks;
    listRuns = mockListRuns;
    listSchedulerSkips = mockListSchedulerSkips;
  },
}));

vi.mock("../project-task-support.js", () => ({
  resolveRepoRootProjectPath: mockResolveRepoRootProjectPath,
  requireProjectOrAllInMultiMode: mockRequireProjectOrAll,
  listRegisteredProjects: mockListRegisteredProjects,
  ensureCliPostgresPool: vi.fn(),
}));

import { runElixirDryRun } from "../run.js";

describe("Elixir run dry-run", () => {
  afterEach(() => {
    vi.clearAllMocks();
    vi.restoreAllMocks();
  });

  it("summarizes scheduler candidates from Elixir projections", async () => {
    mockListTasks.mockResolvedValue([
      { task_id: "task-1", project_id: "proj-1", status: "ready", title: "Ready task" },
      { task_id: "task-active", project_id: "proj-1", status: "in_progress", title: "Active task" },
      { task_id: "task-2", project_id: "proj-1", status: "closed", title: "Closed task" },
    ] as never);
    mockListDispatchableTasks.mockResolvedValue([
      { task_id: "task-1", project_id: "proj-1", status: "ready", title: "Ready task" },
    ] as never);
    mockListRuns.mockResolvedValue([
      { run_id: "run-1", task_id: "task-active", project_id: "proj-1", status: "in_progress" },
    ] as never);
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    const exitCode = await runElixirDryRun({ maxAgents: "3" });

    expect(exitCode).toBe(0);
    expect(mockRequireProjectOrAll).toHaveBeenCalledWith(undefined, false);
    expect(mockListRegisteredProjects).not.toHaveBeenCalled();
    expect(mockListProjects).toHaveBeenCalledOnce();
    expect(mockElixirClientCtor).toHaveBeenCalledWith("http://127.0.0.1:4777", "token");
    expect(mockListTasks).toHaveBeenCalledOnce();
    expect(mockListDispatchableTasks).toHaveBeenCalledOnce();
    expect(mockListRuns).toHaveBeenCalledWith("proj-1");
    expect(mockListSchedulerSkips).toHaveBeenCalledWith("proj-1");
    const output = logSpy.mock.calls.map((call) => call.join(" ")).join("\n");
    expect(output).toContain("Runnable tasks: 1");
    expect(output).toContain("task-1 ready Ready task");
  });

  it("filters by requested task id", async () => {
    mockListTasks.mockResolvedValue([
      { task_id: "task-1", project_id: "proj-1", status: "ready", title: "One" },
      { task_id: "task-2", project_id: "proj-1", status: "ready", title: "Two" },
    ] as never);
    mockListDispatchableTasks.mockResolvedValue([
      { task_id: "task-1", project_id: "proj-1", status: "ready", title: "One" },
      { task_id: "task-2", project_id: "proj-1", status: "ready", title: "Two" },
    ] as never);
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    const exitCode = await runElixirDryRun({ task: "task-2", maxAgents: "5" });

    expect(exitCode).toBe(0);
    const output = logSpy.mock.calls.map((call) => call.join(" ")).join("\n");
    expect(output).toContain("Runnable tasks: 1");
    expect(output).toContain("task-2 ready Two");
    expect(output).not.toContain("task-1 ready One");
  });
});
