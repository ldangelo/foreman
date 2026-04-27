import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

const {
  mockProjectsList,
  mockCreateTaskClient,
  mockCreateTaskClients,
  mockGetProjectByPath,
  mockDispatch,
  MockDispatcher,
  MockForemanStore,
  MockPostgresAdapter,
  MockPostgresStore,
  mockPostgresListTasks,
  mockPostgresListPipelineRuns,
  mockCreatePipelineRun,
  mockUpdatePipelineRun,
  mockSendMessage,
  mockRecordPipelineEvent,
  MockRefineryAgent,
  mockRefineryAgentProcessOnce,
  mockAutoMerge,
  MockMergeQueue,
  MockPostgresMergeQueue,
  mockCreateVcsBackend,
  mockResolveRepoRootProjectPath,
} = vi.hoisted(() => {
  const mockProjectsList = vi.fn().mockResolvedValue([]);
  const mockCreateTaskClient = vi.fn().mockResolvedValue({ taskClient: {}, bvClient: null, backendType: "beads" });
  const mockCreateTaskClients = vi.fn().mockResolvedValue({
    taskClient: {},
    bvClient: null,
    backendType: "beads",
  });

  const mockGetProjectByPath = vi.fn().mockReturnValue(null);
  const mockDispatch = vi.fn().mockResolvedValue({ dispatched: [], skipped: [], activeAgents: 0 });
  const MockDispatcher = vi.fn(function (this: Record<string, unknown>) {
    this.dispatch = mockDispatch;
    this.resumeRuns = vi.fn().mockResolvedValue({ resumed: [], skipped: [], activeAgents: 0 });
  });

  const MockForemanStore = vi.fn(function (this: Record<string, unknown>) {
    this.close = vi.fn();
    this.getDb = vi.fn().mockReturnValue({});
    this.getProjectByPath = mockGetProjectByPath;
    this.getSentinelConfig = vi.fn().mockReturnValue(null);
  }) as unknown as ReturnType<typeof vi.fn> & { forProject: ReturnType<typeof vi.fn> };
  MockForemanStore.forProject = vi.fn(() => ({
    close: vi.fn(),
    getDb: vi.fn().mockReturnValue({}),
    getProjectByPath: mockGetProjectByPath,
    getSentinelConfig: vi.fn().mockReturnValue(null),
  }));

  const mockPostgresGetRun = vi.fn().mockReturnValue({ id: "run-1", worktree_path: "/daemon/wt" });
  const mockPostgresListTasks = vi.fn().mockResolvedValue([]);
  const mockPostgresListPipelineRuns = vi.fn().mockResolvedValue([]);
  const mockCreatePipelineRun = vi.fn().mockResolvedValue(undefined);
  const mockUpdatePipelineRun = vi.fn().mockResolvedValue(undefined);
  const mockSendMessage = vi.fn().mockResolvedValue(undefined);
  const mockRecordPipelineEvent = vi.fn().mockResolvedValue(undefined);
  const MockPostgresAdapter = vi.fn(function (this: Record<string, unknown>) {
    this.listTasks = mockPostgresListTasks;
    this.listPipelineRuns = mockPostgresListPipelineRuns;
    this.createPipelineRun = mockCreatePipelineRun;
    this.updatePipelineRun = mockUpdatePipelineRun;
    this.sendMessage = mockSendMessage;
    this.recordPipelineEvent = mockRecordPipelineEvent;
  });
  const MockPostgresStore = vi.fn(function (this: Record<string, unknown>) {
    this.close = vi.fn();
    this.getRun = mockPostgresGetRun;
    this.getDb = vi.fn().mockReturnValue({});
    this.getProjectByPath = mockGetProjectByPath;
    this.getSentinelConfig = vi.fn().mockReturnValue(null);
  }) as unknown as ReturnType<typeof vi.fn> & { forProject: ReturnType<typeof vi.fn> };
  MockPostgresStore.forProject = vi.fn(() => ({
    close: vi.fn(),
    getRun: mockPostgresGetRun,
    getDb: vi.fn().mockReturnValue({}),
    getProjectByPath: mockGetProjectByPath,
    getSentinelConfig: vi.fn().mockReturnValue(null),
  }));

  const mockRefineryAgentProcessOnce = vi.fn(async () => []);
  const MockRefineryAgent = vi.fn(function (this: Record<string, unknown>, ...args: unknown[]) {
    this.args = args;
    this.processOnce = mockRefineryAgentProcessOnce;
    this.start = vi.fn();
    this.stop = vi.fn();
  });

  const mockAutoMerge = vi.fn().mockResolvedValue({ merged: 0, conflicts: 0, failed: 0 });

  const MockMergeQueue = vi.fn(function (this: Record<string, unknown>) {
    this.reconcile = vi.fn();
    this.dequeue = vi.fn();
    this.updateStatus = vi.fn();
  });
  const MockPostgresMergeQueue = vi.fn(function (this: Record<string, unknown>) {
    this.list = vi.fn();
    this.dequeue = vi.fn();
    this.updateStatus = vi.fn();
    this.resetForRetry = vi.fn();
  });

  const mockCreateVcsBackend = vi.fn().mockResolvedValue({
    name: "git",
    getRepoRoot: vi.fn().mockResolvedValue("/mock/project"),
    getCurrentBranch: vi.fn().mockResolvedValue("main"),
    checkoutBranch: vi.fn().mockResolvedValue(undefined),
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
  });
  const mockResolveRepoRootProjectPath = vi.fn().mockResolvedValue("/mock/project");

  return {
    mockProjectsList,
    mockCreateTaskClient,
    mockCreateTaskClients,
    mockGetProjectByPath,
    mockDispatch,
    MockDispatcher,
    MockForemanStore,
    MockPostgresAdapter,
    MockPostgresStore,
    mockPostgresListTasks,
    mockPostgresListPipelineRuns,
    mockCreatePipelineRun,
    mockUpdatePipelineRun,
    mockSendMessage,
    mockRecordPipelineEvent,
    MockRefineryAgent,
    mockRefineryAgentProcessOnce,
    mockAutoMerge,
    MockMergeQueue,
    MockPostgresMergeQueue,
    mockCreateVcsBackend,
    mockResolveRepoRootProjectPath,
  };
});

