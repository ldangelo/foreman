/**
 * Tests for resolveBaseBranch() — dispatcher helper that detects whether a
 * seed should be stacked on a dependency branch instead of main.
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Run } from "../../lib/store.js";

// ── Module mocks ─────────────────────────────────────────────────────────────

// Shared mock show function — tests override this per test
let mockShowFn = vi.fn().mockResolvedValue({ dependencies: [] });

vi.mock("../../lib/git.js", () => ({
  gitBranchExists: vi.fn().mockResolvedValue(false),
  createWorktree: vi.fn(),
  detectDefaultBranch: vi.fn().mockResolvedValue("main"),
}));

vi.mock("../../lib/beads-rust.js", () => {
  // Must use a class-like function so `new BeadsRustClient(...)` works
  function MockBeadsRustClient(this: { show: typeof mockShowFn }) {
    this.show = mockShowFn;
  }
  return { BeadsRustClient: MockBeadsRustClient };
});

// Imports after mocks
import { gitBranchExists } from "../../lib/git.js";
import { resolveBaseBranch } from "../dispatcher.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "dep-seed",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: "/tmp/worktrees/dep-seed",
    status: "completed",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,
    base_branch: null,
    ...overrides,
  };
}

function makeStore(runs: Run[] = []) {
  return {
    getRunsForSeed: vi.fn((_seedId: string) => runs),
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("resolveBaseBranch()", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // Reset mockShowFn to return empty dependencies by default
    mockShowFn = vi.fn().mockResolvedValue({ dependencies: [] });
  });

  it("returns undefined when seed has no dependencies", async () => {
    mockShowFn = vi.fn().mockResolvedValue({ dependencies: [] });
    (gitBranchExists as any).mockResolvedValue(false);
    const store = makeStore([]);

    const result = await resolveBaseBranch("seed-b", "/tmp/project", store);

    expect(result).toBeUndefined();
  });

  it("returns undefined when dependency branch does not exist locally", async () => {
    mockShowFn = vi.fn().mockResolvedValue({ dependencies: ["dep-a"] });
    (gitBranchExists as any).mockResolvedValue(false); // branch doesn't exist
    const store = makeStore([makeRun({ seed_id: "dep-a", status: "completed" })]);

    const result = await resolveBaseBranch("seed-b", "/tmp/project", store);

    expect(result).toBeUndefined();
  });

  it("returns dependency branch when dep branch exists locally and dep run is completed", async () => {
    mockShowFn = vi.fn().mockResolvedValue({ dependencies: ["dep-a"] });
    (gitBranchExists as any).mockResolvedValue(true); // branch exists
    const store = makeStore([makeRun({ seed_id: "dep-a", status: "completed" })]);

    const result = await resolveBaseBranch("seed-b", "/tmp/project", store);

    expect(result).toBe("foreman/dep-a");
  });

  it("returns undefined when dep branch exists but dep run is already merged", async () => {
    mockShowFn = vi.fn().mockResolvedValue({ dependencies: ["dep-a"] });
    (gitBranchExists as any).mockResolvedValue(true); // branch exists
    // status is "merged" — dep already landed in main
    const store = makeStore([makeRun({ seed_id: "dep-a", status: "merged" })]);

    const result = await resolveBaseBranch("seed-b", "/tmp/project", store);

    expect(result).toBeUndefined();
  });

  it("returns undefined when dep run is still running (not yet completed)", async () => {
    mockShowFn = vi.fn().mockResolvedValue({ dependencies: ["dep-a"] });
    (gitBranchExists as any).mockResolvedValue(true);
    // status is "running" — dep hasn't finished yet
    const store = makeStore([makeRun({ seed_id: "dep-a", status: "running" })]);

    const result = await resolveBaseBranch("seed-b", "/tmp/project", store);

    expect(result).toBeUndefined();
  });

  it("returns undefined when dep run list is empty", async () => {
    mockShowFn = vi.fn().mockResolvedValue({ dependencies: ["dep-a"] });
    (gitBranchExists as any).mockResolvedValue(true);
    const store = makeStore([]); // no runs for dep

    const result = await resolveBaseBranch("seed-b", "/tmp/project", store);

    expect(result).toBeUndefined();
  });

  it("returns first matching dependency branch when multiple deps exist", async () => {
    mockShowFn = vi.fn().mockResolvedValue({ dependencies: ["dep-a", "dep-b"] });
    // both branches exist
    (gitBranchExists as any).mockResolvedValue(true);
    const store = {
      getRunsForSeed: vi.fn((id: string) => {
        if (id === "dep-a") return [makeRun({ seed_id: "dep-a", status: "completed" })];
        if (id === "dep-b") return [makeRun({ seed_id: "dep-b", status: "completed" })];
        return [];
      }),
    };

    const result = await resolveBaseBranch("seed-c", "/tmp/project", store);

    // Should return the first matching dep
    expect(result).toBe("foreman/dep-a");
  });

  it("returns undefined and does not throw when br fails", async () => {
    mockShowFn = vi.fn().mockRejectedValue(new Error("br not found"));
    const store = makeStore([]);

    const result = await resolveBaseBranch("seed-b", "/tmp/project", store);

    expect(result).toBeUndefined();
  });

  it("calls gitBranchExists with correct branch name", async () => {
    mockShowFn = vi.fn().mockResolvedValue({ dependencies: ["my-dep"] });
    (gitBranchExists as any).mockResolvedValue(false);
    const store = makeStore([]);

    await resolveBaseBranch("seed-x", "/tmp/project", store);

    expect(gitBranchExists).toHaveBeenCalledWith("/tmp/project", "foreman/my-dep");
  });
});
