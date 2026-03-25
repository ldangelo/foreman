/**
 * Tests for branch: label auto-labeling during dispatch.
 *
 * Verifies that:
 * 1. On a non-default branch, dispatched beads get branch:<name> label
 * 2. On the default branch, no label is added
 * 3. Beads that already have a branch: label are not re-labeled
 * 4. Child beads inherit branch: label from parent (even on default branch)
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Issue } from "../../lib/task-client.js";
import type { ForemanStore, Run } from "../../lib/store.js";

// ── Module mocks ─────────────────────────────────────────────────────────────

vi.mock("../../lib/git.js", () => ({
  getCurrentBranch: vi.fn().mockResolvedValue("installer"),
  detectDefaultBranch: vi.fn().mockResolvedValue("main"),
  createWorktree: vi.fn().mockResolvedValue({
    worktreePath: "/tmp/worktrees/seed-001",
    branchName: "foreman/seed-001",
  }),
  gitBranchExists: vi.fn().mockResolvedValue(false),
  getRepoRoot: vi.fn().mockResolvedValue("/tmp"),
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
import { getCurrentBranch, detectDefaultBranch } from "../../lib/git.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeIssue(id: string, parent?: string, labels?: string[]): Issue {
  return {
    id,
    title: `Seed ${id}`,
    type: "feature",
    priority: "2",
    status: "open",
    assignee: null,
    parent: parent ?? null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    labels,
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
    getRunsForSeed: vi.fn().mockReturnValue([]),
    ...overrides,
  } as unknown as ForemanStore;
}

function makeTaskClient(issues: Issue[], detailLabels?: Record<string, string[]>) {
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
    vi.mocked(getCurrentBranch).mockResolvedValue("installer");
    vi.mocked(detectDefaultBranch).mockResolvedValue("main");
  });

  it("adds branch:installer label when on non-default branch", async () => {
    const seed = makeIssue("seed-001");
    const taskClient = makeTaskClient([seed]);
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true });

    // update() should have been called with branch:installer label
    expect(taskClient.update).toHaveBeenCalledWith("seed-001", {
      labels: ["branch:installer"],
    });
  });

  it("does NOT add branch label when on default branch (main)", async () => {
    vi.mocked(getCurrentBranch).mockResolvedValue("main");
    vi.mocked(detectDefaultBranch).mockResolvedValue("main");

    const seed = makeIssue("seed-001");
    const taskClient = makeTaskClient([seed]);
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true });

    // update() should NOT have been called with a branch label
    const updateCalls = vi.mocked(taskClient.update).mock.calls;
    const branchLabelCalls = updateCalls.filter(([, opts]) =>
      opts.labels?.some((l: string) => l.startsWith("branch:")),
    );
    expect(branchLabelCalls).toHaveLength(0);
  });

  it("does NOT add branch label when on dev branch (known default)", async () => {
    vi.mocked(getCurrentBranch).mockResolvedValue("dev");
    vi.mocked(detectDefaultBranch).mockResolvedValue("dev");

    const seed = makeIssue("seed-001");
    const taskClient = makeTaskClient([seed]);
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true });

    const updateCalls = vi.mocked(taskClient.update).mock.calls;
    const branchLabelCalls = updateCalls.filter(([, opts]) =>
      opts.labels?.some((l: string) => l.startsWith("branch:")),
    );
    expect(branchLabelCalls).toHaveLength(0);
  });

  it("does NOT re-label a bead that already has a branch: label", async () => {
    const seed = makeIssue("seed-001");
    // Bead already has branch:another-branch label
    const taskClient = makeTaskClient([seed], { "seed-001": ["branch:another-branch"] });
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true });

    const updateCalls = vi.mocked(taskClient.update).mock.calls;
    const branchLabelCalls = updateCalls.filter(([, opts]) =>
      opts.labels?.some((l: string) => l.startsWith("branch:")),
    );
    expect(branchLabelCalls).toHaveLength(0);
  });

  it("inherits branch: label from parent bead", async () => {
    // On default branch but parent has branch:feature-x
    vi.mocked(getCurrentBranch).mockResolvedValue("main");
    vi.mocked(detectDefaultBranch).mockResolvedValue("main");

    const parentSeed = makeIssue("parent-001");
    const childSeed = makeIssue("child-001", "parent-001");
    const taskClient = makeTaskClient([childSeed], {
      "parent-001": ["branch:feature-x"],
      "child-001": [],
    });
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true });

    // Child should inherit branch:feature-x from parent
    expect(taskClient.update).toHaveBeenCalledWith("child-001", {
      labels: ["branch:feature-x"],
    });
  });

  it("does NOT inherit branch: label when parent targets default branch", async () => {
    vi.mocked(getCurrentBranch).mockResolvedValue("main");
    vi.mocked(detectDefaultBranch).mockResolvedValue("main");

    const parentSeed = makeIssue("parent-001");
    const childSeed = makeIssue("child-001", "parent-001");
    const taskClient = makeTaskClient([childSeed], {
      "parent-001": ["branch:main"],
      "child-001": [],
    });
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true });

    const updateCalls = vi.mocked(taskClient.update).mock.calls;
    const branchLabelCalls = updateCalls.filter(([, opts]) =>
      opts.labels?.some((l: string) => l.startsWith("branch:")),
    );
    expect(branchLabelCalls).toHaveLength(0);
  });

  it("preserves existing non-branch labels when adding branch label", async () => {
    const seed = makeIssue("seed-001", undefined, ["workflow:smoke"]);
    const taskClient = makeTaskClient([seed], { "seed-001": ["workflow:smoke"] });
    const store = makeStore();
    const dispatcher = new Dispatcher(taskClient, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true });

    expect(taskClient.update).toHaveBeenCalledWith("seed-001", {
      labels: expect.arrayContaining(["workflow:smoke", "branch:installer"]),
    });
  });
});
