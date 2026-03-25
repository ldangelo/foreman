/**
 * Tests for the checkBranchMismatch() function in run.ts.
 *
 * Verifies that:
 * 1. No in-progress beads → no prompt, returns false
 * 2. In-progress beads without branch: labels → no prompt, returns false
 * 3. In-progress beads with matching branch: label → no prompt, returns false
 * 4. In-progress beads with different branch: label → prompt
 *    - User says yes → git checkout, returns false
 *    - User says no → returns true (abort)
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import type { ITaskClient, Issue } from "../../lib/task-client.js";

// ── Module mocks ─────────────────────────────────────────────────────────────

vi.mock("../../lib/git.js", () => ({
  getCurrentBranch: vi.fn().mockResolvedValue("dev"),
  checkoutBranch: vi.fn().mockResolvedValue(undefined),
  getRepoRoot: vi.fn().mockResolvedValue("/tmp"),
}));

vi.mock("node:readline", () => ({
  createInterface: vi.fn().mockReturnValue({
    question: vi.fn((q: string, cb: (answer: string) => void) => cb("y")),
    close: vi.fn(),
  }),
}));

import { getCurrentBranch, checkoutBranch } from "../../lib/git.js";
import { createInterface } from "node:readline";
import { checkBranchMismatch } from "../../cli/commands/run.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeIssue(id: string, status: string = "in_progress"): Issue {
  return {
    id,
    title: `Seed ${id}`,
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
  inProgressBeads: Issue[],
  detailLabels: Record<string, string[]> = {},
): ITaskClient {
  return {
    ready: vi.fn().mockResolvedValue([]),
    list: vi.fn().mockImplementation(async (opts?: { status?: string }) => {
      if (opts?.status === "in_progress") return inProgressBeads;
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
    vi.mocked(getCurrentBranch).mockResolvedValue("dev");
    vi.mocked(checkoutBranch).mockResolvedValue(undefined);
    mockReadlineAnswer("y");
  });

  it("returns false when no in-progress beads exist", async () => {
    const taskClient = makeTaskClient([]);
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(result).toBe(false);
    expect(createInterface).not.toHaveBeenCalled();
  });

  it("returns false when in-progress beads have no branch: labels", async () => {
    const beads = [makeIssue("seed-001"), makeIssue("seed-002")];
    const taskClient = makeTaskClient(beads, {
      "seed-001": ["workflow:smoke"],
      "seed-002": [],
    });
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(result).toBe(false);
    expect(createInterface).not.toHaveBeenCalled();
  });

  it("returns false when branch: label matches current branch", async () => {
    vi.mocked(getCurrentBranch).mockResolvedValue("installer");
    const beads = [makeIssue("seed-001")];
    const taskClient = makeTaskClient(beads, { "seed-001": ["branch:installer"] });
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(result).toBe(false);
    expect(createInterface).not.toHaveBeenCalled();
  });

  it("prompts when branch: label differs from current branch", async () => {
    const beads = [makeIssue("seed-001")];
    const taskClient = makeTaskClient(beads, { "seed-001": ["branch:installer"] });
    // current branch is "dev", bead targets "installer" → mismatch
    await checkBranchMismatch(taskClient, "/tmp");
    expect(createInterface).toHaveBeenCalled();
  });

  it("checks out the target branch when user says yes", async () => {
    mockReadlineAnswer("y");
    const beads = [makeIssue("seed-001")];
    const taskClient = makeTaskClient(beads, { "seed-001": ["branch:installer"] });
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(checkoutBranch).toHaveBeenCalledWith("/tmp", "installer");
    expect(result).toBe(false);
  });

  it("checks out the target branch when user presses enter (default yes)", async () => {
    mockReadlineAnswer("");
    const beads = [makeIssue("seed-001")];
    const taskClient = makeTaskClient(beads, { "seed-001": ["branch:installer"] });
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(checkoutBranch).toHaveBeenCalledWith("/tmp", "installer");
    expect(result).toBe(false);
  });

  it("returns true (abort) when user says no", async () => {
    mockReadlineAnswer("n");
    const beads = [makeIssue("seed-001")];
    const taskClient = makeTaskClient(beads, { "seed-001": ["branch:installer"] });
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(checkoutBranch).not.toHaveBeenCalled();
    expect(result).toBe(true);
  });

  it("groups multiple beads by target branch", async () => {
    const beads = [makeIssue("seed-001"), makeIssue("seed-002")];
    const taskClient = makeTaskClient(beads, {
      "seed-001": ["branch:installer"],
      "seed-002": ["branch:installer"],
    });
    mockReadlineAnswer("y");
    const result = await checkBranchMismatch(taskClient, "/tmp");
    // Should prompt once for the group, not twice
    expect(createInterface).toHaveBeenCalledTimes(1);
    expect(result).toBe(false);
  });

  it("returns false when getCurrentBranch fails", async () => {
    vi.mocked(getCurrentBranch).mockRejectedValue(new Error("git error"));
    const beads = [makeIssue("seed-001")];
    const taskClient = makeTaskClient(beads, { "seed-001": ["branch:installer"] });
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(result).toBe(false);
  });

  it("returns false when list() fails", async () => {
    const taskClient = makeTaskClient([]);
    vi.mocked(taskClient.list).mockRejectedValue(new Error("br error"));
    const result = await checkBranchMismatch(taskClient, "/tmp");
    expect(result).toBe(false);
  });
});
