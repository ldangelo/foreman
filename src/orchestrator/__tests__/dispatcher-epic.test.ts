/**
 * dispatcher-epic.test.ts — Tests for TRD-006 / PRD-2026-007: epic task dispatch logic.
 *
 * Verifies native-task epic behavior per PRD-2026-007 AC-001:
 *  1. Epic tasks with 3+ children spawn Epic Runner with epicTasks
 *  2. Epic tasks with 0 children auto-close and skip dispatch
 *  3. Epic tasks with < 3 children fall back to single-agent dispatch
 *  4. Task type still uses standard pipeline (no change)
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import { Dispatcher } from "../dispatcher.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import type { ForemanStore } from "../../lib/store.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import type { EpicTask } from "../pipeline-executor.js";
import type { DispatcherOverrides } from "../dispatcher.js";
import type { NativeTaskStatus } from "../types.js";
type NativeTaskOps = DispatcherOverrides["nativeTaskOps"] extends infer T ? NonNullable<T> : never;

// ── Module Mocks ─────────────────────────────────────────────────────────────

vi.mock("../../lib/vcs/index.js", async (importOriginal) => {
  const original = await importOriginal<typeof import("../../lib/vcs/index.js")>();
  return {
    ...original,
    VcsBackendFactory: {
      create: vi.fn().mockResolvedValue({
        name: "git",
        createWorkspace: vi.fn().mockResolvedValue({
          workspacePath: "/tmp/worktrees/test",
          branchName: "foreman/test",
        }),
      }),
      resolveBackend: vi.fn((config: { backend: "git" | "jujutsu" | "auto" }) =>
        config.backend === "auto" ? "git" : config.backend),
    },
  };
});

vi.mock("../../lib/vcs/git-backend.js", () => ({
  GitBackend: class {
    async getCurrentBranch(): Promise<string> { return "main"; }
    async detectDefaultBranch(): Promise<string> { return "main"; }
    async branchExists(): Promise<boolean> { return false; }
    async createWorkspace(_repoPath: string, taskId: string): Promise<{ workspacePath: string; branchName: string }> {
      return { workspacePath: `/tmp/worktrees/${taskId}`, branchName: `foreman/${taskId}` };
    }
  },
}));

vi.mock("../../lib/worktree-manager.js", () => ({
  WorktreeManager: class {
    async createWorktree(opts: { projectId: string; taskId: string; repoPath: string; baseBranch?: string }) {
      return {
        projectId: opts.projectId,
        taskId: opts.taskId,
        branchName: `foreman/${opts.taskId}`,
        path: `/tmp/worktrees/${opts.projectId}/${opts.taskId}`,
        exists: false,
      };
    }
  },
}));

vi.mock("../../lib/setup.js", () => ({
  installDependencies: vi.fn().mockResolvedValue(undefined),
  runSetupWithCache: vi.fn().mockResolvedValue(undefined),
  runWorkspaceHook: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("../../lib/workflow-loader.js", () => ({
  loadWorkflowConfig: vi.fn().mockReturnValue({
    name: "default",
    phases: [],
  }),
  resolveWorkflowName: vi.fn((type: string) => {
    if (type === "epic") return "epic";
    return "default";
  }),
}));

vi.mock("../../lib/workflow-config-loader.js", () => ({
  resolveWorkflowType: vi.fn((type: string) => type),
}));

vi.mock("../../lib/project-config.js", () => ({
  loadProjectConfig: vi.fn().mockReturnValue(null),
  resolveVcsConfig: vi.fn().mockReturnValue({ backend: "git" }),
}));

vi.mock("../templates.js", () => ({
  workerAgentMd: vi.fn().mockReturnValue("# TASK.md content"),
}));

vi.mock("../pi-rpc-spawn-strategy.js", () => ({
  isPiAvailable: vi.fn().mockResolvedValue(true),
}));

vi.mock("../../lib/task-client.js", () => ({
  TaskClient: class {
    async show(_id: string): Promise<never> { throw new Error("not found"); }
  },
}));

// Mock task-ordering — returns 3 ordered tasks by default
vi.mock("../task-ordering.js", () => ({
  getTaskOrder: vi.fn().mockResolvedValue([
    { taskId: "child-1", taskTitle: "Child Task 1" },
    { taskId: "child-2", taskTitle: "Child Task 2" },
    { taskId: "child-3", taskTitle: "Child Task 3" },
  ] as EpicTask[]),
}));

// Mock fs/promises to prevent actual file system writes
vi.mock("node:fs/promises", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...original,
    writeFile: vi.fn().mockResolvedValue(undefined),
    mkdir: vi.fn().mockResolvedValue(undefined),
    open: vi.fn().mockResolvedValue({ fd: 1, close: vi.fn().mockResolvedValue(undefined) }),
    readdir: vi.fn().mockResolvedValue([]),
    unlink: vi.fn().mockResolvedValue(undefined),
  };
});

// ── Helpers ──────────────────────────────────────────────────────────────────

function makeIssue(id: string, type: string, priority = "P2"): Issue {
  return {
    id,
    title: `${type} ${id}`,
    status: "open",
    priority,
    type,
    assignee: null,
    parent: null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };
}


let currentReadyIssues: Issue[] = [];
let childTasksByParent: Record<string, string[]> = {};
let childTaskDetails: Record<string, ReturnType<typeof nativeTaskFromIssue>> = {};

function nativeTaskFromIssue(issue: Issue) {
  return {
    id: issue.id, title: issue.title, description: issue.description ?? null, type: issue.type,
    priority: Number(String(issue.priority ?? "2").replace(/^P/, "")) || 2, status: "ready" as NativeTaskStatus,
    run_id: null, branch: null, external_id: null, labels: issue.labels ?? [], parent: issue.parent ?? null,
    created_at: issue.created_at, updated_at: issue.updated_at, approved_at: new Date().toISOString(), closed_at: null,
  };
}

function makeStore(): ForemanStore {
  return {
    getActiveRuns: vi.fn().mockReturnValue([]),
    getRunsByStatus: vi.fn().mockReturnValue([]),
    getRunsByStatuses: vi.fn().mockReturnValue([]),
    getRunsByStatusesSince: vi.fn().mockReturnValue([]),
    getRunsForTask: vi.fn().mockReturnValue([]),
    getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    hasNativeTasks: vi.fn().mockReturnValue(true),
    getReadyTasks: vi.fn(() => currentReadyIssues.map(nativeTaskFromIssue)),
    getTaskByExternalId: vi.fn().mockReturnValue(null),
    getTaskById: vi.fn((id: string) => {
      // Check child tasks first
      const childDetail = childTaskDetails[id];
      if (childDetail) return childDetail;
      return currentReadyIssues.map(nativeTaskFromIssue).find((task) => task.id === id) ?? null;
    }),
    claimTask: vi.fn().mockReturnValue(true),
    hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    createRun: vi.fn().mockReturnValue({ id: "run-1" }),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    sendMessage: vi.fn(),
    getPendingTaskWrites: vi.fn().mockReturnValue([]),
  } as unknown as ForemanStore;
}

function makeNativeTaskOps(): NativeTaskOps {
  return {
    hasNativeTasks: vi.fn().mockResolvedValue(true),
    getReadyTasks: vi.fn().mockResolvedValue(currentReadyIssues.map(nativeTaskFromIssue)),
    getTaskByExternalId: vi.fn().mockResolvedValue(null),
    getTaskById: vi.fn((id: string) => {
      const childDetail = childTaskDetails[id];
      if (childDetail) return Promise.resolve(childDetail);
      const task = currentReadyIssues.map(nativeTaskFromIssue).find((t) => t.id === id);
      return Promise.resolve(task ?? null);
    }),
    claimTask: vi.fn().mockResolvedValue(true),
    updateTaskStatus: vi.fn().mockResolvedValue(undefined),
    getChildren: vi.fn((parentId: string) => {
      const children = childTasksByParent[parentId] ?? [];
      return Promise.resolve(children);
    }),
  };
}

function makeTasksClient(overrides: Partial<ITaskClient> = {}): ITaskClient {
  const ready = overrides.ready as unknown as { getMockImplementation?: () => (() => Promise<Issue[]>) | undefined } | undefined;
  const impl = ready?.getMockImplementation?.();
  if (impl) {
    void impl().then((issues) => { currentReadyIssues = issues; });
  }
  return {
    ready: vi.fn().mockResolvedValue([]),
    show: vi.fn().mockResolvedValue({ status: "open" }),
    update: vi.fn().mockResolvedValue(undefined),
    close: vi.fn().mockResolvedValue(undefined),
    list: vi.fn().mockResolvedValue([]),
    ...overrides,
  };
}

// ── Tests ────────────────────────────────────────────────────────────────────

describe("Dispatcher — Epic Task Detection (TRD-006 / PRD-2026-007)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // Reset test data
    currentReadyIssues = [];
    childTasksByParent = {};
    childTaskDetails = {};
  });

  // Helper to set up ready issues that will be returned by both store and nativeOps
  function setupReadyIssues(issues: Issue[]): void {
    currentReadyIssues = issues;
  }

  // Helper to set up epic with children
  function setupEpicWithChildren(epicId: string, childIds: string[]): void {
    childTasksByParent[epicId] = childIds;
    for (const childId of childIds) {
      childTaskDetails[childId] = {
        id: childId,
        title: `Child Task ${childId}`,
        description: `Description for ${childId}`,
        type: "task",
        priority: 2,
        status: "ready" as NativeTaskStatus,
        run_id: null,
        branch: null,
        external_id: null,
        labels: [],
        parent: epicId,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: new Date().toISOString(),
        closed_at: null,
      };
    }
  }

  // ── PRD-2026-007 AC-001-1: Epic with 3+ children spawns Epic Runner ────────

  it("AC-001-1: epic with 3+ children spawns Epic Runner with epicTasks", async () => {
    const epicIssue = makeIssue("epic-3plus", "epic");
    setupReadyIssues([epicIssue]);
    setupEpicWithChildren("epic-3plus", ["child-1", "child-2", "child-3"]);

    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([epicIssue]),
    });
    const store = makeStore();
    const nativeOps = makeNativeTaskOps();
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project", undefined, { nativeTaskOps: nativeOps });

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].taskId).toBe("epic-3plus");
    expect(result.skipped).toHaveLength(0);

    expect(spawnSpy).toHaveBeenCalledOnce();
    const callArgs = spawnSpy.mock.calls[0];
    const epicTasks = callArgs[10] as EpicTask[];
    const epicId = callArgs[11] as string | undefined;

    // Epic with 3+ children should pass epicTasks to spawnAgent
    expect(epicTasks).toBeDefined();
    expect(epicTasks.length).toBe(3);
    expect(epicTasks[0].taskId).toBe("child-1");
    expect(epicTasks[1].taskId).toBe("child-2");
    expect(epicTasks[2].taskId).toBe("child-3");
    expect(epicId).toBe("epic-3plus");
  });

  it("AC-001-1: epic with 5 children spawns Epic Runner with all 5 epicTasks", async () => {
    const epicIssue = makeIssue("epic-big", "epic");
    setupReadyIssues([epicIssue]);
    setupEpicWithChildren("epic-big", ["child-1", "child-2", "child-3", "child-4", "child-5"]);

    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([epicIssue]),
    });
    const store = makeStore();
    const nativeOps = makeNativeTaskOps();
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project", undefined, { nativeTaskOps: nativeOps });

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    expect(result.dispatched).toHaveLength(1);
    expect(spawnSpy).toHaveBeenCalledOnce();

    const callArgs = spawnSpy.mock.calls[0];
    const epicTasks = callArgs[10] as EpicTask[];
    expect(epicTasks).toBeDefined();
    expect(epicTasks.length).toBe(5);
  });

  // ── PRD-2026-007 AC-001-3: Epic with 0 children auto-closes ───────────────

  it("AC-001-3: epic with 0 children auto-closes and is skipped", async () => {
    const epicIssue = makeIssue("epic-empty", "epic");
    setupReadyIssues([epicIssue]);
    // No children set up

    const updateStatusFn = vi.fn();
    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([epicIssue]),
    });
    const store = makeStore();
    const nativeOps = makeNativeTaskOps();
    (nativeOps as { updateTaskStatus?: typeof updateStatusFn }).updateTaskStatus = updateStatusFn;
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project", undefined, { nativeTaskOps: nativeOps });

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    // Should be skipped, not dispatched
    expect(result.dispatched).toHaveLength(0);
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0].taskId).toBe("epic-empty");
    expect(result.skipped[0].reason).toBe("Epic has no child tasks");

    // Should have called updateNativeTaskStatus to close the epic
    expect(updateStatusFn).toHaveBeenCalledWith("epic-empty", "closed");

    // Should NOT have spawned an agent
    expect(spawnSpy).not.toHaveBeenCalled();
  });

  // ── PRD-2026-007 AC-001-2: Task type uses standard pipeline ────────────────

  it("AC-001-2: task type dispatches via standard path without epicTasks", async () => {
    const taskIssue = makeIssue("task-1", "task");
    setupReadyIssues([taskIssue]);
    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([taskIssue]),
    });
    const store = makeStore();
    const nativeOps = makeNativeTaskOps();
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project", undefined, { nativeTaskOps: nativeOps });

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].taskId).toBe("task-1");

    expect(spawnSpy).toHaveBeenCalledOnce();
    const callArgs = spawnSpy.mock.calls[0];
    const epicTasks = callArgs[10] as EpicTask[] | undefined;

    // Task should NOT have epicTasks
    expect(epicTasks).toBeUndefined();
  });

  it("AC-001-2: bug type dispatches via standard path without epicTasks", async () => {
    const bugIssue = makeIssue("bug-1", "bug");
    setupReadyIssues([bugIssue]);
    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([bugIssue]),
    });
    const store = makeStore();
    const nativeOps = makeNativeTaskOps();
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project", undefined, { nativeTaskOps: nativeOps });

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    expect(result.dispatched).toHaveLength(1);
    expect(spawnSpy).toHaveBeenCalledOnce();

    const callArgs = spawnSpy.mock.calls[0];
    const epicTasks = callArgs[10] as EpicTask[] | undefined;
    expect(epicTasks).toBeUndefined();
  });

  // ── Fallback behavior: epic with < 3 children ───────────────────────────────

  it("epic with 2 children falls back to single-agent dispatch", async () => {
    const epicIssue = makeIssue("epic-2", "epic");
    setupReadyIssues([epicIssue]);
    setupEpicWithChildren("epic-2", ["child-1", "child-2"]);

    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([epicIssue]),
    });
    const store = makeStore();
    const nativeOps = makeNativeTaskOps();
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project", undefined, { nativeTaskOps: nativeOps });

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    expect(result.dispatched).toHaveLength(1);
    expect(result.skipped).toHaveLength(0);

    expect(spawnSpy).toHaveBeenCalledOnce();
    const callArgs = spawnSpy.mock.calls[0];
    const epicTasks = callArgs[10] as EpicTask[] | undefined;

    // Epic with < 3 children should NOT have epicTasks (single-agent fallback)
    expect(epicTasks).toBeUndefined();
  });

  it("epic with 1 child falls back to single-agent dispatch", async () => {
    const epicIssue = makeIssue("epic-1child", "epic");
    setupReadyIssues([epicIssue]);
    setupEpicWithChildren("epic-1child", ["child-1"]);

    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([epicIssue]),
    });
    const store = makeStore();
    const nativeOps = makeNativeTaskOps();
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project", undefined, { nativeTaskOps: nativeOps });

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    expect(result.dispatched).toHaveLength(1);

    expect(spawnSpy).toHaveBeenCalledOnce();
    const callArgs = spawnSpy.mock.calls[0];
    const epicTasks = callArgs[10] as EpicTask[] | undefined;
    expect(epicTasks).toBeUndefined();
  });

  // ── Epic counts as 1 agent slot ────────────────────────────────────────────

  it("epic counts as 1 agent slot when spawning Epic Runner", async () => {
    const epicIssue = makeIssue("epic-3plus", "epic");
    const taskIssue = makeIssue("task-1", "task");
    setupReadyIssues([epicIssue, taskIssue]);
    setupEpicWithChildren("epic-3plus", ["child-1", "child-2", "child-3"]);

    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([epicIssue, taskIssue]),
    });
    const store = makeStore();
    const nativeOps = makeNativeTaskOps();
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project", undefined, { nativeTaskOps: nativeOps });

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    // With maxAgents: 2, epic + task should both dispatch (epic counts as 1 slot)
    const result = await dispatcher.dispatch({ pipeline: true, maxAgents: 2 });

    expect(result.dispatched).toHaveLength(2);
    expect(result.dispatched.map(d => d.taskId)).toContain("epic-3plus");
    expect(result.dispatched.map(d => d.taskId)).toContain("task-1");

    expect(spawnSpy).toHaveBeenCalledTimes(2);

    // Epic should have epicTasks
    const epicCall = spawnSpy.mock.calls.find(c => (c[2] as { id: string }).id === "epic-3plus");
    expect(epicCall).toBeDefined();
    expect(epicCall![10]).toBeDefined(); // epicTasks
  });

  // ── Error handling: child task fetch fails ─────────────────────────────────

  it("epic falls back to single-agent when child task fetch partially fails", async () => {
    const epicIssue = makeIssue("epic-partial", "epic");
    setupReadyIssues([epicIssue]);
    setupEpicWithChildren("epic-partial", ["child-1", "child-2", "child-3"]);

    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([epicIssue]),
    });
    const store = makeStore();
    const nativeOps = makeNativeTaskOps();
    // Make child-2 fetch return null (simulates missing child)
    (nativeOps.getTaskById as ReturnType<typeof vi.fn>).mockImplementation((id: string) => {
      if (id === "child-2") return Promise.resolve(null);
      const childDetail = childTaskDetails[id];
      return Promise.resolve(childDetail ?? null);
    });
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project", undefined, { nativeTaskOps: nativeOps });

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    expect(result.dispatched).toHaveLength(1);

    // With only 2 actionable children (< 3), should fall back to single-agent
    expect(spawnSpy).toHaveBeenCalledOnce();
    const callArgs = spawnSpy.mock.calls[0];
    const epicTasks = callArgs[10] as EpicTask[] | undefined;
    expect(epicTasks).toBeUndefined();
  });

  // ── Store fallback: Dispatcher without nativeTaskOps override ──────────────────

  it("uses store.getChildren fallback when no nativeTaskOps override is provided", async () => {
    const epicIssue = makeIssue("epic-store-fallback", "epic");
    setupReadyIssues([epicIssue]);
    setupEpicWithChildren("epic-store-fallback", ["child-1", "child-2", "child-3"]);

    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([epicIssue]),
    });

    // Create store with getChildren method as the fallback
    const store = makeStore();
    (store as { getChildren?: (parentId: string) => Promise<string[]> }).getChildren = vi.fn().mockImplementation(
      (parentId: string) => {
        const children = childTasksByParent[parentId] ?? [];
        return Promise.resolve(children);
      },
    );

    // Create dispatcher WITHOUT nativeTaskOps override
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project");

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    // Should have dispatched the epic
    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].taskId).toBe("epic-store-fallback");

    expect(spawnSpy).toHaveBeenCalledOnce();
    const callArgs = spawnSpy.mock.calls[0];
    const epicTasks = callArgs[10] as EpicTask[];
    const epicId = callArgs[11] as string | undefined;

    // Epic should have children from store fallback
    expect(epicTasks).toBeDefined();
    expect(epicTasks.length).toBe(3);
    expect(epicId).toBe("epic-store-fallback");

    // Verify store.getChildren was called
    expect((store as { getChildren?: (parentId: string) => Promise<string[]> }).getChildren).toHaveBeenCalledWith("epic-store-fallback");
  });

  it("epic with 0 children auto-closes via store fallback path", async () => {
    const epicIssue = makeIssue("epic-empty-fallback", "epic");
    setupReadyIssues([epicIssue]);
    // No children set up

    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([epicIssue]),
    });

    const updateStatusFn = vi.fn();
    const store = makeStore();
    (store as unknown as { getChildren?: (parentId: string) => Promise<string[]> }).getChildren = vi.fn().mockResolvedValue([]);
    (store as unknown as { updateTaskStatus?: (taskId: string, status: string) => Promise<void> }).updateTaskStatus = updateStatusFn;

    // Create dispatcher WITHOUT nativeTaskOps override
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project");

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    // Should be skipped, not dispatched
    expect(result.dispatched).toHaveLength(0);
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0].taskId).toBe("epic-empty-fallback");
    expect(result.skipped[0].reason).toBe("Epic has no child tasks");

    // Should have called updateTaskStatus to close the epic
    expect(updateStatusFn).toHaveBeenCalledWith("epic-empty-fallback", "closed");

    // Should NOT have spawned an agent
    expect(spawnSpy).not.toHaveBeenCalled();
  });

  it("excludes epic child tasks from standalone dispatch to prevent duplicate processing", async () => {
    // Set up an epic with children that are also in the ready list
    const epicIssue = makeIssue("epic-dedup", "epic");
    const childIssue = makeIssue("child-1", "task"); // This child is also a ready task
    setupReadyIssues([epicIssue, childIssue]);
    setupEpicWithChildren("epic-dedup", ["child-1", "child-2", "child-3"]);

    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([epicIssue, childIssue]),
    });

    const store = makeStore();
    (store as { getChildren?: (parentId: string) => Promise<string[]> }).getChildren = vi.fn().mockImplementation(
      (parentId: string) => {
        const children = childTasksByParent[parentId] ?? [];
        return Promise.resolve(children);
      },
    );

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project");

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    // Should have dispatched only the epic (not child-1 separately)
    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].taskId).toBe("epic-dedup");

    // Epic should have all 3 children
    expect(spawnSpy).toHaveBeenCalledOnce();
    const callArgs = spawnSpy.mock.calls[0];
    const epicTasks = callArgs[10] as EpicTask[];
    expect(epicTasks).toBeDefined();
    expect(epicTasks.length).toBe(3);
  });
});
