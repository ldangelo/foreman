import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Workspace } from "../../lib/vcs/types.js";
import type { Run } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";

// ── Module mocks ──────────────────────────────────────────────────────────────

const { mockListWorkspaces, mockRemoveWorkspace, mockDeleteBranch, mockCreateVcsBackend } = vi.hoisted(() => {
  const mockListWorkspaces = vi.fn(async () => []);
  const mockRemoveWorkspace = vi.fn(async () => {});
  const mockDeleteBranch = vi.fn(async () => ({ deleted: true, wasFullyMerged: true }));
  const mockCreateVcsBackend = vi.fn().mockResolvedValue({
    name: "git",
    getRepoRoot: vi.fn(async () => "/tmp/project"),
    listWorkspaces: mockListWorkspaces,
    removeWorkspace: mockRemoveWorkspace,
    deleteBranch: mockDeleteBranch,
  });
  return { mockListWorkspaces, mockRemoveWorkspace, mockDeleteBranch, mockCreateVcsBackend };
});

vi.mock("../commands/project-task-support.js", () => ({
  resolveRepoRootProjectPath: vi.fn(),
  listRegisteredProjects: vi.fn(),
  ensureCliPostgresPool: vi.fn(),
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: mockCreateVcsBackend,
  },
}));

vi.mock("../../lib/store.js", () => {
  class MockForemanStore {
    static forProject = vi.fn(() => new MockForemanStore());
    getProjectByPath = vi.fn(() => ({ id: "proj-1", name: "test", path: "/tmp/project", status: "active", created_at: "", updated_at: "" }));
    getRunsForTask = vi.fn((): Run[] => []);
    getRunsByStatus = vi.fn((): Run[] => []);
    close = vi.fn();
  }
  return { ForemanStore: MockForemanStore };
});

vi.mock("../../lib/postgres-store.js", () => {
  class MockPostgresStore {
    static forProject = vi.fn(() => new MockPostgresStore());
    getRunsForTask = vi.fn(async () => []);
    close = vi.fn();
  }
  return { PostgresStore: MockPostgresStore };
});

import { ForemanStore } from "../../lib/store.js";
import {
  listForemanWorktrees,
  cleanWorktrees,
  worktreeListCommandAction,
  worktreeCleanCommandAction,
  type WorktreeInfo,
} from "../commands/worktree.js";
import * as projectTaskSupport from "../commands/project-task-support.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeWorktree(overrides: Partial<Workspace> = {}): Workspace {
  return {
    path: "/tmp/project/.foreman-worktrees/task-abc",
    branch: "foreman/task-abc",
    head: "abc123",
    bare: false,
    ...overrides,
  };
}

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    task_id: "task-abc",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: "/tmp/project/.foreman-worktrees/task-abc",
    status: "completed",
    started_at: new Date(Date.now() - 3600_000).toISOString(),
    completed_at: new Date().toISOString(),
    created_at: new Date(Date.now() - 7200_000).toISOString(),
    progress: null,    ...overrides,
  };
}

// ── listForemanWorktrees() tests ──────────────────────────────────────────────

