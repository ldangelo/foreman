/**
 * Tests for the checkBranchMismatch() function in run.ts.
 *
 * Verifies that:
 * 1. No in-progress tasks → no prompt, returns false
 * 2. In-progress tasks without branch: labels → no prompt, returns false
 * 3. In-progress tasks with matching branch: label → no prompt, returns false
 * 4. In-progress tasks with different branch: label → prompt
 *    - User says yes → checkout target branch, returns false
 *    - User says no → returns true (abort)
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import type { ITaskClient, Issue } from "../../lib/task-client.js";

// ── Module mocks ─────────────────────────────────────────────────────────────

const {
  mockGetCurrentBranch,
  mockCheckoutBranch,
  mockCreateVcsBackend,
} = vi.hoisted(() => {
  const mockGetCurrentBranch = vi.fn().mockResolvedValue("dev");
  const mockCheckoutBranch = vi.fn().mockResolvedValue(undefined);
  const mockCreateVcsBackend = vi.fn().mockResolvedValue({
    name: "git",
    getCurrentBranch: mockGetCurrentBranch,
    checkoutBranch: mockCheckoutBranch,
  });
  return { mockGetCurrentBranch, mockCheckoutBranch, mockCreateVcsBackend };
});

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: mockCreateVcsBackend,
  },
}));

vi.mock("../../lib/project-config.js", () => ({
  loadProjectConfig: vi.fn().mockReturnValue(null),
  resolveVcsConfig: vi.fn().mockReturnValue({ backend: "auto" }),
}));

vi.mock("node:readline", () => ({
  createInterface: vi.fn().mockReturnValue({
    question: vi.fn((_q: string, cb: (answer: string) => void) => cb("y")),
    close: vi.fn(),
  }),
}));

import { createInterface } from "node:readline";
import { checkBranchMismatch } from "../../cli/commands/run.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeIssue(id: string, status: string = "in_progress"): Issue {
  return {
    id,
    title: `Task ${id}`,
    type: "feature",
    priority: "2",
    status,
    assignee: null,
    parent: null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };
}

function makeTaskClient(
  inProgressTasks: Issue[],
  detailLabels: Record<string, string[]> = {},
): ITaskClient {
  return {
    ready: vi.fn().mockResolvedValue([]),
    list: vi.fn().mockImplementation(async (opts?: { status?: string }) => {
      if (opts?.status === "in_progress") return inProgressTasks;
      return [];
    }),
    show: vi.fn().mockImplementation(async (id: string) => ({
      status: "in_progress",
      description: null,
      notes: null,
      labels: detailLabels[id] ?? [],
    })),
    update: vi.fn().mockResolvedValue(undefined),
    close: vi.fn().mockResolvedValue(undefined),
  };
}

function mockReadlineAnswer(answer: string): void {
  vi.mocked(createInterface).mockReturnValue({
    question: vi.fn((_q: string, cb: (answer: string) => void) => cb(answer)),
    close: vi.fn(),
  } as unknown as ReturnType<typeof createInterface>);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("checkBranchMismatch", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockGetCurrentBranch.mockResolvedValue("dev");
    mockCheckoutBranch.mockResolvedValue(undefined);
    mockCreateVcsBackend.mockResolvedValue({
      name: "git",
      getCurrentBranch: mockGetCurrentBranch,
      checkoutBranch: mockCheckoutBranch,
    });
    mockReadlineAnswer("y");
  });

  it("returns false when no in-progress tasks exist", async () => {
    const taskClient = makeTaskClient([]);
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(result).toBe(false);
    expect(createInterface).not.toHaveBeenCalled();
  });

  it("returns false when in-progress tasks have no branch: labels", async () => {
    const tasks = [makeIssue("task-001"), makeIssue("task-002")];
    const taskClient = makeTaskClient(tasks, {
      "task-001": ["workflow:smoke"],
      "task-002": [],
    });
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(result).toBe(false);
    expect(createInterface).not.toHaveBeenCalled();
  });

  it("returns false when branch: label matches current branch", async () => {
    mockGetCurrentBranch.mockResolvedValue("installer");
    const tasks = [makeIssue("task-001")];
    const taskClient = makeTaskClient(tasks, { "task-001": ["branch:installer"] });
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(result).toBe(false);
    expect(createInterface).not.toHaveBeenCalled();
  });

  it("does not prompt when the current branch is a decorated jujutsu name matching the target", async () => {
    mockGetCurrentBranch.mockResolvedValue("dev*");
    const tasks = [makeIssue("task-001")];
    const taskClient = makeTaskClient(tasks, { "task-001": ["branch:dev"] });
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(result).toBe(false);
    expect(createInterface).not.toHaveBeenCalled();
  });

  it("prompts when branch: label differs from current branch", async () => {
    const tasks = [makeIssue("task-001")];
    const taskClient = makeTaskClient(tasks, { "task-001": ["branch:installer"] });
    await checkBranchMismatch(taskClient, "/tmp");
    expect(createInterface).toHaveBeenCalled();
  });

  it("checks out the target branch when user says yes", async () => {
    mockReadlineAnswer("y");
    const tasks = [makeIssue("task-001")];
    const taskClient = makeTaskClient(tasks, { "task-001": ["branch:installer"] });
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(mockCheckoutBranch).toHaveBeenCalledWith("/tmp", "installer");
    expect(result).toBe(false);
  });

  it("checks out the target branch when user presses enter (default yes)", async () => {
    mockReadlineAnswer("");
    const tasks = [makeIssue("task-001")];
    const taskClient = makeTaskClient(tasks, { "task-001": ["branch:installer"] });
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(mockCheckoutBranch).toHaveBeenCalledWith("/tmp", "installer");
    expect(result).toBe(false);
  });

  it("returns true (abort) when user says no", async () => {
    mockReadlineAnswer("n");
    const tasks = [makeIssue("task-001")];
    const taskClient = makeTaskClient(tasks, { "task-001": ["branch:installer"] });
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(mockCheckoutBranch).not.toHaveBeenCalled();
    expect(result).toBe(true);
  });

  it("groups multiple tasks by target branch", async () => {
    const tasks = [makeIssue("task-001"), makeIssue("task-002")];
    const taskClient = makeTaskClient(tasks, {
      "task-001": ["branch:installer"],
      "task-002": ["branch:installer"],
    });
    mockReadlineAnswer("y");
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(createInterface).toHaveBeenCalledTimes(1);
    expect(result).toBe(false);
  });

  it("returns false when getCurrentBranch fails", async () => {
    mockGetCurrentBranch.mockRejectedValue(new Error("vcs error"));
    const tasks = [makeIssue("task-001")];
    const taskClient = makeTaskClient(tasks, { "task-001": ["branch:installer"] });
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(result).toBe(false);
  });

  it("returns false when list() fails", async () => {
    const taskClient = makeTaskClient([]);
    vi.mocked(taskClient.list).mockRejectedValue(new Error("native task store error"));
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(result).toBe(false);
  });
});
