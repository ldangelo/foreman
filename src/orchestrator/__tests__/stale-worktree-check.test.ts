/**
 * Unit tests for stale worktree check module.
 * Tests pre-flight rebase detection and auto-rebase functionality.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  checkAndRebaseStaleWorktree,
  detectStaleWorktree,
  hasUncommittedChanges,
  getWorktreeStatusSummary,
} from "../stale-worktree-check.js";

// Mock ForemanStore
const mockStore = {
  logEvent: vi.fn(),
};

// Mock VcsBackend
function createMockVcs(overrides: Record<string, unknown> = {}) {
  return {
    getHeadId: vi.fn().mockResolvedValue("abc123def456"),
    fetch: vi.fn().mockResolvedValue(undefined),
    resolveRef: vi.fn().mockResolvedValue("xyz789abc123"),
    rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    status: vi.fn().mockResolvedValue(""),
    getCurrentBranch: vi.fn().mockResolvedValue("foreman/seed-abc"),
    ...overrides,
  };
}

import type { ForemanStore } from "../../lib/store.js";
import type { VcsBackend } from "../../lib/vcs/index.js";

describe("checkAndRebaseStaleWorktree", () => {
  let mockStoreInstance: ForemanStore;
  let worktreePath = "/worktrees/project/seed-abc";
  let targetBranch = "dev";

  beforeEach(() => {
    vi.clearAllMocks();
    mockStore.logEvent = vi.fn();
    mockStoreInstance = mockStore as unknown as ForemanStore;
  });

  it("should return rebased=true when worktree is already up-to-date", async () => {
    const mockVcs = createMockVcs({
      getHeadId: vi.fn().mockResolvedValue("abc123"),
      resolveRef: vi.fn().mockResolvedValue("abc123"),
    });

    const result = await checkAndRebaseStaleWorktree(
      mockVcs as unknown as VcsBackend,
      worktreePath,
      targetBranch,
      mockStoreInstance,
      "proj-123",
      "run-456",
      "seed-abc",
    );

    expect(result.rebased).toBe(true);
    expect(result.autoRebasePerformed).toBe(false);
    expect(mockVcs.rebase).not.toHaveBeenCalled();
  });

  it("should auto-rebase when worktree is stale", async () => {
    const mockVcs = createMockVcs({
      getHeadId: vi.fn().mockResolvedValue("abc123"),
      resolveRef: vi.fn().mockResolvedValue("def456"),
    });

    const result = await checkAndRebaseStaleWorktree(
      mockVcs as unknown as VcsBackend,
      worktreePath,
      targetBranch,
      mockStoreInstance,
      "proj-123",
      "run-456",
      "seed-abc",
    );

    expect(result.rebased).toBe(true);
    expect(result.autoRebasePerformed).toBe(true);
    expect(mockVcs.rebase).toHaveBeenCalledWith(worktreePath, "origin/dev");
  });

  it("should log worktree-rebased event on successful rebase", async () => {
    const mockVcs = createMockVcs({
      getHeadId: vi.fn().mockResolvedValue("abc123"),
      resolveRef: vi.fn().mockResolvedValue("def456"),
    });

    await checkAndRebaseStaleWorktree(
      mockVcs as unknown as VcsBackend,
      worktreePath,
      targetBranch,
      mockStoreInstance,
      "proj-123",
      "run-456",
      "seed-abc",
    );

    expect(mockStore.logEvent).toHaveBeenCalledWith(
      "proj-123",
      "worktree-rebased",
      expect.objectContaining({
        seedId: "seed-abc",
        runId: "run-456",
        reason: "pre-dispatch",
      }),
      "run-456",
    );
  });

  it("should return rebased=false when rebase fails with conflicts", async () => {
    // Create fresh mock with conflict response
    const mockVcs = {
      getHeadId: vi.fn().mockResolvedValue("abc123"),
      fetch: vi.fn().mockResolvedValue(undefined),
      resolveRef: vi.fn().mockResolvedValue("def456"),
      rebase: vi.fn().mockResolvedValue({
        success: false,
        hasConflicts: true,
        conflictingFiles: ["src/conflict.ts", "src/other.ts"],
      }),
      getCurrentBranch: vi.fn().mockResolvedValue("foreman/seed-abc"),
      status: vi.fn().mockResolvedValue(""),
    };

    const result = await checkAndRebaseStaleWorktree(
      mockVcs as unknown as VcsBackend,
      worktreePath,
      targetBranch,
      mockStoreInstance,
      "proj-123",
      "run-456",
      "seed-abc",
      { failOnConflict: false },
    );

    expect(result.rebased).toBe(false);
    expect(result.autoRebasePerformed).toBe(true);
    expect(result.conflictingFiles).toContain("src/conflict.ts");
  });

  it("should log worktree-rebase-failed event on conflict", async () => {
    // Create fresh mock with conflict response
    // Use failOnConflict: false to prevent throwing
    const mockVcs = {
      getHeadId: vi.fn().mockResolvedValue("abc123"),
      fetch: vi.fn().mockResolvedValue(undefined),
      resolveRef: vi.fn().mockResolvedValue("def456"),
      rebase: vi.fn().mockResolvedValue({
        success: false,
        hasConflicts: true,
        conflictingFiles: ["src/conflict.ts"],
      }),
      getCurrentBranch: vi.fn().mockResolvedValue("foreman/seed-abc"),
      status: vi.fn().mockResolvedValue(""),
    };

    const result = await checkAndRebaseStaleWorktree(
      mockVcs as unknown as VcsBackend,
      worktreePath,
      targetBranch,
      mockStoreInstance,
      "proj-123",
      "run-456",
      "seed-abc",
      { failOnConflict: false },
    );

    expect(result.rebased).toBe(false);
    expect(mockStore.logEvent).toHaveBeenCalledWith(
      "proj-123",
      "worktree-rebase-failed",
      expect.objectContaining({
        seedId: "seed-abc",
        conflictingFiles: ["src/conflict.ts"],
      }),
      "run-456",
    );
  });

  it("should skip rebase when origin/targetBranch doesn't exist", async () => {
    const mockVcs = createMockVcs({
      getHeadId: vi.fn().mockResolvedValue("abc123"),
      resolveRef: vi.fn().mockRejectedValue(new Error("unknown revision: origin/dev")),
    });

    const result = await checkAndRebaseStaleWorktree(
      mockVcs as unknown as VcsBackend,
      worktreePath,
      targetBranch,
      mockStoreInstance,
      "proj-123",
      "run-456",
      "seed-abc",
    );

    expect(result.rebased).toBe(true);
    expect(result.autoRebasePerformed).toBe(false);
  });

  it("should skip rebase for fresh worktree with no commits", async () => {
    const mockVcs = createMockVcs({
      getHeadId: vi.fn().mockRejectedValue(new Error("fatal: your current branch 'foreman/seed-abc' does not have any commits yet")),
    });

    const result = await checkAndRebaseStaleWorktree(
      mockVcs as unknown as VcsBackend,
      worktreePath,
      targetBranch,
      mockStoreInstance,
      "proj-123",
      "run-456",
      "seed-abc",
    );

    expect(result.rebased).toBe(true);
    expect(result.autoRebasePerformed).toBe(false);
  });

  it("should not rebase when autoRebase is disabled", async () => {
    const mockVcs = createMockVcs({
      getHeadId: vi.fn().mockResolvedValue("abc123"),
      resolveRef: vi.fn().mockResolvedValue("def456"),
    });

    const result = await checkAndRebaseStaleWorktree(
      mockVcs as unknown as VcsBackend,
      worktreePath,
      targetBranch,
      mockStoreInstance,
      "proj-123",
      "run-456",
      "seed-abc",
      { autoRebase: false },
    );

    expect(result.rebased).toBe(false);
    expect(result.autoRebasePerformed).toBe(false);
    expect(mockVcs.rebase).not.toHaveBeenCalled();
  });

  it("should throw when failOnConflict=true and rebase conflicts", async () => {
    const mockVcs = createMockVcs({
      getHeadId: vi.fn().mockResolvedValue("abc123"),
      resolveRef: vi.fn().mockResolvedValue("def456"),
      rebase: vi.fn().mockResolvedValue({
        success: false,
        hasConflicts: true,
        conflictingFiles: ["src/conflict.ts"],
      }),
    });

    await expect(
      checkAndRebaseStaleWorktree(
        mockVcs as unknown as VcsBackend,
        worktreePath,
        targetBranch,
        mockStoreInstance,
        "proj-123",
        "run-456",
        "seed-abc",
        { failOnConflict: true },
      ),
    ).rejects.toThrow("Rebase failed with conflicts");
  });

  it("should not throw when failOnConflict=false and rebase conflicts", async () => {
    const mockVcs = createMockVcs({
      getHeadId: vi.fn().mockResolvedValue("abc123"),
      resolveRef: vi.fn().mockResolvedValue("def456"),
      rebase: vi.fn().mockResolvedValue({
        success: false,
        hasConflicts: true,
        conflictingFiles: ["src/conflict.ts"],
      }),
    });

    const result = await checkAndRebaseStaleWorktree(
      mockVcs as unknown as VcsBackend,
      worktreePath,
      targetBranch,
      mockStoreInstance,
      "proj-123",
      "run-456",
      "seed-abc",
      { failOnConflict: false },
    );

    expect(result.rebased).toBe(false);
    expect(result.error).toContain("Rebase failed with conflicts");
  });
});

describe("detectStaleWorktree", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("should return isStale=true when worktree is behind target", async () => {
    const mockVcs = createMockVcs({
      getHeadId: vi.fn().mockResolvedValue("abc123"),
      resolveRef: vi.fn().mockResolvedValue("def456"),
    });

    const result = await detectStaleWorktree(
      mockVcs as unknown as VcsBackend,
      "/worktrees/project/seed-abc",
      "dev",
    );

    expect(result.isStale).toBe(true);
    expect(result.localHead).toBe("abc123");
    expect(result.remoteHead).toBe("def456");
  });

  it("should return isStale=false when worktree is up-to-date", async () => {
    const mockVcs = createMockVcs({
      getHeadId: vi.fn().mockResolvedValue("abc123"),
      resolveRef: vi.fn().mockResolvedValue("abc123"),
    });

    const result = await detectStaleWorktree(
      mockVcs as unknown as VcsBackend,
      "/worktrees/project/seed-abc",
      "dev",
    );

    expect(result.isStale).toBe(false);
  });

  it("should return isStale=false when origin/target doesn't exist", async () => {
    const mockVcs = createMockVcs({
      getHeadId: vi.fn().mockResolvedValue("abc123"),
      resolveRef: vi.fn().mockRejectedValue(new Error("unknown revision")),
    });

    const result = await detectStaleWorktree(
      mockVcs as unknown as VcsBackend,
      "/worktrees/project/seed-abc",
      "dev",
    );

    expect(result.isStale).toBe(false);
  });
});

describe("hasUncommittedChanges", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("should return true when there are uncommitted changes", async () => {
    const mockVcs = createMockVcs({
      status: vi.fn().mockResolvedValue(" M src/modified.ts\n?? src/new.ts"),
    });

    const result = await hasUncommittedChanges(
      mockVcs as unknown as VcsBackend,
      "/worktrees/project/seed-abc",
    );

    expect(result).toBe(true);
  });

  it("should return false when working tree is clean", async () => {
    const mockVcs = createMockVcs({
      status: vi.fn().mockResolvedValue(""),
    });

    const result = await hasUncommittedChanges(
      mockVcs as unknown as VcsBackend,
      "/worktrees/project/seed-abc",
    );

    expect(result).toBe(false);
  });
});

describe("getWorktreeStatusSummary", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("should return formatted status summary", async () => {
    const mockVcs = createMockVcs({
      getHeadId: vi.fn().mockResolvedValue("abc12345"),
      resolveRef: vi.fn().mockResolvedValue("def67890"),
      getCurrentBranch: vi.fn().mockResolvedValue("foreman/seed-abc"),
      status: vi.fn().mockResolvedValue(""),
    });

    const summary = await getWorktreeStatusSummary(
      mockVcs as unknown as VcsBackend,
      "/worktrees/project/seed-abc",
      "dev",
    );

    expect(summary).toContain("foreman/seed-abc");
    expect(summary).toContain("abc12345");
    expect(summary).toContain("origin/dev");
    expect(summary).toContain("def67890");
  });

  it("should indicate stale status when behind", async () => {
    const mockVcs = createMockVcs({
      getHeadId: vi.fn().mockResolvedValue("abc12345"),
      resolveRef: vi.fn().mockResolvedValue("def67890"),
      getCurrentBranch: vi.fn().mockResolvedValue("foreman/seed-abc"),
      status: vi.fn().mockResolvedValue(""),
    });

    const summary = await getWorktreeStatusSummary(
      mockVcs as unknown as VcsBackend,
      "/worktrees/project/seed-abc",
      "dev",
    );

    expect(summary).toContain("stale");
  });

  it("should indicate up-to-date status when current", async () => {
    const mockVcs = createMockVcs({
      getHeadId: vi.fn().mockResolvedValue("abc12345"),
      resolveRef: vi.fn().mockResolvedValue("abc12345"),
      getCurrentBranch: vi.fn().mockResolvedValue("foreman/seed-abc"),
      status: vi.fn().mockResolvedValue(""),
    });

    const summary = await getWorktreeStatusSummary(
      mockVcs as unknown as VcsBackend,
      "/worktrees/project/seed-abc",
      "dev",
    );

    expect(summary).toContain("up-to-date");
  });
});