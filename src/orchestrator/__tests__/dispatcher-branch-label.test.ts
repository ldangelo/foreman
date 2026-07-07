/**
 * Tests for branch: label auto-labeling during dispatch.
 *
 * Verifies that:
 * 1. On a non-default branch, dispatched tasks get branch:<name> label
 * 2. On the default branch, no label is added
 * 3. Tasks that already have a branch: label are not re-labeled
 * 4. Child tasks inherit branch: label from parent (even on default branch)
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Issue } from "../../lib/task-client.js";
import type { ForemanStore, Run } from "../../lib/store.js";

// ── Module mocks ─────────────────────────────────────────────────────────────

// TRD-015: getCurrentBranch and detectDefaultBranch now go through GitBackend
// Use module-level mock functions so per-test overrides work
let mockGetCurrentBranch = vi.fn().mockResolvedValue("installer");
let mockDetectDefaultBranch = vi.fn().mockResolvedValue("main");

vi.mock("../../lib/setup.js", () => ({
  installDependencies: vi.fn().mockResolvedValue(undefined),
  runSetupWithCache: vi.fn().mockResolvedValue(undefined),
  runWorkspaceHook: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("../../lib/vcs/git-backend.js", () => ({
  GitBackend: class {
    constructor(_path: string) {}
    async getCurrentBranch(path: string): Promise<string> { return mockGetCurrentBranch(path); }
    async detectDefaultBranch(path: string): Promise<string> { return mockDetectDefaultBranch(path); }
    async branchExists(_path: string, _branch: string): Promise<boolean> { return false; }
    async createWorkspace(_repoPath: string, taskId: string): Promise<{ workspacePath: string; branchName: string }> {
      return { workspacePath: `/tmp/worktrees/${taskId}`, branchName: `foreman/${taskId}` };
    }
  },
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: vi.fn().mockImplementation(async () => ({
      name: "jujutsu",
      getCurrentBranch: async (path: string) => mockGetCurrentBranch(path),
      detectDefaultBranch: async (path: string) => mockDetectDefaultBranch(path),
      branchExists: async (_path: string, branch: string) => branch !== "wzplklnookuz" && branch !== "HEAD",
    })),
    resolveBackend: vi.fn((config: { backend: "git" | "jujutsu" | "auto" }) =>
      config.backend === "auto" ? "jujutsu" : config.backend),
  },
}));

vi.mock("../../lib/workflow-config-loader.js", () => ({
  resolveWorkflowType: vi.fn().mockReturnValue("feature"),
}));

vi.mock("../../lib/workflow-loader.js", () => ({
  resolveWorkflowName: vi.fn().mockReturnValue("default"),
  loadWorkflowConfig: vi.fn().mockReturnValue({ setup: undefined, setupCache: undefined }),
}));

vi.mock("../pi-rpc-spawn-strategy.js", () => ({
  isPiAvailable: vi.fn().mockReturnValue(false),
}));

vi.mock("../dispatcher.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../dispatcher.js")>();
  return {
    ...actual,
    spawnWorkerProcess: vi.fn().mockResolvedValue({}),
  };
});

import { Dispatcher } from "../dispatcher.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeIssue(id: string, parent?: string, labels?: string[]): Issue {
  return {
    id,
    title: `Task ${id}`,
    type: "task",
    priority: "2",
    status: "open",
    assignee: null,
    parent: parent ?? null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    labels,
  };
}


let currentReadyIssues: Issue[] = [];

function nativeTaskFromIssue(issue: Issue) {
  return {
    id: issue.id,
    title: issue.title,
    description: issue.description ?? null,
    type: issue.type,
    priority: Number(String(issue.priority ?? "2").replace(/^P/, "")) || 2,
    status: "ready",
    run_id: null,
    branch: null,
    external_id: null,
    labels: issue.labels ?? [],
    parent: issue.parent ?? null,
    created_at: issue.created_at,
    updated_at: issue.updated_at,
    approved_at: new Date().toISOString(),
    closed_at: null,
  };
}

function makeStore(overrides: Partial<ForemanStore> = {}): ForemanStore {
  return {
    getActiveRuns: vi.fn().mockReturnValue([] as Run[]),
    getRunsByStatus: vi.fn().mockReturnValue([] as Run[]),
    getRunsByStatuses: vi.fn().mockReturnValue([] as Run[]),
    getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    createRun: vi.fn().mockReturnValue({ id: "run-001" }),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    sendMessage: vi.fn(),
    getRunsForTask: vi.fn().mockReturnValue([]),
    hasNativeTasks: vi.fn().mockReturnValue(true),
    getReadyTasks: vi.fn(() => currentReadyIssues.map(nativeTaskFromIssue)),
    getTaskByExternalId: vi.fn().mockReturnValue(null),
    getTaskById: vi.fn((id: string) => currentReadyIssues.map(nativeTaskFromIssue).find((task) => task.id === id) ?? null),
    claimTask: vi.fn().mockReturnValue(true),
    updateTaskLabels: vi.fn(),
    ...overrides,
  } as unknown as ForemanStore;
}

function makeTaskClient(issues: Issue[], detailLabels?: Record<string, string[]>) {
  const existingIds = new Set(issues.map((issue) => issue.id));
  const detailIssues = Object.keys(detailLabels ?? {})
    .filter((id) => !existingIds.has(id))
    .map((id) => makeIssue(id, undefined, detailLabels?.[id]));
  currentReadyIssues = [
    ...issues.map((issue) => ({ ...issue, labels: detailLabels?.[issue.id] ?? issue.labels })),
    ...detailIssues,
  ];
  return {
    ready: vi.fn().mockResolvedValue(issues),
    list: vi.fn().mockResolvedValue(issues),
    show: vi.fn().mockImplementation(async (id: string) => {
      const issue = issues.find((i) => i.id === id);
      return {
        status: issue?.status ?? "open",
        description: null,
        notes: null,
        labels: detailLabels?.[id] ?? issue?.labels ?? [],
      };
    }),
    update: vi.fn().mockResolvedValue(undefined),
    close: vi.fn().mockResolvedValue(undefined),
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("Dispatcher — branch label auto-labeling", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // Reset to default values (non-default branch)
    mockGetCurrentBranch = vi.fn().mockResolvedValue("installer");
    mockDetectDefaultBranch = vi.fn().mockResolvedValue("main");
  });

  it("adds branch:installer label when on non-default branch", async () => {
    const task = makeIssue("task-001");
    const taskClient = makeTaskClient([task]);
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true });

    // update() should have been called with branch:installer label
    expect((store.updateTaskLabels as any)).toHaveBeenCalledWith("task-001", ["branch:installer"]);
  });

  it("does NOT add branch label when on default branch (main)", async () => {
    mockGetCurrentBranch = vi.fn().mockResolvedValue("main");
    mockDetectDefaultBranch = vi.fn().mockResolvedValue("main");

    const task = makeIssue("task-001");
    const taskClient = makeTaskClient([task]);
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true });

    // update() should NOT have been called with a branch label
    const updateCalls = vi.mocked((store.updateTaskLabels as any)).mock.calls;
    const branchLabelCalls = updateCalls.filter(([, labels]: [string, string[]]) =>
      labels.some((label: string) => label.startsWith("branch:")),
    );
    expect(branchLabelCalls).toHaveLength(0);
  });

  it("does NOT add branch label when on dev branch (known default)", async () => {
    mockGetCurrentBranch = vi.fn().mockResolvedValue("dev");
    mockDetectDefaultBranch = vi.fn().mockResolvedValue("dev");

    const task = makeIssue("task-001");
    const taskClient = makeTaskClient([task]);
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true });

    const updateCalls = vi.mocked((store.updateTaskLabels as any)).mock.calls;
    const branchLabelCalls = updateCalls.filter(([, labels]: [string, string[]]) =>
      labels.some((label: string) => label.startsWith("branch:")),
    );
    expect(branchLabelCalls).toHaveLength(0);
  });

  it("does NOT add branch label when current branch is detached HEAD", async () => {
    mockGetCurrentBranch = vi.fn().mockResolvedValue("HEAD");
    mockDetectDefaultBranch = vi.fn().mockResolvedValue("dev");

    const task = makeIssue("task-001");
    const taskClient = makeTaskClient([task]);
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true });

    const updateCalls = vi.mocked((store.updateTaskLabels as any)).mock.calls;
    const branchLabelCalls = updateCalls.filter(([, labels]: [string, string[]]) =>
      labels.some((label: string) => label.startsWith("branch:")),
    );
    expect(branchLabelCalls).toHaveLength(0);
  });

  it("does NOT add branch label when current jujutsu branch name is only an anonymous change id", async () => {
    mockGetCurrentBranch = vi.fn().mockResolvedValue("wzplklnookuz");
    const task = makeIssue("task-001");
    const taskClient = makeTaskClient([task]);
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true });

    const updateCalls = vi.mocked((store.updateTaskLabels as any)).mock.calls;
    const branchLabelCalls = updateCalls.filter(([, labels]: [string, string[]]) =>
      labels.some((label: string) => label.startsWith("branch:")),
    );
    expect(branchLabelCalls).toHaveLength(0);
  });

  it("does NOT re-label a task that already has a branch: label", async () => {
    const task = makeIssue("task-001");
    // Task already has branch:another-branch label
    const taskClient = makeTaskClient([task], { "task-001": ["branch:another-branch"] });
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true });

    const updateCalls = vi.mocked((store.updateTaskLabels as any)).mock.calls;
    const branchLabelCalls = updateCalls.filter(([, labels]: [string, string[]]) =>
      labels.some((label: string) => label.startsWith("branch:")),
    );
    expect(branchLabelCalls).toHaveLength(0);
  });

  it("inherits branch: label from parent task", async () => {
    // On default branch but parent has branch:feature-x
    mockGetCurrentBranch = vi.fn().mockResolvedValue("main");
    mockDetectDefaultBranch = vi.fn().mockResolvedValue("main");

    const parentTask = makeIssue("parent-001");
    const childTask = makeIssue("child-001", "parent-001");
    const taskClient = makeTaskClient([childTask], {
      "parent-001": ["branch:feature-x"],
      "child-001": [],
    });
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true });

    // Child should inherit branch:feature-x from parent
    expect((store.updateTaskLabels as any)).toHaveBeenCalledWith("child-001", ["branch:feature-x"]);
  });

  it("does NOT inherit branch: label when parent targets default branch", async () => {
    mockGetCurrentBranch = vi.fn().mockResolvedValue("main");
    mockDetectDefaultBranch = vi.fn().mockResolvedValue("main");

    const parentTask = makeIssue("parent-001");
    const childTask = makeIssue("child-001", "parent-001");
    const taskClient = makeTaskClient([childTask], {
      "parent-001": ["branch:main"],
      "child-001": [],
    });
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true });

    const updateCalls = vi.mocked((store.updateTaskLabels as any)).mock.calls;
    const branchLabelCalls = updateCalls.filter(([, labels]: [string, string[]]) =>
      labels.some((label: string) => label.startsWith("branch:")),
    );
    expect(branchLabelCalls).toHaveLength(0);
  });

  it("preserves existing non-branch labels when adding branch label", async () => {
    const task = makeIssue("task-001", undefined, ["workflow:smoke"]);
    const taskClient = makeTaskClient([task], { "task-001": ["workflow:smoke"] });
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true });

    expect((store.updateTaskLabels as any)).toHaveBeenCalledWith("task-001", expect.arrayContaining(["workflow:smoke", "branch:installer"]));
  });

  // ── assumeDefaultBranch (daemon background dispatch) ─────────────────────────

  it("does NOT auto-label with the checked-out feature branch when assumeDefaultBranch is set", async () => {
    // Repo is checked out on a feature branch ("installer"), but the daemon must
    // treat the project as being on its default branch.
    mockGetCurrentBranch = vi.fn().mockResolvedValue("installer");
    mockDetectDefaultBranch = vi.fn().mockResolvedValue("main");

    const task = makeIssue("task-001");
    const taskClient = makeTaskClient([task]);
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true, assumeDefaultBranch: true });

    const updateCalls = vi.mocked((store.updateTaskLabels as any)).mock.calls;
    const branchLabelCalls = updateCalls.filter(([, labels]: [string, string[]]) =>
      labels.some((label: string) => label.startsWith("branch:")),
    );
    expect(branchLabelCalls).toHaveLength(0);
    // Must not even inspect the developer's checked-out branch.
    expect(mockGetCurrentBranch).not.toHaveBeenCalled();
  });

  it("interactive default (assumeDefaultBranch unset) still auto-labels on a feature branch", async () => {
    mockGetCurrentBranch = vi.fn().mockResolvedValue("installer");
    mockDetectDefaultBranch = vi.fn().mockResolvedValue("main");

    const task = makeIssue("task-001");
    const taskClient = makeTaskClient([task]);
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true });

    expect((store.updateTaskLabels as any)).toHaveBeenCalledWith("task-001", ["branch:installer"]);
  });

  it("still inherits parent branch label when assumeDefaultBranch is set", async () => {
    // Even though the daemon ignores the checked-out branch, explicit parent
    // branch-label inheritance must continue to work.
    mockGetCurrentBranch = vi.fn().mockResolvedValue("installer");
    mockDetectDefaultBranch = vi.fn().mockResolvedValue("main");

    const childTask = makeIssue("child-001", "parent-001");
    const taskClient = makeTaskClient([childTask], {
      "parent-001": ["branch:feature-x"],
      "child-001": [],
    });
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true, assumeDefaultBranch: true });

    expect((store.updateTaskLabels as any)).toHaveBeenCalledWith("child-001", ["branch:feature-x"]);
  });
});