vi.mock("../../lib/task-client-factory.js", () => ({
  createTaskClient: mockCreateTaskClient,
  createTaskClients: mockCreateTaskClients,
  resolveTaskStoreMode: vi.fn().mockReturnValue("auto"),
}));
vi.mock("../../lib/store.js", () => ({ ForemanStore: MockForemanStore }));
vi.mock("../../lib/db/postgres-adapter.js", () => ({ PostgresAdapter: MockPostgresAdapter }));
vi.mock("../../lib/postgres-store.js", () => ({ PostgresStore: MockPostgresStore }));
vi.mock("../../lib/vcs/index.js", () => ({ VcsBackendFactory: { create: mockCreateVcsBackend } }));
vi.mock("../../orchestrator/dispatcher.js", () => ({ Dispatcher: MockDispatcher, purgeOrphanedWorkerConfigs: vi.fn() }));
vi.mock("../../orchestrator/merge-queue.js", () => ({ MergeQueue: MockMergeQueue }));
vi.mock("../../orchestrator/postgres-merge-queue.js", () => ({ PostgresMergeQueue: MockPostgresMergeQueue }));
vi.mock("../../orchestrator/refinery-agent.js", () => ({ RefineryAgent: MockRefineryAgent, wrapLocalRefineryQueue: (queue: unknown) => queue }));
vi.mock("../../orchestrator/auto-merge.js", () => ({ autoMerge: mockAutoMerge }));
vi.mock("../../orchestrator/notification-server.js", () => ({
  NotificationServer: vi.fn(function (this: Record<string, unknown>) {
    this.start = vi.fn().mockResolvedValue(undefined);
    this.stop = vi.fn().mockResolvedValue(undefined);
    this.url = "http://127.0.0.1:9999";
  }),
}));
vi.mock("../../orchestrator/notification-bus.js", () => ({ notificationBus: {} }));
vi.mock("../../orchestrator/sentinel.js", () => ({ SentinelAgent: vi.fn(), wrapPostgresSentinelStore: (store: unknown) => store }));
vi.mock("../../orchestrator/task-backend-ops.js", () => ({ syncBeadStatusOnStartup: vi.fn() }));
vi.mock("../../orchestrator/pi-rpc-spawn-strategy.js", () => ({ isPiAvailable: vi.fn().mockReturnValue(false) }));
vi.mock("../commands/project-task-support.js", () => ({
  listRegisteredProjects: () => mockProjectsList(),
  ensureCliPostgresPool: vi.fn(),
  resolveRepoRootProjectPath: mockResolveRepoRootProjectPath,
  requireProjectOrAllInMultiMode: vi.fn(),
}));

import { runCommand } from "../commands/run.js";

