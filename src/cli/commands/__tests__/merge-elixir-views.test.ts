import { afterEach, describe, expect, it, vi } from "vitest";

const { mockResolveRepoRootProjectPath, mockFindRegisteredProjectByPath, mockEnsureRunning, mockListRuns, mockRequestMerge, mockElixirClientCtor } = vi.hoisted(() => ({
  mockResolveRepoRootProjectPath: vi.fn(async () => "/repo"),
  mockFindRegisteredProjectByPath: vi.fn(async () => ({ id: "proj-1", name: "demo", path: "/repo" })),
  mockEnsureRunning: vi.fn(async () => ({ running: true, url: "http://127.0.0.1:4777" })),
  mockListRuns: vi.fn(async () => []),
  mockRequestMerge: vi.fn(async () => ({ ok: true, events: ["evt-1"], projection_version: 1, correlation_id: "corr" })),
  mockElixirClientCtor: vi.fn(),
}));

vi.mock("../project-task-support.js", () => ({
  resolveRepoRootProjectPath: mockResolveRepoRootProjectPath,
}));

vi.mock("../project-context.js", () => ({
  findRegisteredProjectByPath: mockFindRegisteredProjectByPath,
}));

vi.mock("../../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: class MockElixirServerManager {
    authToken = "token";
    ensureRunning = mockEnsureRunning;
  },
}));

vi.mock("../../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: class MockElixirServerClient {
    constructor(url: string, token?: string) {
      mockElixirClientCtor(url, token);
    }
    listRuns = mockListRuns;
    requestMerge = mockRequestMerge;
  },
}));

vi.mock("../../../lib/store.js", () => ({ ForemanStore: { forProject: vi.fn(() => { throw new Error("legacy store"); }) } }));
vi.mock("../../../lib/postgres-store.js", () => ({ PostgresStore: vi.fn(() => { throw new Error("postgres store"); }) }));

import { renderElixirMergeView, requestElixirMerge } from "../merge.js";

describe("Elixir merge read-only views", () => {
  afterEach(() => {
    vi.clearAllMocks();
    vi.restoreAllMocks();
  });

  it("lists completed Elixir runs as merge candidates without legacy stores", async () => {
    mockListRuns.mockResolvedValue([
      { run_id: "run-1", task_id: "task-1", status: "completed", branch_name: "foreman/task-1" },
      { run_id: "run-2", task_id: "task-2", status: "running" },
    ] as never);
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await renderElixirMergeView({ list: true, json: true });

    expect(mockFindRegisteredProjectByPath).toHaveBeenCalledWith("/repo", { initPool: false });
    expect(mockElixirClientCtor).toHaveBeenCalledWith("http://127.0.0.1:4777", "token");
    expect(mockListRuns).toHaveBeenCalledWith("proj-1");
    const body = JSON.parse(String(logSpy.mock.calls[0][0]));
    expect(body.entries).toEqual([{ run_id: "run-1", seed_id: "task-1", branch_name: "foreman/task-1", status: "pending", source_status: "completed" }]);
  });

  it("requests Elixir VCS merge operations without opening legacy stores", async () => {
    mockListRuns.mockResolvedValue([
      { run_id: "run-1", task_id: "task-1", status: "completed", branch_name: "foreman/task-1" },
      { run_id: "run-2", task_id: "task-2", status: "running", branch_name: "foreman/task-2" },
    ] as never);
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await requestElixirMerge({ task: "task-1", targetBranch: "dev", json: true });

    expect(mockListRuns).toHaveBeenCalledWith("proj-1");
    expect(mockRequestMerge).toHaveBeenCalledWith({ runId: "run-1", branch: "foreman/task-1", target: "dev" });
    const body = JSON.parse(String(logSpy.mock.calls[0][0]));
    expect(body.requested).toEqual([{ run_id: "run-1", seed_id: "task-1", branch_name: "foreman/task-1", target_branch: "dev" }]);
  });
});
