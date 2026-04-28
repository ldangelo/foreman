import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

type BackendType = "native" | "beads";

const {
  backendState,
  mockCreateTaskClient,
  mockResolveRepoRootProjectPath,
  mockRequireProjectOrAllInMultiMode,
  mockListRegisteredProjects,
  mockArchiveWorktreeReports,
  mockDeleteWorkerConfigFile,
  mockForemanStoreForProject,
  mockVcsCreate,
  mockMergeQueueCtor,
  nativeTaskClient,
  beadsTaskClient,
  localStore,
  mergeQueue,
  vcsBackend,
} = vi.hoisted(() => {
  const backendState = { current: "native" as BackendType };

  const nativeTaskClient = {
    list: vi.fn(async () => []),
    ready: vi.fn(async () => []),
    show: vi.fn(async (id: string) => {
      if (id === "task-actual") return { status: "in-progress" };
      if (id === "task-trap") return { status: "completed" };
      return { status: "open" };
    }),
    update: vi.fn(async () => {}),
    close: vi.fn(async () => {}),
    resetToReady: vi.fn(async () => {}),
  };

  const beadsTaskClient = {
    list: vi.fn(async () => []),
    ready: vi.fn(async () => []),
    show: vi.fn(async (id: string) => {
      if (id === "bd-actual") return { status: "in_progress" };
      if (id === "bd-trap") return { status: "completed" };
      return { status: "open" };
    }),
    update: vi.fn(async () => {}),
    close: vi.fn(async () => {}),
  };

  const localStore = {
    getProjectByPath: vi.fn(() => ({ id: "proj-native", path: "/mock/project" })),
    getDb: vi.fn(() => ({})),
    close: vi.fn(),
    getRunsByStatus: vi.fn(async (status: string) => {
      if (backendState.current === "native") {
        if (status === "failed") {
          return [
            {
              id: "run-actual",
              project_id: "proj-native",
              seed_id: "task-actual",
              agent_type: "claude-sonnet-4-6",
              session_key: null,
              worktree_path: null,
              status: "failed",
              started_at: new Date().toISOString(),
              completed_at: new Date().toISOString(),
              created_at: new Date().toISOString(),
              progress: null,
            },
          ];
        }

        if (status === "completed") {
          return [
            {
              id: "run-trap",
              project_id: "proj-native",
              seed_id: "task-trap",
              agent_type: "claude-sonnet-4-6",
              session_key: null,
              worktree_path: null,
              status: "completed",
              started_at: new Date().toISOString(),
              completed_at: new Date().toISOString(),
              created_at: new Date().toISOString(),
              progress: null,
            },
          ];
        }
      }

      if (backendState.current === "beads") {
        if (status === "failed") {
          return [
            {
              id: "run-actual",
              project_id: "proj-native",
              seed_id: "bd-actual",
              agent_type: "claude-sonnet-4-6",
              session_key: null,
              worktree_path: null,
              status: "failed",
              started_at: new Date().toISOString(),
              completed_at: new Date().toISOString(),
              created_at: new Date().toISOString(),
              progress: null,
            },
          ];
        }

        if (status === "completed") {
          return [
            {
              id: "run-trap",
              project_id: "proj-native",
              seed_id: "bd-trap",
              agent_type: "claude-sonnet-4-6",
              session_key: null,
              worktree_path: null,
              status: "completed",
              started_at: new Date().toISOString(),
              completed_at: new Date().toISOString(),
              created_at: new Date().toISOString(),
              progress: null,
            },
          ];
        }
      }

      return [];
    }),
    getActiveRuns: vi.fn(async () => []),
    getRunsForSeed: vi.fn(async () => []),
    updateRun: vi.fn(async () => {}),
    logEvent: vi.fn(async () => {}),
  };

  const mergeQueue = {
    list: vi.fn(async () => []),
    remove: vi.fn(async () => {}),
    missingFromQueue: vi.fn(async () => []),
  };

  const vcsBackend = {
    getCurrentBranch: vi.fn(async () => "main"),
    detectDefaultBranch: vi.fn(async () => "main"),
    removeWorkspace: vi.fn(async () => {}),
    deleteBranch: vi.fn(async () => ({ deleted: true })),
    checkoutBranch: vi.fn(async () => {}),
  };

  const mockMergeQueueCtor = vi.fn(function MockMergeQueueImpl() {
    return mergeQueue;
  });

  const taskClients = {
    native: nativeTaskClient,
    beads: beadsTaskClient,
  };

  return {
    backendState,
    mockCreateTaskClient: vi.fn(async () => ({
      taskClient: taskClients[backendState.current],
      backendType: backendState.current,
    })),
    mockResolveRepoRootProjectPath: vi.fn(async () => "/mock/project"),
    mockRequireProjectOrAllInMultiMode: vi.fn(async () => {}),
    mockListRegisteredProjects: vi.fn(async () => []),
    mockArchiveWorktreeReports: vi.fn(async () => {}),
    mockDeleteWorkerConfigFile: vi.fn(async () => {}),
    mockForemanStoreForProject: vi.fn(() => localStore),
    mockVcsCreate: vi.fn(async () => vcsBackend),
    mockMergeQueueCtor,
    nativeTaskClient,
    beadsTaskClient,
    localStore,
    mergeQueue,
    vcsBackend,
  };
});

