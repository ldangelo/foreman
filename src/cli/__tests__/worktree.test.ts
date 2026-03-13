import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Worktree } from "../../lib/git.js";
import type { Run } from "../../lib/store.js";

// ── Module mocks ──────────────────────────────────────────────────────────────

vi.mock("../../lib/git.js", () => ({
  getRepoRoot: vi.fn(async () => "/tmp/project"),
  listWorktrees: vi.fn(async () => []),
  removeWorktree: vi.fn(async () => {}),
  deleteBranch: vi.fn(async () => ({ deleted: true, wasFullyMerged: true })),
}));

vi.mock("../../lib/store.js", () => {
  class MockForemanStore {
    getProjectByPath = vi.fn(() => ({ id: "proj-1", name: "test", path: "/tmp/project", status: "active", created_at: "", updated_at: "" }));
    getRunsForSeed = vi.fn((): Run[] => []);
    getRunsByStatus = vi.fn((): Run[] => []);
    close = vi.fn();
  }
  return { ForemanStore: MockForemanStore };
});

import { listWorktrees, removeWorktree, deleteBranch } from "../../lib/git.js";
import { ForemanStore } from "../../lib/store.js";
import {
  listForemanWorktrees,
  cleanWorktrees,
  type WorktreeInfo,
  type CleanResult,
} from "../commands/worktree.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeWorktree(overrides: Partial<Worktree> = {}): Worktree {
  return {
    path: "/tmp/project/.foreman-worktrees/seed-abc",
    branch: "foreman/seed-abc",
    head: "abc123",
    bare: false,
    ...overrides,
  };
}

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "seed-abc",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: "/tmp/project/.foreman-worktrees/seed-abc",
    status: "completed",
    started_at: new Date(Date.now() - 3600_000).toISOString(),
    completed_at: new Date().toISOString(),
    created_at: new Date(Date.now() - 7200_000).toISOString(),
    progress: null,
    ...overrides,
  };
}

// ── listForemanWorktrees() tests ──────────────────────────────────────────────

