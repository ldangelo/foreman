import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mockResolveRepoRootProjectPath = vi.hoisted(() => vi.fn());
const mockRequireProjectOrAllInMultiMode = vi.hoisted(() => vi.fn());
const mockListRegisteredProjects = vi.hoisted(() => vi.fn());
const mockEnsureCliPostgresPool = vi.hoisted(() => vi.fn());
const mockCreateTaskClient = vi.hoisted(() => vi.fn());
const mockCreateTrpcClient = vi.hoisted(() => vi.fn());
const mockForemanForProject = vi.hoisted(() => vi.fn());
const mockPostgresForProject = vi.hoisted(() => vi.fn());
const mockDispatcherCtor = vi.hoisted(() => vi.fn());
const mockPostgresAdapterCtor = vi.hoisted(() => vi.fn());
const mockForemanBackendMode = vi.hoisted(() => vi.fn());
const mockEnsureRunning = vi.hoisted(() => vi.fn());
const mockGetTask = vi.hoisted(() => vi.fn());
const mockListRuns = vi.hoisted(() => vi.fn());
const mockSendCommand = vi.hoisted(() => vi.fn());
const mockSchedulerTick = vi.hoisted(() => vi.fn());

const mockLocalTaskClient = {
  show: vi.fn().mockResolvedValue({ status: "open", title: "Local task" }),
  update: vi.fn().mockResolvedValue(undefined),
  resetToReady: vi.fn().mockResolvedValue(undefined),
  ready: vi.fn().mockResolvedValue([]),
  list: vi.fn().mockResolvedValue([]),
  close: vi.fn().mockResolvedValue(undefined),
};

const mockTrpcClient = {
  tasks: {
    get: vi.fn().mockResolvedValue({ status: "open", title: "Registered task" }),
    retry: vi.fn().mockResolvedValue(undefined),
    update: vi.fn().mockResolvedValue(undefined),
  },
};

const mockLocalStore = {
  getProjectByPath: vi.fn().mockResolvedValue({ id: "local-project", path: "/canonical/project" }),
  getRunsForTask: vi.fn().mockResolvedValue([]),
  updateRun: vi.fn().mockResolvedValue(undefined),
  logEvent: vi.fn().mockResolvedValue(undefined),
  close: vi.fn(),
};

const mockRegisteredStore = {
  getProjectByPath: vi.fn().mockResolvedValue({ id: "registered-project", path: "/canonical/project" }),
  getRunsForTask: vi.fn().mockResolvedValue([]),
  updateRun: vi.fn().mockResolvedValue(undefined),
  logEvent: vi.fn().mockResolvedValue(undefined),
  close: vi.fn(),
};

vi.mock("../commands/project-task-support.js", () => ({
  resolveRepoRootProjectPath: mockResolveRepoRootProjectPath,
  requireProjectOrAllInMultiMode: mockRequireProjectOrAllInMultiMode,
  listRegisteredProjects: mockListRegisteredProjects,
  ensureCliPostgresPool: mockEnsureCliPostgresPool,
}));

vi.mock("../../lib/task-client-factory.js", () => ({
  createTaskClient: mockCreateTaskClient,
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: mockForemanBackendMode,
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn().mockImplementation(function MockElixirServerManager() {
    return { ensureRunning: mockEnsureRunning };
  }),
}));

vi.mock("../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: vi.fn().mockImplementation(function MockElixirServerClient() {
    return {
      getTask: mockGetTask,
      listRuns: mockListRuns,
      sendCommand: mockSendCommand,
      schedulerTick: mockSchedulerTick,
    };
  }),
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: mockForemanForProject,
  },
}));

vi.mock("../../lib/postgres-store.js", () => ({
  PostgresStore: {
    forProject: mockPostgresForProject,
  },
}));

vi.mock("../../lib/db/postgres-adapter.js", () => ({
  PostgresAdapter: mockPostgresAdapterCtor,
}));

vi.mock("../../orchestrator/dispatcher.js", () => ({
  Dispatcher: mockDispatcherCtor,
}));

import { retryCommand } from "../commands/retry.js";

async function runCommand(args: string[]): Promise<void> {
  await retryCommand.parseAsync(["node", "foreman", ...args]);
}

