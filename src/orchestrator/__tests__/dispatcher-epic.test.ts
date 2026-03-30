/**
 * dispatcher-epic.test.ts — Tests for TRD-006: epic bead dispatch logic.
 *
 * Verifies:
 *  1. Epic bead with children dispatches through epic path (epicTasks populated)
 *  2. Task bead dispatches through standard path (no epicTasks)
 *  3. Epic bead with 0 children auto-closes
 *  4. Epic counts as 1 agent slot regardless of child task count
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
    },
  };
});

vi.mock("../../lib/vcs/git-backend.js", () => ({
  GitBackend: class {
    async getCurrentBranch(): Promise<string> { return "main"; }
    async detectDefaultBranch(): Promise<string> { return "main"; }
    async branchExists(): Promise<boolean> { return false; }
    async createWorkspace(_repoPath: string, seedId: string): Promise<{ workspacePath: string; branchName: string }> {
      return { workspacePath: `/tmp/worktrees/${seedId}`, branchName: `foreman/${seedId}` };
    }
  },
}));

vi.mock("../../lib/git.js", () => ({
  installDependencies: vi.fn().mockResolvedValue(undefined),
  runSetupWithCache: vi.fn().mockResolvedValue(undefined),
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
    { seedId: "child-1", seedTitle: "Child Task 1" },
    { seedId: "child-2", seedTitle: "Child Task 2" },
    { seedId: "child-3", seedTitle: "Child Task 3" },
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

function makeStore(): ForemanStore {
  return {
    getActiveRuns: vi.fn().mockReturnValue([]),
    getRunsByStatus: vi.fn().mockReturnValue([]),
    getRunsByStatuses: vi.fn().mockReturnValue([]),
    getRunsByStatusesSince: vi.fn().mockReturnValue([]),
    getRunsForSeed: vi.fn().mockReturnValue([]),
    getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    hasNativeTasks: vi.fn().mockReturnValue(false),
    getReadyTasks: vi.fn().mockReturnValue([]),
    hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    createRun: vi.fn().mockReturnValue({ id: "run-1" }),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    sendMessage: vi.fn(),
    getPendingBeadWrites: vi.fn().mockReturnValue([]),
  } as unknown as ForemanStore;
}

function makeSeedsClient(overrides: Partial<ITaskClient> = {}): ITaskClient {
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

  it("epic bead with children dispatches via epic path with epicTasks populated", async () => {
    const epicIssue = makeIssue("epic-1", "epic");
    const seedsClient = makeSeedsClient({
      ready: vi.fn().mockResolvedValue([epicIssue]),
      show: vi.fn().mockResolvedValue({
        ...epicIssue,
        children: ["child-1", "child-2", "child-3"],
      }),
    });
    const store = makeStore();
    const dispatcher = new Dispatcher(seedsClient, store, "/tmp/project");

    // Spy on spawnAgent to capture the call args without actually spawning
    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    // Should have dispatched (not skipped)
    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].seedId).toBe("epic-1");
    expect(result.skipped).toHaveLength(0);

    // spawnAgent should have been called with epicTasks and epicId
    expect(spawnSpy).toHaveBeenCalledOnce();
    const callArgs = spawnSpy.mock.calls[0];
    // Args: model, worktreePath, seedInfo, runId, telemetry, pipelineOpts, notifyUrl, vcsBackend, targetBranch, epicTasks, epicId
    const epicTasks = callArgs[9] as EpicTask[];
    const epicId = callArgs[10] as string;

    expect(epicTasks).toBeDefined();
    expect(epicTasks).toHaveLength(3);
    expect(epicTasks[0].seedId).toBe("child-1");
    expect(epicTasks[1].seedId).toBe("child-2");
    expect(epicTasks[2].seedId).toBe("child-3");
    expect(epicId).toBe("epic-1");
  });

  it("task bead dispatches via standard path without epicTasks", async () => {
    const taskIssue = makeIssue("task-1", "task");
    const seedsClient = makeSeedsClient({
      ready: vi.fn().mockResolvedValue([taskIssue]),
      show: vi.fn().mockResolvedValue({ ...taskIssue, description: "do the thing" }),
    });
    const store = makeStore();
    const dispatcher = new Dispatcher(seedsClient, store, "/tmp/project");

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].seedId).toBe("task-1");

    // spawnAgent should have been called WITHOUT epicTasks
    expect(spawnSpy).toHaveBeenCalledOnce();
    const callArgs = spawnSpy.mock.calls[0];
    const epicTasks = callArgs[9] as EpicTask[] | undefined;
    const epicId = callArgs[10] as string | undefined;

    expect(epicTasks).toBeUndefined();
    expect(epicId).toBeUndefined();
  });

  it("epic bead with 0 children auto-closes", async () => {
    const epicIssue = makeIssue("epic-empty", "epic");
    const closeFn = vi.fn().mockResolvedValue(undefined);
    const seedsClient = makeSeedsClient({
      ready: vi.fn().mockResolvedValue([epicIssue]),
      show: vi.fn().mockResolvedValue({
        ...epicIssue,
        children: [],
      }),
      close: closeFn,
    });
    const store = makeStore();
    const dispatcher = new Dispatcher(seedsClient, store, "/tmp/project");

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    // Should be skipped (auto-closed), not dispatched
    expect(result.dispatched).toHaveLength(0);
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0].seedId).toBe("epic-empty");
    expect(result.skipped[0].reason).toContain("auto-closed");
    expect(result.skipped[0].reason).toContain("no children");

    // close() should have been called
    expect(closeFn).toHaveBeenCalledWith("epic-empty", expect.stringContaining("no children"));

    // No worker should have been spawned
    expect(spawnSpy).not.toHaveBeenCalled();
  });

  it("epic counts as 1 agent slot regardless of child task count", async () => {
    const epicIssue = makeIssue("epic-big", "epic");
    const taskIssue = makeIssue("task-1", "task");

    const seedsClient = makeSeedsClient({
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
    const dispatcher = new Dispatcher(seedsClient, store, "/tmp/project");

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true, maxAgents: 2 });

    // Both should be dispatched — the epic counts as 1 slot, leaving room for the task
    expect(result.dispatched).toHaveLength(2);
    expect(result.dispatched.map(d => d.seedId)).toContain("epic-big");
    expect(result.dispatched.map(d => d.seedId)).toContain("task-1");

    // spawnAgent called twice
    expect(spawnSpy).toHaveBeenCalledTimes(2);

    // Find the epic call — it should have epicTasks
    const epicCall = spawnSpy.mock.calls.find(c => (c[2] as { id: string }).id === "epic-big");
    expect(epicCall).toBeDefined();
    const epicTasks = epicCall![9] as EpicTask[];
    expect(epicTasks).toBeDefined();
    expect(epicTasks).toHaveLength(3); // getTaskOrder mock returns 3

    // Find the task call — it should NOT have epicTasks
    const taskCall = spawnSpy.mock.calls.find(c => (c[2] as { id: string }).id === "task-1");
    expect(taskCall).toBeDefined();
    expect(taskCall![9]).toBeUndefined();
  });

  it("feature bead with open children still skips (unchanged behavior)", async () => {
    const featureIssue = makeIssue("feat-1", "feature");
    const seedsClient = makeSeedsClient({
      ready: vi.fn().mockResolvedValue([featureIssue]),
      show: vi.fn().mockResolvedValue({
        ...featureIssue,
        children: ["child-1"],
        status: "open",
      }),
    });
    const store = makeStore();
    const dispatcher = new Dispatcher(seedsClient, store, "/tmp/project");

    const spawnSpy = vi.spyOn(dispatcher as never as { spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ pipeline: true });

    // Feature beads with open children are skipped, not dispatched
    expect(result.dispatched).toHaveLength(0);
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0].reason).toContain("organizational container");

    // No worker spawned
    expect(spawnSpy).not.toHaveBeenCalled();
  });

  it("epic with no actionable child tasks auto-closes", async () => {
    // Override getTaskOrder to return empty for this test
    const { getTaskOrder } = await import("../task-ordering.js");
    vi.mocked(getTaskOrder).mockResolvedValueOnce([]);

    const epicIssue = makeIssue("epic-containers", "epic");
    const closeFn = vi.fn().mockResolvedValue(undefined);
    const seedsClient = makeSeedsClient({
      ready: vi.fn().mockResolvedValue([epicIssue]),
      show: vi.fn().mockResolvedValue({
        ...epicIssue,
        children: ["story-1", "story-2"],
      }),
      close: closeFn,
    });
    const store = makeStore();
    const dispatcher = new Dispatcher(seedsClient, store, "/tmp/project");

    const result = await dispatcher.dispatch({ pipeline: true });

    expect(result.dispatched).toHaveLength(0);
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0].reason).toContain("no actionable child tasks");
    expect(closeFn).toHaveBeenCalledWith("epic-containers", expect.stringContaining("no actionable"));
  });
});
