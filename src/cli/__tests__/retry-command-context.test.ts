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

import { retryCommand } from "../commands/retry.js";

async function runCommand(args: string[]): Promise<void> {
  await retryCommand.parseAsync(["node", "foreman", ...args]);
}

describe("retry command bootstrap", () => {
  beforeEach(() => {
    vi.clearAllMocks();

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

    await runCommand(["bead-1", "--dry-run", "--project", "my-project", "--project-path", "/worktrees/my-project"]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({
      project: "my-project",
      projectPath: "/worktrees/my-project",
    });
    expect(mockForemanForProject).toHaveBeenCalledWith("/canonical/project");
    expect(mockEnsureCliPostgresPool).toHaveBeenCalledWith("/canonical/project");
    expect(mockPostgresForProject).toHaveBeenCalledWith("proj-1");
    expect(mockCreateTaskClient).not.toHaveBeenCalled();
    expect(mockPostgresAdapterCtor).toHaveBeenCalledTimes(1);
    expect(mockDispatcherCtor).toHaveBeenCalledTimes(1);
    const overrides = (mockDispatcherCtor.mock.calls as unknown[][])[0]?.[4] as Record<string, unknown>;
    const runOps = overrides.runOps as Record<string, unknown>;
    expect(runOps.createRun).toBeTypeOf("function");
    expect(runOps.updateRun).toBeTypeOf("function");
    expect(runOps.sendMessage).toBeTypeOf("function");
    expect(runOps.logEvent).toBeTypeOf("function");

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