describe("listForemanWorktrees()", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns only foreman/* worktrees", async () => {
    const worktrees: Workspace[] = [
      makeWorktree({ path: "/tmp/project", branch: "main" }),
      makeWorktree({ path: "/tmp/project/.foreman-worktrees/task-abc", branch: "foreman/task-abc" }),
      makeWorktree({ path: "/tmp/project/.foreman-worktrees/task-def", branch: "foreman/task-def" }),
    ];
    mockListWorkspaces.mockResolvedValue(worktrees as never);

    const store = new ForemanStore() as any;
    const result = await listForemanWorktrees("/tmp/project", store);

    expect(result).toHaveLength(2);
    expect(result[0].branch).toBe("foreman/task-abc");
    expect(result[1].branch).toBe("foreman/task-def");
  });

  it("includes run status and task ID in metadata", async () => {
    mockListWorkspaces.mockResolvedValue([
      makeWorktree({ branch: "foreman/task-abc" }),
    ] as never);
    const store = new ForemanStore() as any;
    const run = makeRun({ status: "running" });
    store.getRunsForTask.mockReturnValue([run]);

    const result = await listForemanWorktrees("/tmp/project", store);

    expect(result[0].taskId).toBe("task-abc");
    expect(result[0].runStatus).toBe("running");
  });

  it("returns empty array when no foreman worktrees exist", async () => {
    mockListWorkspaces.mockResolvedValue([
      makeWorktree({ path: "/tmp/project", branch: "main" }),
    ] as never);
    const store = new ForemanStore() as any;
    const result = await listForemanWorktrees("/tmp/project", store);
    expect(result).toHaveLength(0);
  });

  it("handles worktrees with no matching run", async () => {
    mockListWorkspaces.mockResolvedValue([
      makeWorktree({ branch: "foreman/orphan-task" }),
    ] as never);
    const store = new ForemanStore() as any;
    store.getRunsForTask.mockReturnValue([]);

    const result = await listForemanWorktrees("/tmp/project", store);

    expect(result[0].taskId).toBe("orphan-task");
    expect(result[0].runStatus).toBeNull();
  });
});

// ── cleanWorktrees() tests ────────────────────────────────────────────────────

describe("cleanWorktrees()", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("removes worktrees for completed/merged/failed runs only", async () => {
    const worktrees: WorktreeInfo[] = [
      {
        path: "/tmp/project/.foreman-worktrees/task-done",
        branch: "foreman/task-done",
        head: "abc",
        taskId: "task-done",
        runStatus: "merged",
        runId: "run-1",
        createdAt: new Date().toISOString(),
      },
      {
        path: "/tmp/project/.foreman-worktrees/task-active",
        branch: "foreman/task-active",
        head: "def",
        taskId: "task-active",
        runStatus: "running",
        runId: "run-2",
        createdAt: new Date().toISOString(),
      },
    ];

    const result = await cleanWorktrees("/tmp/project", worktrees, { all: false, force: false });

    expect(result.removed).toBe(1);
    expect(mockRemoveWorkspace).toHaveBeenCalledTimes(1);
    expect(mockRemoveWorkspace).toHaveBeenCalledWith("/tmp/project", "/tmp/project/.foreman-worktrees/task-done");
  });

  it("with --all removes active worktrees too", async () => {
    const worktrees: WorktreeInfo[] = [
      {
        path: "/tmp/project/.foreman-worktrees/task-done",
        branch: "foreman/task-done",
        head: "abc",
        taskId: "task-done",
        runStatus: "merged",
        runId: "run-1",
        createdAt: new Date().toISOString(),
      },
      {
        path: "/tmp/project/.foreman-worktrees/task-active",
        branch: "foreman/task-active",
        head: "def",
        taskId: "task-active",
        runStatus: "running",
        runId: "run-2",
        createdAt: new Date().toISOString(),
      },
    ];

    const result = await cleanWorktrees("/tmp/project", worktrees, { all: true, force: false });

    expect(result.removed).toBe(2);
    expect(mockRemoveWorkspace).toHaveBeenCalledTimes(2);
  });

  it("with --force uses force branch deletion", async () => {
    const worktrees: WorktreeInfo[] = [
      {
        path: "/tmp/project/.foreman-worktrees/task-done",
        branch: "foreman/task-done",
        head: "abc",
        taskId: "task-done",
        runStatus: "failed",
        runId: "run-1",
        createdAt: new Date().toISOString(),
      },
    ];

    await cleanWorktrees("/tmp/project", worktrees, { all: false, force: true });

    expect(mockDeleteBranch).toHaveBeenCalledWith(
      "/tmp/project",
      "foreman/task-done",
      expect.objectContaining({ force: true }),
    );
  });

  it("returns summary with count", async () => {
    const worktrees: WorktreeInfo[] = [
      {
        path: "/tmp/project/.foreman-worktrees/task-1",
        branch: "foreman/task-1",
        head: "a",
        taskId: "task-1",
        runStatus: "completed",
        runId: "r1",
        createdAt: new Date().toISOString(),
      },
      {
        path: "/tmp/project/.foreman-worktrees/task-2",
        branch: "foreman/task-2",
        head: "b",
        taskId: "task-2",
        runStatus: "merged",
        runId: "r2",
        createdAt: new Date().toISOString(),
      },
    ];

    const result = await cleanWorktrees("/tmp/project", worktrees, { all: false, force: false });

    expect(result.removed).toBe(2);
    expect(result.errors).toHaveLength(0);
  });

  it("continues on error and collects failures", async () => {
    mockRemoveWorkspace.mockRejectedValueOnce(new Error("locked"));

    const worktrees: WorktreeInfo[] = [
      {
        path: "/tmp/project/.foreman-worktrees/task-1",
        branch: "foreman/task-1",
        head: "a",
        taskId: "task-1",
        runStatus: "failed",
        runId: "r1",
        createdAt: new Date().toISOString(),
      },
    ];

    const result = await cleanWorktrees("/tmp/project", worktrees, { all: false, force: false });

    expect(result.removed).toBe(0);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toContain("locked");
  });

  it("with --dry-run skips actual removal but counts worktrees", async () => {
    const worktrees: WorktreeInfo[] = [
      {
        path: "/tmp/project/.foreman-worktrees/task-done",
        branch: "foreman/task-done",
        head: "abc",
        taskId: "task-done",
        runStatus: "merged",
        runId: "run-1",
        createdAt: new Date().toISOString(),
      },
      {
        path: "/tmp/project/.foreman-worktrees/task-active",
        branch: "foreman/task-active",
        head: "def",
        taskId: "task-active",
        runStatus: "running",
        runId: "run-2",
        createdAt: new Date().toISOString(),
      },
    ];

    const result = await cleanWorktrees("/tmp/project", worktrees, { all: false, force: false, dryRun: true });

    expect(result.removed).toBe(1);
    expect(result.errors).toHaveLength(0);
    expect(mockRemoveWorkspace).not.toHaveBeenCalled();
    expect(mockDeleteBranch).not.toHaveBeenCalled();
  });

  it("with --dry-run populates wouldRemove with the affected worktrees", async () => {
    const worktrees: WorktreeInfo[] = [
      {
        path: "/tmp/project/.foreman-worktrees/task-done",
        branch: "foreman/task-done",
        head: "abc",
        taskId: "task-done",
        runStatus: "merged",
        runId: "run-1",
        createdAt: new Date().toISOString(),
      },
      {
        path: "/tmp/project/.foreman-worktrees/task-active",
        branch: "foreman/task-active",
        head: "def",
        taskId: "task-active",
        runStatus: "running",
        runId: "run-2",
        createdAt: new Date().toISOString(),
      },
    ];

    const result = await cleanWorktrees("/tmp/project", worktrees, { all: false, force: false, dryRun: true });

    expect(result.wouldRemove).toHaveLength(1);
    expect(result.wouldRemove![0].taskId).toBe("task-done");
    expect(result.wouldRemove![0].path).toBe("/tmp/project/.foreman-worktrees/task-done");
  });

  it("with --dry-run and --all counts all worktrees without removing", async () => {
    const worktrees: WorktreeInfo[] = [
      {
        path: "/tmp/project/.foreman-worktrees/task-done",
        branch: "foreman/task-done",
        head: "abc",
        taskId: "task-done",
        runStatus: "merged",
        runId: "run-1",
        createdAt: new Date().toISOString(),
      },
      {
        path: "/tmp/project/.foreman-worktrees/task-active",
        branch: "foreman/task-active",
        head: "def",
        taskId: "task-active",
        runStatus: "running",
        runId: "run-2",
        createdAt: new Date().toISOString(),
      },
    ];

    const result = await cleanWorktrees("/tmp/project", worktrees, { all: true, force: false, dryRun: true });

    expect(result.removed).toBe(2);
    expect(result.errors).toHaveLength(0);
    expect(result.wouldRemove).toHaveLength(2);
    expect(mockRemoveWorkspace).not.toHaveBeenCalled();
    expect(mockDeleteBranch).not.toHaveBeenCalled();
  });

  it("with --dry-run and --all populates wouldRemove with all worktrees", async () => {
    const worktrees: WorktreeInfo[] = [
      {
        path: "/tmp/project/.foreman-worktrees/task-done",
        branch: "foreman/task-done",
        head: "abc",
        taskId: "task-done",
        runStatus: "merged",
        runId: "run-1",
        createdAt: new Date().toISOString(),
      },
      {
        path: "/tmp/project/.foreman-worktrees/task-active",
        branch: "foreman/task-active",
        head: "def",
        taskId: "task-active",
        runStatus: "running",
        runId: "run-2",
        createdAt: new Date().toISOString(),
      },
    ];

    const result = await cleanWorktrees("/tmp/project", worktrees, { all: true, force: false, dryRun: true });

    const taskIds = result.wouldRemove!.map((wt) => wt.taskId);
    expect(taskIds).toContain("task-done");
    expect(taskIds).toContain("task-active");
  });

  it("with --dry-run still respects filter criteria (skips active without --all)", async () => {
    const worktrees: WorktreeInfo[] = [
      {
        path: "/tmp/project/.foreman-worktrees/task-done",
        branch: "foreman/task-done",
        head: "abc",
        taskId: "task-done",
        runStatus: "completed",
        runId: "run-1",
        createdAt: new Date().toISOString(),
      },
      {
        path: "/tmp/project/.foreman-worktrees/task-pending",
        branch: "foreman/task-pending",
        head: "def",
        taskId: "task-pending",
        runStatus: "pending",
        runId: "run-2",
        createdAt: new Date().toISOString(),
      },
      {
        path: "/tmp/project/.foreman-worktrees/task-running",
        branch: "foreman/task-running",
        head: "ghi",
        taskId: "task-running",
        runStatus: "running",
        runId: "run-3",
        createdAt: new Date().toISOString(),
      },
    ];

    const result = await cleanWorktrees("/tmp/project", worktrees, { all: false, force: false, dryRun: true });

    // Only "completed" is cleanable without --all; "pending" and "running" are skipped
    expect(result.removed).toBe(1);
    expect(result.wouldRemove).toHaveLength(1);
    expect(result.wouldRemove![0].taskId).toBe("task-done");
    expect(mockRemoveWorkspace).not.toHaveBeenCalled();
    expect(mockDeleteBranch).not.toHaveBeenCalled();
  });

  it("without --dry-run does not populate wouldRemove", async () => {
    const worktrees: WorktreeInfo[] = [
      {
        path: "/tmp/project/.foreman-worktrees/task-done",
        branch: "foreman/task-done",
        head: "abc",
        taskId: "task-done",
        runStatus: "completed",
        runId: "run-1",
        createdAt: new Date().toISOString(),
      },
    ];

    const result = await cleanWorktrees("/tmp/project", worktrees, { all: false, force: false });

    expect(result.wouldRemove).toBeUndefined();
    expect(mockRemoveWorkspace).toHaveBeenCalledTimes(1);
  });
});

// ── worktree command targeting tests ──────────────────────────────────────────

describe("worktree command targeting", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  it("resolves registered worktree list to the canonical project path from a non-canonical cwd", async () => {
    const projectTaskSupportMock = vi.mocked(projectTaskSupport);
    const canonicalPath = "/canonical/project";
    const localStore = { close: vi.fn(), getRunsForTask: vi.fn().mockResolvedValue([]) } as unknown as ForemanStore;
    const postgresStore = { close: vi.fn(), getRunsForTask: vi.fn().mockResolvedValue([]) } as unknown as PostgresStore;
    const localStoreSpy = vi.spyOn(ForemanStore, "forProject").mockReturnValue(localStore);
    const postgresStoreSpy = vi.spyOn(PostgresStore, "forProject").mockReturnValue(postgresStore);

    try {
      projectTaskSupportMock.resolveRepoRootProjectPath.mockResolvedValue(canonicalPath);
      projectTaskSupportMock.listRegisteredProjects.mockResolvedValue([
        { id: "proj-1", name: "test-project", path: canonicalPath },
      ]);

      await worktreeListCommandAction({});

      expect(projectTaskSupportMock.resolveRepoRootProjectPath).toHaveBeenCalledWith({});
      expect(projectTaskSupportMock.ensureCliPostgresPool).toHaveBeenCalledWith(canonicalPath);
      expect(localStoreSpy).toHaveBeenCalledWith(canonicalPath);
      expect(postgresStoreSpy).toHaveBeenCalledWith("proj-1");
    } finally {
      localStoreSpy.mockRestore();
      postgresStoreSpy.mockRestore();
    }
  });

  it("resolves registered worktree clean to the canonical project path from a non-canonical cwd", async () => {
    const projectTaskSupportMock = vi.mocked(projectTaskSupport);
    const canonicalPath = "/canonical/project";
    const localStore = { close: vi.fn(), getRunsForTask: vi.fn().mockResolvedValue([]) } as unknown as ForemanStore;
    const postgresStore = { close: vi.fn(), getRunsForTask: vi.fn().mockResolvedValue([]) } as unknown as PostgresStore;
    const localStoreSpy = vi.spyOn(ForemanStore, "forProject").mockReturnValue(localStore);
    const postgresStoreSpy = vi.spyOn(PostgresStore, "forProject").mockReturnValue(postgresStore);

    try {
      projectTaskSupportMock.resolveRepoRootProjectPath.mockResolvedValue(canonicalPath);
      projectTaskSupportMock.listRegisteredProjects.mockResolvedValue([
        { id: "proj-1", name: "test-project", path: canonicalPath },
      ]);

      await worktreeCleanCommandAction({});

      expect(projectTaskSupportMock.resolveRepoRootProjectPath).toHaveBeenCalledWith({});
      expect(projectTaskSupportMock.ensureCliPostgresPool).toHaveBeenCalledWith(canonicalPath);
      expect(localStoreSpy).toHaveBeenCalledWith(canonicalPath);
      expect(postgresStoreSpy).toHaveBeenCalledWith("proj-1");
    } finally {
      localStoreSpy.mockRestore();
      postgresStoreSpy.mockRestore();
    }
  });

  it("keeps local unregistered worktree list behavior unchanged", async () => {
    const projectTaskSupportMock = vi.mocked(projectTaskSupport);
    const localStore = new ForemanStore();
    const localStoreSpy = vi.spyOn(ForemanStore, "forProject").mockReturnValue(localStore);
    const postgresStoreSpy = vi.spyOn(PostgresStore, "forProject");

    try {
      projectTaskSupportMock.resolveRepoRootProjectPath.mockResolvedValue("/tmp/project");
      projectTaskSupportMock.listRegisteredProjects.mockResolvedValue([]);

      await worktreeListCommandAction({});

      expect(projectTaskSupportMock.resolveRepoRootProjectPath).toHaveBeenCalledWith({});
      expect(projectTaskSupportMock.ensureCliPostgresPool).not.toHaveBeenCalled();
      expect(localStoreSpy).toHaveBeenCalledWith("/tmp/project");
      expect(postgresStoreSpy).not.toHaveBeenCalled();
    } finally {
      localStoreSpy.mockRestore();
      postgresStoreSpy.mockRestore();
    }
  });

  it("prints JSON for worktree list output", async () => {
    const projectTaskSupportMock = vi.mocked(projectTaskSupport);
    const localStore = new ForemanStore() as any;
    vi.spyOn(ForemanStore, "forProject").mockReturnValue(localStore);
    projectTaskSupportMock.resolveRepoRootProjectPath.mockResolvedValue("/tmp/project");
    projectTaskSupportMock.listRegisteredProjects.mockResolvedValue([]);
    mockListWorkspaces.mockResolvedValue([makeWorktree({ branch: "foreman/task-abc" })] as never);
    localStore.getRunsForTask.mockReturnValue([makeRun({ task_id: "task-abc" })]);

    await worktreeListCommandAction({ json: true });

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain('"taskId": "task-abc"');
  });

  it("prints friendly messages for empty list and empty clean results", async () => {
    const projectTaskSupportMock = vi.mocked(projectTaskSupport);
    const localStore = new ForemanStore() as any;
    vi.spyOn(ForemanStore, "forProject").mockReturnValue(localStore);
    projectTaskSupportMock.resolveRepoRootProjectPath.mockResolvedValue("/tmp/project");
    projectTaskSupportMock.listRegisteredProjects.mockResolvedValue([]);
    mockListWorkspaces.mockResolvedValue([] as never);

    await worktreeListCommandAction({});
    await worktreeCleanCommandAction({});

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("No foreman worktrees found.");
    expect(rendered).toContain("No foreman worktrees to clean.");
  });

  it("prints dry-run clean summaries including wouldRemove and errors", async () => {
    const projectTaskSupportMock = vi.mocked(projectTaskSupport);
    const localStore = new ForemanStore() as any;
    vi.spyOn(ForemanStore, "forProject").mockReturnValue(localStore);
    projectTaskSupportMock.resolveRepoRootProjectPath.mockResolvedValue("/tmp/project");
    projectTaskSupportMock.listRegisteredProjects.mockResolvedValue([]);
    mockListWorkspaces.mockResolvedValue([
      makeWorktree({ path: "/tmp/project/.foreman-worktrees/task-done", branch: "foreman/task-done" }),
    ] as never);
    localStore.getRunsForTask.mockReturnValue([makeRun({ task_id: "task-done", status: "completed", worktree_path: "/tmp/project/.foreman-worktrees/task-done" })]);

    await worktreeCleanCommandAction({ dryRun: true });

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("dry-run mode");
    expect(rendered).toContain("Worktrees that would be removed:");
    expect(rendered).toContain("Would remove 1 worktree(s).");
  });

  it("keeps outside-a-repo worktree clean behavior unchanged", async () => {
    const projectTaskSupportMock = vi.mocked(projectTaskSupport);
    const consoleErrSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const exitSpy = vi.spyOn(process, "exit").mockImplementation((() => undefined) as never);
    const localStoreSpy = vi.spyOn(ForemanStore, "forProject");
    const postgresStoreSpy = vi.spyOn(PostgresStore, "forProject");

    try {
      projectTaskSupportMock.resolveRepoRootProjectPath.mockRejectedValue(new Error("not a repo"));

      await worktreeCleanCommandAction({});

      expect(projectTaskSupportMock.resolveRepoRootProjectPath).toHaveBeenCalledWith({});
      expect(consoleErrSpy).toHaveBeenCalledWith(expect.stringContaining("Error: not a repo"));
      expect(exitSpy).toHaveBeenCalledWith(1);
      expect(localStoreSpy).not.toHaveBeenCalled();
      expect(postgresStoreSpy).not.toHaveBeenCalled();
    } finally {
      consoleErrSpy.mockRestore();
      exitSpy.mockRestore();
      localStoreSpy.mockRestore();
      postgresStoreSpy.mockRestore();
    }
  });
});
