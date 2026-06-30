import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockQuestion,
  mockRlClose,
  mockVcsCreate,
} = vi.hoisted(() => ({
  mockQuestion: vi.fn(),
  mockRlClose: vi.fn(),
  mockVcsCreate: vi.fn(),
}));

vi.mock("node:readline", () => ({
  createInterface: () => ({
    question: (prompt: string, cb: (answer: string) => void) => {
      const answer = mockQuestion(prompt);
      if (answer && typeof (answer as Promise<string>).then === "function") {
        (answer as Promise<string>).then((value) => cb(value));
      } else {
        cb(String(answer ?? ""));
      }
    },
    close: () => mockRlClose(),
  }),
  emitKeypressEvents: vi.fn(),
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: (...args: unknown[]) => mockVcsCreate(...args),
  },
}));

import { checkBranchMismatch } from "../commands/run.js";

describe("checkBranchMismatch", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("returns false when no in-progress beads exist", async () => {
    mockVcsCreate.mockResolvedValue({
      getCurrentBranch: vi.fn().mockResolvedValue("main"),
      checkoutBranch: vi.fn().mockResolvedValue(undefined),
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    });

    const taskClient = {
      list: vi.fn().mockResolvedValue([]),
      show: vi.fn(),
    } as any;

    await expect(checkBranchMismatch(taskClient, "/repo")).resolves.toBe(false);
    expect(taskClient.show).not.toHaveBeenCalled();
  });

  it("switches to the mismatched target branch when the user accepts", async () => {
    const checkoutBranch = vi.fn().mockResolvedValue(undefined);
    mockVcsCreate.mockResolvedValue({
      getCurrentBranch: vi.fn().mockResolvedValue("main"),
      checkoutBranch,
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    });
    mockQuestion.mockReturnValue(""); // default yes

    const taskClient = {
      list: vi.fn().mockResolvedValue([{ id: "task-1" }]),
      show: vi.fn().mockResolvedValue({ labels: ["branch:feature/test"] }),
    } as any;

    await expect(checkBranchMismatch(taskClient, "/repo")).resolves.toBe(false);
    expect(checkoutBranch).toHaveBeenCalledWith("/repo", "feature/test");
    expect(vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("Switched to branch feature/test");
  });

  it("returns true and prints skip guidance when the user declines the switch", async () => {
    const checkoutBranch = vi.fn().mockResolvedValue(undefined);
    mockVcsCreate.mockResolvedValue({
      getCurrentBranch: vi.fn().mockResolvedValue("main"),
      checkoutBranch,
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    });
    mockQuestion.mockReturnValue("n");

    const taskClient = {
      list: vi.fn().mockResolvedValue([{ id: "task-1" }]),
      show: vi.fn().mockResolvedValue({ labels: ["branch:feature/test"] }),
    } as any;

    await expect(checkBranchMismatch(taskClient, "/repo")).resolves.toBe(true);
    expect(checkoutBranch).not.toHaveBeenCalled();
    expect(vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("Skipping beads task-1");
  });

  it("returns true and prints an error when branch checkout fails", async () => {
    const checkoutBranch = vi.fn().mockRejectedValue(new Error("checkout failed"));
    mockVcsCreate.mockResolvedValue({
      getCurrentBranch: vi.fn().mockResolvedValue("main"),
      checkoutBranch,
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    });
    mockQuestion.mockReturnValue("y");

    const taskClient = {
      list: vi.fn().mockResolvedValue([{ id: "task-1" }]),
      show: vi.fn().mockResolvedValue({ labels: ["branch:feature/test"] }),
    } as any;

    await expect(checkBranchMismatch(taskClient, "/repo")).resolves.toBe(true);
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("Failed to switch to branch feature/test: checkout failed");
  });
});
