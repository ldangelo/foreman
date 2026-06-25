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
const mockElixirManagerCtor = vi.hoisted(() => vi.fn());
const mockElixirClientCtor = vi.hoisted(() => vi.fn());
const mockElixirGetTask = vi.hoisted(() => vi.fn());
const mockElixirListRuns = vi.hoisted(() => vi.fn());
const mockElixirSendCommand = vi.hoisted(() => vi.fn());

const mockLocalTaskClient = {
  show: vi.fn().mockResolvedValue({ status: "open", title: "Local bead" }),
  update: vi.fn().mockResolvedValue(undefined),
  resetToReady: vi.fn().mockResolvedValue(undefined),
  ready: vi.fn().mockResolvedValue([]),
  list: vi.fn().mockResolvedValue([]),
  close: vi.fn().mockResolvedValue(undefined),
};

const mockTrpcClient = {
  tasks: {
    get: vi.fn().mockResolvedValue({ status: "open", title: "Registered bead" }),
    retry: vi.fn().mockResolvedValue(undefined),
    update: vi.fn().mockResolvedValue(undefined),
  },
};

const mockLocalStore = {
  getProjectByPath: vi.fn().mockResolvedValue({ id: "local-project", path: "/canonical/project" }),
  getRunsForSeed: vi.fn().mockResolvedValue([]),
  updateRun: vi.fn().mockResolvedValue(undefined),
  logEvent: vi.fn().mockResolvedValue(undefined),
  close: vi.fn(),
};

const mockRegisteredStore = {
  getProjectByPath: vi.fn().mockResolvedValue({ id: "registered-project", path: "/canonical/project" }),
  getRunsForSeed: vi.fn().mockResolvedValue([]),
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

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: mockElixirManagerCtor,
}));

vi.mock("../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: mockElixirClientCtor,
}));

import { retryCommand } from "../commands/retry.js";

const ORIGINAL_FOREMAN_BACKEND = process.env.FOREMAN_BACKEND;

async function runCommand(args: string[]): Promise<void> {
  await retryCommand.parseAsync(["node", "foreman", ...args]);
}

describe("retry command bootstrap", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    delete process.env.FOREMAN_BACKEND;

    mockRequireProjectOrAllInMultiMode.mockResolvedValue(undefined);
    mockResolveRepoRootProjectPath.mockResolvedValue("/canonical/project");
    mockListRegisteredProjects.mockResolvedValue([]);
    mockEnsureCliPostgresPool.mockImplementation(() => undefined);
    mockCreateTaskClient.mockResolvedValue({ taskClient: mockLocalTaskClient, backendType: "beads" });
    mockCreateTrpcClient.mockReturnValue(mockTrpcClient);
    mockForemanForProject.mockReturnValue(mockLocalStore);
    mockPostgresForProject.mockReturnValue(mockRegisteredStore);
    mockDispatcherCtor.mockImplementation(function MockDispatcherImpl(this: Record<string, unknown>) {
      this.dispatch = vi.fn();
    });
    mockPostgresAdapterCtor.mockImplementation(function MockPostgresAdapterImpl(this: Record<string, unknown>) {
      return {};
    });
    mockElixirManagerCtor.mockImplementation(function MockElixirServerManagerImpl() {
      return { url: "http://127.0.0.1:4777", authToken: "token" };
    });
    mockElixirGetTask.mockResolvedValue({ task_id: "bead-1", project_id: "proj-1", status: "failed", title: "Registered bead" });
    mockElixirListRuns.mockResolvedValue([]);
    mockElixirSendCommand.mockResolvedValue({ ok: true, events: ["TaskUpdated"], projection_version: 1, correlation_id: "c1" });
    mockElixirClientCtor.mockImplementation(function MockElixirServerClientImpl() {
      return { getTask: mockElixirGetTask, listRuns: mockElixirListRuns, sendCommand: mockElixirSendCommand };
    });

    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    vi.spyOn(process, "exit").mockImplementation(((code?: number) => code as never) as never);
  });

  afterEach(() => {
    if (ORIGINAL_FOREMAN_BACKEND === undefined) delete process.env.FOREMAN_BACKEND;
    else process.env.FOREMAN_BACKEND = ORIGINAL_FOREMAN_BACKEND;
    vi.restoreAllMocks();
  });

  it("routes registered retry through Elixir in default backend mode", async () => {
    mockResolveRepoRootProjectPath.mockResolvedValue("/canonical/project");
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "my-project", path: "/canonical/project/../project" },
    ]);

    await runCommand(["bead-1", "--dry-run", "--project", "my-project", "--project-path", "/worktrees/my-project"]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({
      project: "my-project",
      projectPath: "/worktrees/my-project",
    });
    expect(mockForemanForProject).toHaveBeenCalledWith("/canonical/project");
    expect(mockEnsureCliPostgresPool).toHaveBeenCalledWith("/canonical/project");
    expect(mockPostgresForProject).not.toHaveBeenCalled();
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockCreateTaskClient).not.toHaveBeenCalled();
    expect(mockPostgresAdapterCtor).not.toHaveBeenCalled();
    expect(mockDispatcherCtor).not.toHaveBeenCalled();
    expect(mockElixirClientCtor).toHaveBeenCalledWith("http://127.0.0.1:4777", "token");
    expect(mockElixirGetTask).toHaveBeenCalledWith("bead-1");

  });

  it("sends Elixir task/run retry events for registered projects", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "my-project", path: "/canonical/project" },
    ]);
    mockElixirGetTask.mockResolvedValue({ task_id: "bead-1", project_id: "proj-1", status: "failed", title: "Registered bead" });
    mockElixirListRuns.mockResolvedValue([
      { run_id: "run-1", task_id: "bead-1", project_id: "proj-1", status: "completed", created_at: "2026-01-01T00:00:00.000Z" },
    ]);

    await runCommand(["bead-1"]);

    expect(mockElixirSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "task.update",
      payload: expect.objectContaining({ project_id: "proj-1", task_id: "bead-1", status: "ready" }),
    }));
    expect(mockElixirSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "run.reset",
      payload: expect.objectContaining({ project_id: "proj-1", run_id: "run-1", reason: "foreman retry" }),
    }));
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
  });

  it("keeps local/unregistered behavior unchanged", async () => {
    await runCommand(["bead-1", "--dry-run"]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockForemanForProject).toHaveBeenCalledWith("/canonical/project");
    expect(mockCreateTaskClient).toHaveBeenCalledWith("/canonical/project");
    expect(mockPostgresForProject).not.toHaveBeenCalled();
    expect(mockEnsureCliPostgresPool).not.toHaveBeenCalled();
    expect(mockDispatcherCtor).not.toHaveBeenCalled();
  });

  it("keeps outside-a-repo behavior unchanged", async () => {
    mockResolveRepoRootProjectPath.mockRejectedValue(new Error("not a repo"));

    await runCommand(["bead-1", "--dry-run"]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockForemanForProject).not.toHaveBeenCalled();
    expect(mockCreateTaskClient).not.toHaveBeenCalled();
    expect(mockPostgresForProject).not.toHaveBeenCalled();
    expect(mockEnsureCliPostgresPool).not.toHaveBeenCalled();
    expect(mockDispatcherCtor).not.toHaveBeenCalled();
  });
});