vi.mock("../../lib/task-client-factory.js", () => ({
  createTaskClient: mockCreateTaskClient,
}));

vi.mock("../commands/project-task-support.js", () => ({
  resolveRepoRootProjectPath: mockResolveRepoRootProjectPath,
  requireProjectOrAllInMultiMode: mockRequireProjectOrAllInMultiMode,
  listRegisteredProjects: mockListRegisteredProjects,
  ensureCliPostgresPool: vi.fn(),
}));

vi.mock("../../lib/archive-reports.js", () => ({
  archiveWorktreeReports: mockArchiveWorktreeReports,
}));

vi.mock("../../orchestrator/dispatcher.js", () => ({
  deleteWorkerConfigFile: mockDeleteWorkerConfigFile,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: { forProject: mockForemanStoreForProject },
}));

vi.mock("../../lib/postgres-store.js", () => ({
  PostgresStore: { forProject: vi.fn() },
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: { create: mockVcsCreate },
}));

vi.mock("../../orchestrator/merge-queue.js", () => ({
  MergeQueue: mockMergeQueueCtor,
}));

vi.mock("../../orchestrator/postgres-merge-queue.js", () => ({
  PostgresMergeQueue: vi.fn(),
}));

import { resetCommand } from "../commands/reset.js";

async function runReset(args: string[]): Promise<void> {
  await resetCommand.parseAsync(["node", "foreman", ...args]);
}

describe("foreman reset — native backend", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    backendState.current = "native";
    mockResolveRepoRootProjectPath.mockResolvedValue("/mock/project");
    mockCreateTaskClient.mockResolvedValue({ taskClient: nativeTaskClient, backendType: "native" });
    mockListRegisteredProjects.mockResolvedValue([]);
    localStore.getProjectByPath.mockReturnValue({ id: "proj-native", path: "/mock/project" });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("skips bead-only repair passes and still resets retryable tasks to ready", async () => {
    await runReset(["--project-path", "/mock/project"]);

    expect(mockCreateTaskClient).toHaveBeenCalledWith("/mock/project", {
      registeredProjectId: undefined,
    });
    expect(nativeTaskClient.resetToReady).toHaveBeenCalledWith("task-actual");
    expect(nativeTaskClient.update).not.toHaveBeenCalled();
    expect(nativeTaskClient.show).toHaveBeenCalledWith("task-actual");
    expect(nativeTaskClient.show).not.toHaveBeenCalledWith("task-trap");
    expect(mergeQueue.list).toHaveBeenCalled();
  });

  it("still keeps bead repair passes active for beads", async () => {
    backendState.current = "beads";
    mockCreateTaskClient.mockResolvedValue({ taskClient: beadsTaskClient, backendType: "beads" });

    await runReset(["--project-path", "/mock/project"]);

    expect(beadsTaskClient.update).toHaveBeenCalledWith("bd-actual", { status: "open" });
    expect(beadsTaskClient.resetToReady).toBeUndefined();
    expect(beadsTaskClient.show).toHaveBeenCalledWith("bd-trap");
    expect(beadsTaskClient.show).toHaveBeenCalledWith("bd-actual");
  });
});
