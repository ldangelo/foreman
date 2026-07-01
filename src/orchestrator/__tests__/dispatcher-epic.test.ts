/**
 * dispatcher-epic.test.ts — Tests for TRD-006: epic bead dispatch logic.
 *
 * Verifies current native-task behavior:
 *  1. Epic tasks dispatch as single-agent tasks
 *  2. Task beads dispatch through standard path
 *  3. Empty epics still dispatch as ordinary tasks
 *  4. Epic counts as 1 agent slot
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import { Dispatcher } from "../dispatcher.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import type { ForemanStore } from "../../lib/store.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import type { EpicTask } from "../pipeline-executor.js";

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
    async createWorktree(opts: { projectId: string; beadId: string; repoPath: string; baseBranch?: string }) {
      return {
        projectId: opts.projectId,
        beadId: opts.beadId,
        branchName: `foreman/${opts.beadId}`,
        path: `/tmp/worktrees/${opts.projectId}/${opts.beadId}`,
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

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: class {
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

function nativeTaskFromIssue(issue: Issue) {
  return {
    id: issue.id, title: issue.title, description: issue.description ?? null, type: issue.type,
    priority: Number(String(issue.priority ?? "2").replace(/^P/, "")) || 2, status: "ready",
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
    getTaskById: vi.fn((id: string) => currentReadyIssues.map(nativeTaskFromIssue).find((task) => task.id === id) ?? null),
    claimTask: vi.fn().mockReturnValue(true),
    hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    createRun: vi.fn().mockReturnValue({ id: "run-1" }),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    sendMessage: vi.fn(),
    getPendingBeadWrites: vi.fn().mockReturnValue([]),
  } as unknown as ForemanStore;
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

describe("Dispatcher — Epic Bead Detection (TRD-006)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("epic task dispatches as a single-agent task without child expansion", async () => {
    const epicIssue = makeIssue("epic-1", "epic");
    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([epicIssue]),
      show: vi.fn().mockResolvedValue({
        ...epicIssue,
        children: ["child-1", "child-2", "child-3"],
      }),
    });
    const store = makeStore();
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project");

    // Spy on spawnAgent to capture the call args without actually spawning
    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    // Should have dispatched (not skipped)
    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].taskId).toBe("epic-1");
    expect(result.skipped).toHaveLength(0);

    // Native tasks do not expose child expansion to the worker.
    expect(spawnSpy).toHaveBeenCalledOnce();
    const callArgs = spawnSpy.mock.calls[0];
    const epicTasks = callArgs[10] as EpicTask[] | undefined;
    const epicId = callArgs[11] as string | undefined;

    expect(epicTasks).toBeUndefined();
    expect(epicId).toBeUndefined();
  });

  it("task bead dispatches via standard path without epicTasks", async () => {
    const taskIssue = makeIssue("task-1", "task");
    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([taskIssue]),
      show: vi.fn().mockResolvedValue({ ...taskIssue, description: "do the thing" }),
    });
    const store = makeStore();
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project");

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].taskId).toBe("task-1");

    // spawnAgent should have been called WITHOUT epicTasks
    expect(spawnSpy).toHaveBeenCalledOnce();
    const callArgs = spawnSpy.mock.calls[0];
    const epicTasks = callArgs[10] as EpicTask[] | undefined;
    const epicId = callArgs[11] as string | undefined;

    expect(epicTasks).toBeUndefined();
    expect(epicId).toBeUndefined();
  });

  it("epic task with 0 children still dispatches as a normal task", async () => {
    const epicIssue = makeIssue("epic-empty", "epic");
    const closeFn = vi.fn().mockResolvedValue(undefined);
    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([epicIssue]),
      show: vi.fn().mockResolvedValue({
        ...epicIssue,
        children: [],
      }),
      close: closeFn,
    });
    const store = makeStore();
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project");

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    expect(result.dispatched).toHaveLength(1);
    expect(result.skipped).toHaveLength(0);
    expect(closeFn).not.toHaveBeenCalled();
    expect(spawnSpy).toHaveBeenCalledOnce();
  });

  it("epic counts as 1 agent slot regardless of child task count", async () => {
    const epicIssue = makeIssue("epic-big", "epic");
    const taskIssue = makeIssue("task-1", "task");

    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([epicIssue, taskIssue]),
      show: vi.fn().mockImplementation(async (id: string) => {
        if (id === "epic-big") {
          return {
            ...epicIssue,
            children: ["child-1", "child-2", "child-3", "child-4", "child-5"],
          };
        }
        return { ...taskIssue, description: "a task" };
      }),
    });
    const store = makeStore();
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project");

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true, maxAgents: 2 });

    // Both should be dispatched — the epic counts as 1 slot, leaving room for the task
    expect(result.dispatched).toHaveLength(2);
    expect(result.dispatched.map(d => d.taskId)).toContain("epic-big");
    expect(result.dispatched.map(d => d.taskId)).toContain("task-1");

    // spawnAgent called twice
    expect(spawnSpy).toHaveBeenCalledTimes(2);

    // Native epic dispatch does not expand children into epicTasks.
    const epicCall = spawnSpy.mock.calls.find(c => (c[2] as { id: string }).id === "epic-big");
    expect(epicCall).toBeDefined();
    expect(epicCall![10]).toBeUndefined();

    const taskCall = spawnSpy.mock.calls.find(c => (c[2] as { id: string }).id === "task-1");
    expect(taskCall).toBeDefined();
    expect(taskCall![10]).toBeUndefined();
  });

  it("feature task with children dispatches under native task semantics", async () => {
    const featureIssue = makeIssue("feat-1", "feature");
    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([featureIssue]),
      show: vi.fn().mockResolvedValue({
        ...featureIssue,
        dependents: [{ id: "child-1", status: "open" }],
        status: "open",
      }),
    });
    const store = makeStore();
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project");

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    expect(result.dispatched).toHaveLength(1);
    expect(result.skipped).toHaveLength(0);
    expect(spawnSpy).toHaveBeenCalledOnce();
  });

  it("native feature task dispatches instead of being treated as a container", async () => {
    const featureIssue = {
      id: "feat-native",
      title: "feature feat-native",
      description: null,
      type: "feature",
      priority: 2,
      status: "ready",
      run_id: null,
      branch: null,
      external_id: "github:test/repo#1",
      labels: ["feature", "github:feature"],
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      approved_at: null,
      closed_at: null,
    };
    const tasksClient = makeTasksClient();
    const store = {
      ...makeStore(),
      hasNativeTasks: vi.fn().mockReturnValue(true),
      getReadyTasks: vi.fn().mockReturnValue([featureIssue]),
      claimTask: vi.fn().mockReturnValue(true),
    } as unknown as ForemanStore;
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project");

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].taskId).toBe("feat-native");
    expect(result.skipped).toHaveLength(0);
    expect(spawnSpy).toHaveBeenCalledOnce();
  });

  it("epic with no actionable child tasks still dispatches natively", async () => {
    const { getTaskOrder } = await import("../task-ordering.js");
    vi.mocked(getTaskOrder).mockResolvedValueOnce([]);

    const epicIssue = makeIssue("epic-containers", "epic");
    const closeFn = vi.fn().mockResolvedValue(undefined);
    const tasksClient = makeTasksClient({
      ready: vi.fn().mockResolvedValue([epicIssue]),
      show: vi.fn().mockResolvedValue({
        ...epicIssue,
        children: ["story-1", "story-2"],
      }),
      close: closeFn,
    });
    const store = makeStore();
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project");
    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    expect(result.dispatched).toHaveLength(1);
    expect(result.skipped).toHaveLength(0);
    expect(closeFn).not.toHaveBeenCalled();
    expect(spawnSpy).toHaveBeenCalledOnce();
  });
});
