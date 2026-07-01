import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Run } from "../../lib/store.js";

const {
  mockResolveProjectContext,
  mockLocalStore,
  mockPostgresStore,
  mockMergeQueueList,
  mockMergeQueueRemove,
  mockRemoveWorkspace,
  mockDeleteBranch,
  mockBranchExists,
} = vi.hoisted(() => {
  const mockResolveProjectContext = vi.fn();
  const mockLocalStore = {
    getDb: vi.fn(() => ({})),
    close: vi.fn(),
    getRun: vi.fn(),
    getRunsForSeed: vi.fn(),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    updateTaskStatus: vi.fn(),
    getRunsByStatus: vi.fn(),
  };
  const mockPostgresStore = {
    close: vi.fn(),
    getRun: vi.fn(),
    getRunsForSeed: vi.fn(),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    updateTaskStatus: vi.fn(),
    getRunsByStatus: vi.fn(),
  };
  const mockMergeQueueList = vi.fn(async () => []);
  const mockMergeQueueRemove = vi.fn(async () => {});
  const mockRemoveWorkspace = vi.fn(async () => {});
  const mockDeleteBranch = vi.fn(async () => ({ deleted: true, wasFullyMerged: false }));
  const mockBranchExists = vi.fn(async () => false);
  return {
    mockResolveProjectContext,
    mockLocalStore,
    mockPostgresStore,
    mockMergeQueueList,
    mockMergeQueueRemove,
    mockRemoveWorkspace,
    mockDeleteBranch,
    mockBranchExists,
  };
});

vi.mock("../commands/project-context.js", () => ({
  resolveProjectContext: mockResolveProjectContext,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: { forProject: vi.fn(() => mockLocalStore) },
}));

vi.mock("../../lib/postgres-store.js", () => ({
  PostgresStore: { forProject: vi.fn(() => mockPostgresStore) },
}));

vi.mock("../../orchestrator/merge-queue.js", () => ({
  MergeQueue: class MockMergeQueue {
    list = mockMergeQueueList;
    remove = mockMergeQueueRemove;
  },
}));

vi.mock("../../orchestrator/postgres-merge-queue.js", () => ({
  PostgresMergeQueue: class MockPostgresMergeQueue {
    list = mockMergeQueueList;
    remove = mockMergeQueueRemove;
  },
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: vi.fn(async () => ({
      removeWorkspace: mockRemoveWorkspace,
      deleteBranch: mockDeleteBranch,
      branchExists: mockBranchExists,
    })),
  },
}));

vi.mock("../../lib/archive-reports.js", () => ({
  archiveWorktreeReports: vi.fn(async () => {}),
}));

import { abandonAction } from "../commands/abandon.js";

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "task-1",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: "/tmp/wt/task-1",
    status: "completed",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,
    ...overrides,
  };
}

describe("abandonAction", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockResolveProjectContext.mockResolvedValue({ projectPath: "/tmp/project", registered: { id: "proj-1" } });
    mockPostgresStore.getRun.mockResolvedValue(makeRun());
    mockPostgresStore.getRunsForSeed.mockResolvedValue([]);
    mockPostgresStore.getRunsByStatus.mockResolvedValue([]);
    mockBranchExists.mockResolvedValue(false);
    mockMergeQueueList.mockResolvedValue([
      { id: 7, run_id: "run-1", seed_id: "task-1", branch_name: "foreman/task-1" },
    ] as never);
  });

  it("removes queue entries and worktree, blocks task, and marks run failed", async () => {
    const code = await abandonAction("run-1", { reason: "too stale" });

    expect(code).toBe(0);
    expect(mockMergeQueueRemove).toHaveBeenCalledWith(7);
    expect(mockRemoveWorkspace).toHaveBeenCalledWith("/tmp/project", "/tmp/wt/task-1");
    expect(mockPostgresStore.updateTaskStatus).toHaveBeenCalledWith("task-1", "blocked");
    expect(mockPostgresStore.updateRun).toHaveBeenCalledWith("run-1", expect.objectContaining({ status: "failed", merge_strategy: "none" }));
  });

  it("dry-run does not mutate", async () => {
    const code = await abandonAction("run-1", { dryRun: true, deleteBranch: true });

    expect(code).toBe(0);
    expect(mockMergeQueueRemove).not.toHaveBeenCalled();
    expect(mockRemoveWorkspace).not.toHaveBeenCalled();
    expect(mockDeleteBranch).not.toHaveBeenCalled();
    expect(mockPostgresStore.updateRun).not.toHaveBeenCalled();
  });

  it("deletes branch only when requested", async () => {
    await abandonAction("run-1", { deleteBranch: true, force: true });

    expect(mockDeleteBranch).toHaveBeenCalledWith("/tmp/project", "foreman/task-1", { force: true });
  });

  it("bulk-abandons completed runs with missing branches", async () => {
    mockPostgresStore.getRunsByStatus.mockResolvedValue([
      makeRun({ id: "run-1", seed_id: "task-1" }),
      makeRun({ id: "run-2", seed_id: "task-2", worktree_path: "/tmp/wt/task-2" }),
    ]);
    mockBranchExists.mockResolvedValueOnce(false).mockResolvedValueOnce(true);

    const code = await abandonAction(undefined, { missingBranches: true, reason: "branch missing" });

    expect(code).toBe(0);
    expect(mockPostgresStore.updateRun).toHaveBeenCalledTimes(1);
    expect(mockPostgresStore.updateRun).toHaveBeenCalledWith("run-1", expect.objectContaining({ status: "failed", merge_strategy: "none" }));
    expect(mockRemoveWorkspace).toHaveBeenCalledWith("/tmp/project", "/tmp/wt/task-1");
  });
});
