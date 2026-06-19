import { describe, expect, it, beforeEach, afterEach, vi } from "vitest";

const { previousFeatureFlag, mockResolveRepoRootProjectPath, mockListRegisteredProjects, mockPostgresStoreForProject, mockVcsCreate, MockForemanStore, MockMergeQueue, MockPostgresMergeQueue, MockRefineryAgent, mockWrapLocalRefineryQueue } = vi.hoisted(() => {
  const previousFeatureFlag = process.env.FOREMAN_USE_REFINERY_AGENT;
  process.env.FOREMAN_USE_REFINERY_AGENT = "false";
  vi.spyOn(process, "exit").mockImplementation((() => undefined) as never);

  const mockResolveRepoRootProjectPath = vi.fn();
  const mockListRegisteredProjects = vi.fn();
  const mockPostgresStoreForProject = vi.fn();
  const mockVcsCreate = vi.fn();
  const mockWrapLocalRefineryQueue = vi.fn((queue: unknown) => queue);

  const MockForemanStore = vi.fn(function (this: Record<string, unknown>) {
    throw new Error("new ForemanStore() should not be used in refinery-agent-cli");
}) as unknown as ReturnType<typeof vi.fn> & { forProject: ReturnType<typeof vi.fn> };

  const localDb = { id: "local-db" };
  const localStore = {
    close: vi.fn(),
    getDb: vi.fn(() => localDb),
    getProjectByPath: vi.fn(),
  };
  MockForemanStore.forProject = vi.fn(() => localStore);

  const MockMergeQueue = vi.fn(function (this: Record<string, unknown>, db: unknown) {
    this.db = db;
  });

  const MockPostgresMergeQueue = vi.fn(function (this: Record<string, unknown>, projectId: string) {
    this.projectId = projectId;
  });

  const MockRefineryAgent = vi.fn(function (this: Record<string, unknown>) {
    this.processOnce = vi.fn().mockResolvedValue([]);
    this.start = vi.fn().mockResolvedValue(undefined);
    this.stop = vi.fn();
  });

  return {
    previousFeatureFlag,
    mockResolveRepoRootProjectPath,
    mockListRegisteredProjects,
    mockPostgresStoreForProject,
    mockVcsCreate,
    MockForemanStore,
    MockMergeQueue,
    MockPostgresMergeQueue,
    MockRefineryAgent,
    mockWrapLocalRefineryQueue,
  };
});

vi.mock("../../lib/store.js", () => ({ ForemanStore: MockForemanStore }));
vi.mock("../../lib/postgres-store.js", () => ({ PostgresStore: { forProject: mockPostgresStoreForProject } }));
vi.mock("../merge-queue.js", () => ({ MergeQueue: MockMergeQueue }));
vi.mock("../postgres-merge-queue.js", () => ({ PostgresMergeQueue: MockPostgresMergeQueue }));
vi.mock("../refinery-agent.js", () => ({
  RefineryAgent: MockRefineryAgent,
  wrapLocalRefineryQueue: (queue: unknown) => mockWrapLocalRefineryQueue(queue),
}));
vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: (...args: unknown[]) => mockVcsCreate(...args),
  },
}));
vi.mock("../../cli/commands/project-task-support.js", () => ({
  listRegisteredProjects: (...args: unknown[]) => mockListRegisteredProjects(...args),
  resolveRepoRootProjectPath: (...args: unknown[]) => mockResolveRepoRootProjectPath(...args),
}));

import { runRefineCli } from "../refinery-agent-cli.js";

describe("runRefineCli bootstrap context", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    process.env.FOREMAN_USE_REFINERY_AGENT = "true";

    mockResolveRepoRootProjectPath.mockResolvedValue("/repo/canonical");
    mockListRegisteredProjects.mockResolvedValue([]);
    mockPostgresStoreForProject.mockReturnValue({ runLookup: true });
    mockVcsCreate.mockResolvedValue({});
  });

  afterEach(() => {
    process.env.FOREMAN_USE_REFINERY_AGENT = previousFeatureFlag;
    vi.restoreAllMocks();
  });

  it("resolves registered --once runs through the canonical project path and registered run lookup", async () => {
    mockListRegisteredProjects.mockResolvedValue([{ id: "registered-id", path: "/repo/canonical", name: "test" }]);

    await runRefineCli(["--once"]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(MockForemanStore.forProject).toHaveBeenCalledWith("/repo/canonical");
    expect(mockVcsCreate).toHaveBeenCalledWith({ backend: "auto" }, "/repo/canonical");
    expect(mockPostgresStoreForProject).toHaveBeenCalledWith("registered-id");
    expect(MockPostgresMergeQueue).toHaveBeenCalledWith("registered-id");
    expect(MockRefineryAgent).toHaveBeenCalledWith(
      expect.any(Object),
      expect.any(Object),
      "/repo/canonical",
      expect.objectContaining({ projectPath: "/repo/canonical" }),
      { runLookup: true },
    );
  });

  it("keeps local unregistered bootstrap on ForemanStore.forProject(projectPath)", async () => {
    await runRefineCli(["--once"]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(MockForemanStore.forProject).toHaveBeenCalledWith("/repo/canonical");
    expect(mockPostgresStoreForProject).not.toHaveBeenCalled();
    expect(MockMergeQueue).toHaveBeenCalledWith({ id: "local-db" });
    expect(mockWrapLocalRefineryQueue).toHaveBeenCalled();
    expect(MockRefineryAgent).toHaveBeenCalledWith(
      expect.any(Object),
      expect.any(Object),
      "/repo/canonical",
      expect.objectContaining({ projectPath: "/repo/canonical" }),
      undefined,
    );
  });
});