describe("listForemanWorktrees()", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns only foreman/* worktrees", async () => {
    const worktrees: Worktree[] = [
      makeWorktree({ path: "/tmp/project", branch: "main" }),
      makeWorktree({ path: "/tmp/project/.foreman-worktrees/seed-abc", branch: "foreman/seed-abc" }),
      makeWorktree({ path: "/tmp/project/.foreman-worktrees/seed-def", branch: "foreman/seed-def" }),
    ];
    vi.mocked(listWorktrees).mockResolvedValue(worktrees);

    const store = new ForemanStore() as any;
    const result = await listForemanWorktrees("/tmp/project", store);

    expect(result).toHaveLength(2);
    expect(result[0].branch).toBe("foreman/seed-abc");
    expect(result[1].branch).toBe("foreman/seed-def");
  });

  it("includes run status and seed ID in metadata", async () => {
    vi.mocked(listWorktrees).mockResolvedValue([
      makeWorktree({ branch: "foreman/seed-abc" }),
    ]);
    const store = new ForemanStore() as any;
    const run = makeRun({ status: "running" });
    store.getRunsForSeed.mockReturnValue([run]);

    const result = await listForemanWorktrees("/tmp/project", store);

    expect(result[0].seedId).toBe("seed-abc");
    expect(result[0].runStatus).toBe("running");
  });

  it("returns empty array when no foreman worktrees exist", async () => {
    vi.mocked(listWorktrees).mockResolvedValue([
      makeWorktree({ path: "/tmp/project", branch: "main" }),
    ]);
    const store = new ForemanStore() as any;
    const result = await listForemanWorktrees("/tmp/project", store);
    expect(result).toHaveLength(0);
  });

  it("handles worktrees with no matching run", async () => {
    vi.mocked(listWorktrees).mockResolvedValue([
      makeWorktree({ branch: "foreman/orphan-seed" }),
    ]);
    const store = new ForemanStore() as any;
    store.getRunsForSeed.mockReturnValue([]);

    const result = await listForemanWorktrees("/tmp/project", store);

    expect(result[0].seedId).toBe("orphan-seed");
    expect(result[0].runStatus).toBeNull();
  });
});

// ── cleanWorktrees() tests ────────────────────────────────────────────────────

describe("cleanWorktrees()", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("removes worktrees for completed/merged/failed runs only", async () => {
    const worktrees: WorktreeInfo[] = [
      {
        path: "/tmp/project/.foreman-worktrees/seed-done",
        branch: "foreman/seed-done",
        head: "abc",
        seedId: "seed-done",
        runStatus: "merged",
        runId: "run-1",
        createdAt: new Date().toISOString(),
      },
      {
        path: "/tmp/project/.foreman-worktrees/seed-active",
        branch: "foreman/seed-active",
        head: "def",
        seedId: "seed-active",
        runStatus: "running",
        runId: "run-2",
        createdAt: new Date().toISOString(),
      },
    ];

    const result = await cleanWorktrees("/tmp/project", worktrees, { all: false, force: false });

    expect(result.removed).toBe(1);
    expect(vi.mocked(removeWorktree)).toHaveBeenCalledTimes(1);
    expect(vi.mocked(removeWorktree)).toHaveBeenCalledWith("/tmp/project", "/tmp/project/.foreman-worktrees/seed-done");
  });

  it("with --all removes active worktrees too", async () => {
    const worktrees: WorktreeInfo[] = [
      {
        path: "/tmp/project/.foreman-worktrees/seed-done",
        branch: "foreman/seed-done",
        head: "abc",
        seedId: "seed-done",
        runStatus: "merged",
        runId: "run-1",
        createdAt: new Date().toISOString(),
      },
      {
        path: "/tmp/project/.foreman-worktrees/seed-active",
        branch: "foreman/seed-active",
        head: "def",
        seedId: "seed-active",
        runStatus: "running",
        runId: "run-2",
        createdAt: new Date().toISOString(),
      },
    ];

    const result = await cleanWorktrees("/tmp/project", worktrees, { all: true, force: false });

    expect(result.removed).toBe(2);
    expect(vi.mocked(removeWorktree)).toHaveBeenCalledTimes(2);
  });

  it("with --force uses force branch deletion", async () => {
    const worktrees: WorktreeInfo[] = [
      {
        path: "/tmp/project/.foreman-worktrees/seed-done",
        branch: "foreman/seed-done",
        head: "abc",
        seedId: "seed-done",
        runStatus: "failed",
        runId: "run-1",
        createdAt: new Date().toISOString(),
      },
    ];

    await cleanWorktrees("/tmp/project", worktrees, { all: false, force: true });

    expect(vi.mocked(deleteBranch)).toHaveBeenCalledWith(
      "/tmp/project",
      "foreman/seed-done",
      expect.objectContaining({ force: true }),
    );
  });

  it("returns summary with count", async () => {
    const worktrees: WorktreeInfo[] = [
      {
        path: "/tmp/project/.foreman-worktrees/seed-1",
        branch: "foreman/seed-1",
        head: "a",
        seedId: "seed-1",
        runStatus: "completed",
        runId: "r1",
        createdAt: new Date().toISOString(),
      },
      {
        path: "/tmp/project/.foreman-worktrees/seed-2",
        branch: "foreman/seed-2",
        head: "b",
        seedId: "seed-2",
        runStatus: "merged",
        runId: "r2",
        createdAt: new Date().toISOString(),
      },
    ];

    const result = await cleanWorktrees("/tmp/project", worktrees, { all: false, force: false });

    expect(result.removed).toBe(2);
    expect(result.errors).toHaveLength(0);
  });

  it("continues on error and collects failures", async () => {
    vi.mocked(removeWorktree).mockRejectedValueOnce(new Error("locked"));

    const worktrees: WorktreeInfo[] = [
      {
        path: "/tmp/project/.foreman-worktrees/seed-1",
        branch: "foreman/seed-1",
        head: "a",
        seedId: "seed-1",
        runStatus: "failed",
        runId: "r1",
        createdAt: new Date().toISOString(),
      },
    ];

    const result = await cleanWorktrees("/tmp/project", worktrees, { all: false, force: false });

    expect(result.removed).toBe(0);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toContain("locked");
  });
});