describe("retry command bootstrap", () => {
  beforeEach(() => {
    vi.clearAllMocks();

    mockRequireProjectOrAllInMultiMode.mockResolvedValue(undefined);
    mockResolveRepoRootProjectPath.mockResolvedValue("/canonical/project");
    mockForemanBackendMode.mockReturnValue("node");
    mockListRegisteredProjects.mockResolvedValue([]);
    mockListRegisteredProjects.mockResolvedValue([]);
    mockEnsureCliPostgresPool.mockImplementation(() => undefined);
    mockCreateTaskClient.mockResolvedValue({ taskClient: mockLocalTaskClient, backendType: "tasks" });
    mockCreateTrpcClient.mockReturnValue(mockTrpcClient);
    mockForemanForProject.mockReturnValue(mockLocalStore);
    mockPostgresForProject.mockReturnValue(mockRegisteredStore);
    mockDispatcherCtor.mockImplementation(function MockDispatcherImpl(this: Record<string, unknown>) {
      this.dispatch = vi.fn();
    });
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockGetTask.mockResolvedValue({ task_id: "task-1", project_id: "proj-1", status: "failed", title: "Registered task" });
    mockListRuns.mockResolvedValue([]);
    mockSendCommand.mockResolvedValue({ ok: true, events: ["evt-1"], projection_version: 1, correlation_id: "corr-1" });
    mockSchedulerTick.mockResolvedValue({ claimed: [], skipped: [] });
    mockPostgresAdapterCtor.mockImplementation(function MockPostgresAdapterImpl(this: Record<string, unknown>) {
      return {};
    });

    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    vi.spyOn(process, "exit").mockImplementation(((code?: number) => code as never) as never);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("resolves a registered retry bootstrap to the canonical project path from a non-canonical clone", async () => {
    mockResolveRepoRootProjectPath.mockResolvedValue("/canonical/project");
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "my-project", path: "/canonical/project/../project" },
    ]);

    await runCommand(["task-1", "--dry-run", "--project", "my-project", "--project-path", "/worktrees/my-project"]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({
      project: "my-project",
      projectPath: "/worktrees/my-project",
    });
    expect(mockForemanForProject).toHaveBeenCalledWith("/canonical/project");
    expect(mockCreateTaskClient).not.toHaveBeenCalled();
    expect(mockPostgresForProject).not.toHaveBeenCalled();
    expect(mockPostgresAdapterCtor).not.toHaveBeenCalled();
    expect(mockDispatcherCtor).not.toHaveBeenCalled();
    expect(mockGetTask).toHaveBeenCalledWith("task-1");
    expect(mockListRuns).toHaveBeenCalledWith({ projectId: "proj-1" });

  });

  it("routes registered retry through Elixir task/runs APIs in Elixir mode", async () => {
    mockForemanBackendMode.mockReturnValue("elixir");
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "my-project", path: "/canonical/project" },
    ]);

    await runCommand(["task-1", "--dry-run", "--project", "my-project", "--project-path", "/worktrees/my-project"]);

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockCreateTaskClient).not.toHaveBeenCalled();
    expect(mockGetTask).toHaveBeenCalledWith("task-1");
    expect(mockListRuns).toHaveBeenCalledWith({ projectId: "proj-1" });
    expect(mockSendCommand).not.toHaveBeenCalled();
    expect(mockSchedulerTick).not.toHaveBeenCalled();
    expect(mockPostgresForProject).not.toHaveBeenCalled();
    expect(mockDispatcherCtor).not.toHaveBeenCalled();
  });

  it("routes registered retry --dispatch through Elixir scheduler tick in Elixir mode", async () => {
    mockForemanBackendMode.mockReturnValue("elixir");
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "my-project", path: "/canonical/project" },
    ]);

    await runCommand(["task-1", "--dispatch", "--project", "my-project", "--project-path", "/worktrees/my-project"]);

    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "task.update",
      payload: expect.objectContaining({ project_id: "proj-1", task_id: "task-1", status: "ready" }),
    }));
    expect(mockSchedulerTick).toHaveBeenCalledTimes(1);
  });

  it("fails closed in Elixir mode when the resolved project is not registered", async () => {
    mockForemanBackendMode.mockReturnValue("elixir");
    mockListRegisteredProjects.mockResolvedValue([]);

    await runCommand(["task-1", "--project-path", "/canonical/project"]);

    expect(mockGetTask).not.toHaveBeenCalled();
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("not registered in Elixir projections");
  });

  it("keeps local/unregistered behavior unchanged", async () => {
    await runCommand(["task-1", "--dry-run"]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockForemanForProject).toHaveBeenCalledWith("/canonical/project");
    expect(mockCreateTaskClient).toHaveBeenCalledWith("/canonical/project");
    expect(mockPostgresForProject).not.toHaveBeenCalled();
    expect(mockEnsureCliPostgresPool).not.toHaveBeenCalled();
    expect(mockDispatcherCtor).not.toHaveBeenCalled();
  });

  it("keeps outside-a-repo behavior unchanged", async () => {
    mockResolveRepoRootProjectPath.mockRejectedValue(new Error("not a repo"));

    await runCommand(["task-1", "--dry-run"]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockForemanForProject).not.toHaveBeenCalled();
    expect(mockCreateTaskClient).not.toHaveBeenCalled();
    expect(mockPostgresForProject).not.toHaveBeenCalled();
    expect(mockEnsureCliPostgresPool).not.toHaveBeenCalled();
    expect(mockDispatcherCtor).not.toHaveBeenCalled();
  });
});
