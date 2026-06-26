import { afterEach, describe, expect, it, vi } from "vitest";
import type { Run } from "../../lib/store.js";

const {
  mockResolveRepoRootProjectPath,
  mockFindRegisteredProjectByPath,
  mockEnsureElixirRunning,
  mockListElixirRuns,
  mockElixirClientCtor,
  mockForemanForProject,
  mockPostgresForProject,
} = vi.hoisted(() => ({
  mockResolveRepoRootProjectPath: vi.fn(),
  mockFindRegisteredProjectByPath: vi.fn(),
  mockEnsureElixirRunning: vi.fn(async () => ({ running: true, url: "http://127.0.0.1:4777" })),
  mockListElixirRuns: vi.fn(async () => []),
  mockElixirClientCtor: vi.fn(),
  mockForemanForProject: vi.fn(),
  mockPostgresForProject: vi.fn(),
}));

vi.mock("../commands/project-task-support.js", () => ({
  resolveRepoRootProjectPath: mockResolveRepoRootProjectPath,
}));

vi.mock("../commands/project-context.js", () => ({
  findRegisteredProjectByPath: mockFindRegisteredProjectByPath,
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: class MockElixirServerManager {
    authToken = "token";
    ensureRunning = mockEnsureElixirRunning;
  },
}));

vi.mock("../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: class MockElixirServerClient {
    constructor(url: string, token?: string) {
      mockElixirClientCtor(url, token);
    }
    listRuns = mockListElixirRuns;
  },
}));

vi.mock("../../lib/store.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../lib/store.js")>();
  return {
    ...actual,
    ForemanStore: { forProject: mockForemanForProject },
  };
});

vi.mock("../../lib/postgres-store.js", () => ({
  PostgresStore: { forProject: mockPostgresForProject },
}));

import { stopAction, stopCommand, stopCommandAction } from "../commands/stop.js";

describe("stop command", () => {
  const originalBackend = process.env.FOREMAN_BACKEND;

  afterEach(() => {
    if (originalBackend === undefined) delete process.env.FOREMAN_BACKEND;
    else process.env.FOREMAN_BACKEND = originalBackend;
    vi.clearAllMocks();
    vi.restoreAllMocks();
  });

  it("loads the production command", () => {
    expect(stopCommand.name()).toBe("stop");
  });

  it("resolves bead IDs without querying getRun as a UUID", async () => {
    const run = makeRun({ id: "550e8400-e29b-41d4-a716-446655440000", seed_id: "foreman-e59b5" });
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "project-1", path: "/repo" }),
      getActiveRuns: vi.fn().mockResolvedValue([]),
      getRun: vi.fn().mockRejectedValue(new Error("should not query getRun for non-UUID bead id")),
      getRunsForSeed: vi.fn().mockResolvedValue([run]),
      updateRun: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };

    const exitCode = await stopAction("foreman-e59b5", { force: false, dryRun: true }, store, "/repo");

    expect(exitCode).toBe(0);
    expect(store.getRun).not.toHaveBeenCalled();
    expect(store.getRunsForSeed).toHaveBeenCalledWith("foreman-e59b5", "project-1");
  });

  it("lists active Elixir runs without opening legacy stores", async () => {
    delete process.env.FOREMAN_BACKEND;
    mockResolveRepoRootProjectPath.mockResolvedValue("/repo");
    mockFindRegisteredProjectByPath.mockResolvedValue({ id: "project-1", name: "test", path: "/repo" });
    mockListElixirRuns.mockResolvedValue([
      {
        run_id: "run-1",
        task_id: "task-1",
        project_id: "project-1",
        status: "running",
        started_at: new Date(Date.now() - 60_000).toISOString(),
        worker_pid: 1234,
      },
      { run_id: "run-2", task_id: "task-2", project_id: "project-1", status: "completed" },
    ] as never);
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    const exitCode = await stopCommandAction(undefined, { list: true });

    expect(exitCode).toBe(0);
    expect(mockFindRegisteredProjectByPath).toHaveBeenCalledWith("/repo", { initPool: false });
    expect(mockForemanForProject).not.toHaveBeenCalled();
    expect(mockPostgresForProject).not.toHaveBeenCalled();
    expect(mockElixirClientCtor).toHaveBeenCalledWith("http://127.0.0.1:4777", "token");
    expect(mockListElixirRuns).toHaveBeenCalledWith("project-1");
    expect(logSpy.mock.calls.map((call) => call.join(" ")).join("\n")).toContain("task-1");
  });

  it("still guards Elixir stop mutations", async () => {
    delete process.env.FOREMAN_BACKEND;
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    const exitCode = await stopCommandAction("task-1", {});

    expect(exitCode).toBe(1);
    expect(errorSpy.mock.calls.map((call) => call.join(" ")).join("\n")).toContain("foreman stop uses legacy run stores");
    expect(mockResolveRepoRootProjectPath).not.toHaveBeenCalled();
    expect(mockForemanForProject).not.toHaveBeenCalled();
  });

  it("resolves UUID run IDs before falling back to seed lookup", async () => {
    const run = makeRun({ id: "550e8400-e29b-41d4-a716-446655440000" });
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "project-1", path: "/repo" }),
      getActiveRuns: vi.fn().mockResolvedValue([]),
      getRun: vi.fn().mockResolvedValue(run),
      getRunsForSeed: vi.fn().mockResolvedValue([]),
      updateRun: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };

    const exitCode = await stopAction(run.id, { force: false, dryRun: true }, store, "/repo");

    expect(exitCode).toBe(0);
    expect(store.getRun).toHaveBeenCalledWith(run.id);
    expect(store.getRunsForSeed).not.toHaveBeenCalled();
  });
});

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "project-1",
    seed_id: "seed-1",
    agent_type: "minimax/MiniMax-M2.7",
    session_key: null,
    worktree_path: null,
    status: "running",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,
    ...overrides,
  };
}