describe("foreman run startup refinery lookup", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockProjectsList.mockResolvedValue([]);
    mockCreateTaskClients.mockResolvedValue({ taskClient: {}, bvClient: null, backendType: "beads" });
    mockGetProjectByPath.mockReturnValue(null);
    mockRefineryAgentProcessOnce.mockResolvedValue([]);
    mockDispatch.mockResolvedValue({ dispatched: [], skipped: [], activeAgents: 0 });
    mockCreatePipelineRun.mockResolvedValue(undefined);
    mockUpdatePipelineRun.mockResolvedValue(undefined);
    mockSendMessage.mockResolvedValue(undefined);
    mockRecordPipelineEvent.mockResolvedValue(undefined);
    mockCreateVcsBackend.mockResolvedValue({
      name: "git",
      getRepoRoot: vi.fn().mockResolvedValue("/mock/project"),
      getCurrentBranch: vi.fn().mockResolvedValue("main"),
      checkoutBranch: vi.fn().mockResolvedValue(undefined),
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("injects the registered Postgres run lookup into RefineryAgent", async () => {
    const projectPath = "/mock/project";
    mockProjectsList.mockResolvedValue([{ id: "proj-1", name: "my-project", path: projectPath }]);
    mockGetProjectByPath.mockReturnValue({ id: "proj-1", path: projectPath });

    await runCommand.parseAsync(["--project-path", projectPath, "--no-watch"], { from: "user" });

    expect(MockPostgresStore.forProject).toHaveBeenCalledWith("proj-1");
    expect(MockRefineryAgent).toHaveBeenCalledTimes(1);
    expect(MockRefineryAgent.mock.calls[0][4]).toBe(MockPostgresStore.forProject.mock.results[0].value);
    expect(MockForemanStore.forProject).toHaveBeenCalledWith(projectPath);
  });

  it("passes populated dispatcher overrides for registered projects", async () => {
    const projectPath = "/mock/project";
    mockProjectsList.mockResolvedValue([{ id: "proj-1", name: "my-project", path: projectPath }]);
    mockGetProjectByPath.mockReturnValue({ id: "proj-1", path: projectPath });

    await runCommand.parseAsync(["--project-path", projectPath, "--no-watch"], { from: "user" });

    expect(mockCreateTaskClient).toHaveBeenCalledWith(projectPath, expect.objectContaining({
      ensureBrInstalled: true,
      registeredProjectId: "proj-1",
    }));
    expect(MockDispatcher).toHaveBeenCalledTimes(1);
    const overrides = (MockDispatcher.mock.calls as unknown[][])[0]?.[4] as Record<string, unknown>;
    expect(overrides).toMatchObject({
      externalProjectId: "proj-1",
      getRecentFailureCount: expect.any(Function),
      getActiveSeedIds: expect.any(Function),
      getActiveAgentCount: expect.any(Function),
      hasActiveOrPendingRun: expect.any(Function),
      getRunsByStatus: expect.any(Function),
      getRunsForSeed: expect.any(Function),
      getRun: expect.any(Function),
      getActiveRuns: expect.any(Function),
      nativeTaskOps: expect.any(Object),
      runOps: expect.any(Object),
    });
    expect((overrides.nativeTaskOps as Record<string, unknown>).hasNativeTasks).toEqual(expect.any(Function));
    expect((overrides.runOps as Record<string, unknown>).createRun).toEqual(expect.any(Function));
    expect((overrides.runOps as Record<string, unknown>).updateRun).toEqual(expect.any(Function));
    expect((overrides.runOps as Record<string, unknown>).sendMessage).toEqual(expect.any(Function));
    expect((overrides.runOps as Record<string, unknown>).logEvent).toEqual(expect.any(Function));
  });

  it("returns a canonical Run from registered runOps.createRun", async () => {
    const projectPath = "/mock/project";
    mockProjectsList.mockResolvedValue([{ id: "proj-1", name: "my-project", path: projectPath }]);
    mockGetProjectByPath.mockReturnValue({ id: "proj-1", path: projectPath });
    mockPostgresListPipelineRuns.mockResolvedValue([]);

    await runCommand.parseAsync(["--project-path", projectPath, "--no-watch"], { from: "user" });

    const overrides = (MockDispatcher.mock.calls as unknown[][])[0]?.[4] as Record<string, unknown>;
    const runOps = overrides.runOps as { createRun: (args: Record<string, unknown>) => Promise<Record<string, unknown>> };
    const run = await runOps.createRun({
      runId: "run-registered",
      projectId: "proj-1",
      seedId: "seed-1",
      agentType: "claude-sonnet-4-6",
      branchName: "foreman/seed-1",
      worktreePath: "/tmp/worktrees/seed-1",
      baseBranch: null,
      mergeStrategy: "auto",
    });

    expect(mockCreatePipelineRun).toHaveBeenCalledWith(expect.objectContaining({
      id: "run-registered",
      projectId: "proj-1",
      beadId: "seed-1",
      branch: "foreman/seed-1",
      trigger: "bead",
      agentType: "claude-sonnet-4-6",
      worktreePath: "/tmp/worktrees/seed-1",
      mergeStrategy: "auto",
    }));
    expect(run).toMatchObject({
      id: "run-registered",
      project_id: "proj-1",
      seed_id: "seed-1",
      agent_type: "claude-sonnet-4-6",
      session_key: null,
      worktree_path: "/tmp/worktrees/seed-1",
      status: "pending",
      started_at: null,
      completed_at: null,
      progress: null,
      tmux_session: null,
      base_branch: null,
      merge_strategy: "auto",
    });
    expect(typeof run.created_at).toBe("string");
  });

  it("counts recent test-failed runs for onError=stop without reading task rows", async () => {
    const projectPath = "/mock/project";
    mockProjectsList.mockResolvedValue([{ id: "proj-1", name: "my-project", path: projectPath }]);
    mockGetProjectByPath.mockReturnValue({ id: "proj-1", path: projectPath });
    mockPostgresListTasks.mockResolvedValue([
      { id: "task-1", updated_at: "2026-04-25T02:00:00.000Z" },
    ]);
    mockPostgresListPipelineRuns.mockImplementation(async (_projectId: string, filters?: { status?: string }) => {
      switch (filters?.status) {
        case "failed":
        case "stuck":
        case "conflict":
          return [{ created_at: "2026-04-25T00:05:00.000Z", status: filters.status }];
        case "test-failed":
          return [
            { created_at: "2026-04-25T02:00:00.000Z", status: "test-failed" },
            { created_at: "2026-04-24T23:59:59.000Z", status: "test-failed" },
          ];
        default:
          return [];
      }
    });

    await runCommand.parseAsync(["--project-path", projectPath, "--no-watch"], { from: "user" });

    const overrides = (MockDispatcher.mock.calls as unknown[][])[0]?.[4] as Record<string, unknown>;
    const getRecentFailureCount = overrides.getRecentFailureCount as (projectId: string, since: string) => Promise<number>;
    const count = await getRecentFailureCount("proj-1", "2026-04-25T00:30:00.000Z");

    expect(count).toBe(1);
    expect(mockPostgresListTasks).not.toHaveBeenCalled();
    expect(mockPostgresListPipelineRuns).toHaveBeenCalledWith("proj-1", { status: "test-failed", limit: 1000 });
  });

  it("does not fall back to legacy autoMerge for registered startup merge failures", async () => {
    const projectPath = "/mock/project";
    mockProjectsList.mockResolvedValue([{ id: "proj-1", name: "my-project", path: projectPath }]);
    mockGetProjectByPath.mockReturnValue({ id: "proj-1", path: projectPath });
    mockRefineryAgentProcessOnce.mockRejectedValueOnce(new Error("startup merge failed"));

    await runCommand.parseAsync(["--project-path", projectPath, "--no-watch"], { from: "user" });

    expect(mockAutoMerge).not.toHaveBeenCalled();
  });

  it("uses the caller-provided registered project for startup merge instead of re-looking up by path", async () => {
    const projectPath = "/mock/project";
    mockProjectsList
      .mockResolvedValueOnce([{ id: "proj-1", name: "my-project", path: projectPath }])
      .mockResolvedValue([]);
    mockGetProjectByPath.mockReturnValue({ id: "proj-1", path: projectPath });

    await runCommand.parseAsync(["--project-path", projectPath, "--no-watch"], { from: "user" });

    expect(MockPostgresMergeQueue).toHaveBeenCalledWith("proj-1");
    expect(MockMergeQueue).not.toHaveBeenCalled();
  });

  it("resolves registered projects by exact path only", async () => {
    const projectPath = "/mock/project";
    mockProjectsList.mockResolvedValue([{ id: "proj-1", name: "project", path: "/elsewhere/project" }]);
    mockGetProjectByPath.mockReturnValue({ id: "local-project", path: projectPath });

    await runCommand.parseAsync(["--project-path", projectPath, "--no-watch", "--dry-run"], { from: "user" });

    expect(MockPostgresStore.forProject).not.toHaveBeenCalled();
    expect(MockDispatcher).toHaveBeenCalledTimes(1);
    expect((MockDispatcher.mock.calls as unknown[][])[0]?.[4]).toBeUndefined();
  });

  it("falls back to legacy autoMerge with the real task client for local startup merge failures", async () => {
    const projectPath = "/mock/project";
    mockGetProjectByPath.mockReturnValue({ id: "local-project", path: projectPath });
    mockRefineryAgentProcessOnce.mockRejectedValueOnce(new Error("startup merge failed"));

    await runCommand.parseAsync(["--project-path", projectPath, "--no-watch"], { from: "user" });

    expect(mockAutoMerge).toHaveBeenCalledTimes(1);
    expect(mockAutoMerge.mock.calls[0][0]).toMatchObject({ projectPath });
    expect(mockAutoMerge.mock.calls[0][0].taskClient).toBeTruthy();
  });
});
