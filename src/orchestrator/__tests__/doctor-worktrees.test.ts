import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Run } from "../../lib/store.js";

// ── Module mocks ─────────────────────────────────────────────────────────────
// Must be declared before any imports that use them (vitest hoists vi.mock calls).

vi.mock("node:child_process", () => ({
  // Stub execFile so promisify(execFile)(...) resolves immediately.
  // promisify passes callback as the last argument; we call it with no error.
  execFile: vi.fn((...args: unknown[]) => {
    const cb = args[args.length - 1];
    if (typeof cb === "function") cb(null, "", "");
  }),
}));

const {
  mockListWorkspaces,
  mockRemoveWorkspace,
  mockBranchExistsOnRemote,
  mockDetectDefaultBranch,
  mockCreateVcsBackend,
} = vi.hoisted(() => {
  const mockListWorkspaces = vi.fn();
  const mockRemoveWorkspace = vi.fn();
  const mockBranchExistsOnRemote = vi.fn().mockResolvedValue(false);
  const mockDetectDefaultBranch = vi.fn().mockResolvedValue("main");
  const mockCreateVcsBackend = vi.fn().mockResolvedValue({
    name: "git",
    listWorkspaces: mockListWorkspaces,
    removeWorkspace: mockRemoveWorkspace,
    branchExistsOnRemote: mockBranchExistsOnRemote,
    detectDefaultBranch: mockDetectDefaultBranch,
  });
  return { mockListWorkspaces, mockRemoveWorkspace, mockBranchExistsOnRemote, mockDetectDefaultBranch, mockCreateVcsBackend };
});

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: mockCreateVcsBackend,
  },
}));

import { Doctor } from "../doctor.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "seed-abc",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: "/tmp/worktrees/seed-abc",
    status: "running",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,    ...overrides,
  };
}

function makeWorktree(seedId: string, path = `/tmp/worktrees/${seedId}`) {
  return {
    path,
    branch: `foreman/${seedId}`,
    head: "abc1234",
    bare: false,
  };
}

function makeMocks(projectPath = "/tmp/project") {
  const store = {
    getProjectByPath: vi.fn(() => null as any),
    getRunsByStatus: vi.fn(() => [] as Run[]),
    getRunsForSeed: vi.fn((_seedId: string) => [] as Run[]),
    getActiveRuns: vi.fn(() => [] as Run[]),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
  };
  const doctor = new Doctor(store as any, projectPath);
  return { store, doctor };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("Doctor.checkOrphanedWorktrees", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns pass when no foreman worktrees exist", async () => {
    const { doctor } = makeMocks();
    mockListWorkspaces.mockResolvedValue([]);

    const results = await doctor.checkOrphanedWorktrees();

    expect(results).toHaveLength(1);
    expect(results[0].status).toBe("pass");
    expect(results[0].message).toContain("No foreman worktrees found");
  });

  it("returns pass for worktrees with active (running) runs", async () => {
    const { store, doctor } = makeMocks();
    const seedId = "seed-abc";
    mockListWorkspaces.mockResolvedValue([makeWorktree(seedId)]);
    store.getRunsForSeed.mockReturnValue([
      // Use the test process PID so isProcessAlive() returns true
      makeRun({ seed_id: seedId, status: "running", worktree_path: `/tmp/worktrees/${seedId}`, session_key: `pid-${process.pid}` }),
    ]);

    const results = await doctor.checkOrphanedWorktrees();

    expect(results).toHaveLength(1);
    expect(results[0].status).toBe("pass");
    expect(results[0].message).toContain("Active run");
    expect(mockRemoveWorkspace).not.toHaveBeenCalled();
  });

  it("returns pass for worktrees with active (pending) runs", async () => {
    const { store, doctor } = makeMocks();
    const seedId = "seed-abc";
    mockListWorkspaces.mockResolvedValue([makeWorktree(seedId)]);
    store.getRunsForSeed.mockReturnValue([
      makeRun({ seed_id: seedId, status: "pending", worktree_path: `/tmp/worktrees/${seedId}` }),
    ]);

    const results = await doctor.checkOrphanedWorktrees();

    expect(results[0].status).toBe("pass");
    expect(mockRemoveWorkspace).not.toHaveBeenCalled();
  });

  it("warns for completed (needs merge) run — does NOT remove worktree", async () => {
    const { store, doctor } = makeMocks();
    const seedId = "seed-abc";
    mockListWorkspaces.mockResolvedValue([makeWorktree(seedId)]);
    store.getRunsForSeed.mockReturnValue([
      makeRun({ seed_id: seedId, status: "completed" }),
    ]);

    const results = await doctor.checkOrphanedWorktrees({ fix: true });

    expect(results[0].status).toBe("warn");
    expect(results[0].message).toContain("foreman merge");
    expect(mockRemoveWorkspace).not.toHaveBeenCalled();
  });

  it("warns for merged run and removes worktree when fix=true", async () => {
    const { store, doctor } = makeMocks();
    const seedId = "seed-abc";
    mockListWorkspaces.mockResolvedValue([makeWorktree(seedId)]);
    mockRemoveWorkspace.mockResolvedValue(undefined);
    store.getRunsForSeed.mockReturnValue([
      makeRun({ seed_id: seedId, status: "merged" }),
    ]);

    const results = await doctor.checkOrphanedWorktrees({ fix: true });

    expect(results[0].status).toBe("fixed");
    expect(mockRemoveWorkspace).toHaveBeenCalled();
  });

  it("shows dry-run message for merged run without removing", async () => {
    const { store, doctor } = makeMocks();
    const seedId = "seed-abc";
    mockListWorkspaces.mockResolvedValue([makeWorktree(seedId)]);
    store.getRunsForSeed.mockReturnValue([
      makeRun({ seed_id: seedId, status: "merged" }),
    ]);

    const results = await doctor.checkOrphanedWorktrees({ dryRun: true });

    expect(results[0].status).toBe("warn");
    expect(results[0].message).toContain("dry-run");
    expect(mockRemoveWorkspace).not.toHaveBeenCalled();
  });

  // ── Bug fix: failed/stuck/conflict/test-failed should NOT be removed ──────

  it("preserves worktree for failed run — does NOT remove", async () => {
    const { store, doctor } = makeMocks();
    const seedId = "seed-abc";
    mockListWorkspaces.mockResolvedValue([makeWorktree(seedId)]);
    store.getRunsForSeed.mockReturnValue([
      makeRun({ seed_id: seedId, status: "failed" }),
    ]);

    const results = await doctor.checkOrphanedWorktrees({ fix: true });

    expect(results[0].status).toBe("warn");
    expect(results[0].message).toContain("failed");
    expect(results[0].message).toContain("foreman reset");
    expect(mockRemoveWorkspace).not.toHaveBeenCalled();
  });

  it("preserves worktree for stuck run — does NOT remove", async () => {
    const { store, doctor } = makeMocks();
    const seedId = "seed-abc";
    mockListWorkspaces.mockResolvedValue([makeWorktree(seedId)]);
    store.getRunsForSeed.mockReturnValue([
      makeRun({ seed_id: seedId, status: "stuck" }),
    ]);

    const results = await doctor.checkOrphanedWorktrees({ fix: true });

    expect(results[0].status).toBe("warn");
    expect(results[0].message).toContain("stuck");
    expect(results[0].message).toContain("foreman reset");
    expect(mockRemoveWorkspace).not.toHaveBeenCalled();
  });

  it("preserves worktree for conflict run — does NOT remove", async () => {
    const { store, doctor } = makeMocks();
    const seedId = "seed-abc";
    mockListWorkspaces.mockResolvedValue([makeWorktree(seedId)]);
    store.getRunsForSeed.mockReturnValue([
      makeRun({ seed_id: seedId, status: "conflict" }),
    ]);

    const results = await doctor.checkOrphanedWorktrees({ fix: true });

    expect(results[0].status).toBe("warn");
    expect(results[0].message).toContain("conflict");
    expect(mockRemoveWorkspace).not.toHaveBeenCalled();
  });

  it("preserves worktree for test-failed run — does NOT remove", async () => {
    const { store, doctor } = makeMocks();
    const seedId = "seed-abc";
    mockListWorkspaces.mockResolvedValue([makeWorktree(seedId)]);
    store.getRunsForSeed.mockReturnValue([
      makeRun({ seed_id: seedId, status: "test-failed" }),
    ]);

    const results = await doctor.checkOrphanedWorktrees({ fix: true });

    expect(results[0].status).toBe("warn");
    expect(results[0].message).toContain("test-failed");
    expect(results[0].message).toContain("foreman reset");
    expect(mockRemoveWorkspace).not.toHaveBeenCalled();
  });

  it("preserves worktree when seed has mixed runs including a failed one", async () => {
    // Even if there's a merged run, a failed run should prevent worktree removal
    // The merged run check takes priority, so let's test with only failable runs
    const { store, doctor } = makeMocks();
    const seedId = "seed-abc";
    mockListWorkspaces.mockResolvedValue([makeWorktree(seedId)]);
    store.getRunsForSeed.mockReturnValue([
      makeRun({ id: "run-1", seed_id: seedId, status: "failed" }),
      makeRun({ id: "run-2", seed_id: seedId, status: "failed" }),
    ]);

    const results = await doctor.checkOrphanedWorktrees({ fix: true });

    expect(results[0].status).toBe("warn");
    expect(mockRemoveWorkspace).not.toHaveBeenCalled();
  });

  it("removes truly orphaned worktree (no runs) when fix=true", async () => {
    const { store, doctor } = makeMocks();
    const seedId = "seed-orphan";
    mockListWorkspaces.mockResolvedValue([makeWorktree(seedId)]);
    mockRemoveWorkspace.mockResolvedValue(undefined);
    store.getRunsForSeed.mockReturnValue([]); // no runs at all

    const results = await doctor.checkOrphanedWorktrees({ fix: true });

    expect(results[0].status).toBe("fixed");
    expect(results[0].message).toContain("Orphaned");
    expect(mockRemoveWorkspace).toHaveBeenCalled();
  });

  it("shows dry-run message for truly orphaned worktree without removing", async () => {
    const { store, doctor } = makeMocks();
    const seedId = "seed-orphan";
    mockListWorkspaces.mockResolvedValue([makeWorktree(seedId)]);
    store.getRunsForSeed.mockReturnValue([]);

    const results = await doctor.checkOrphanedWorktrees({ dryRun: true });

    expect(results[0].status).toBe("warn");
    expect(results[0].message).toContain("dry-run");
    expect(mockRemoveWorkspace).not.toHaveBeenCalled();
  });

  it("warns for orphaned worktree without fix flag", async () => {
    const { store, doctor } = makeMocks();
    const seedId = "seed-orphan";
    mockListWorkspaces.mockResolvedValue([makeWorktree(seedId)]);
    store.getRunsForSeed.mockReturnValue([]);

    const results = await doctor.checkOrphanedWorktrees();

    expect(results[0].status).toBe("warn");
    expect(results[0].message).toContain("--fix");
  });

  // ── SDK-based run tests ───────────────────────────────────────────────────

  it("returns pass for SDK-based running run (no PID in session_key)", async () => {
    const { store, doctor } = makeMocks();
    const seedId = "seed-abc";
    mockListWorkspaces.mockResolvedValue([makeWorktree(seedId)]);
    store.getRunsForSeed.mockReturnValue([
      makeRun({
        seed_id: seedId,
        status: "running",
        worktree_path: `/tmp/worktrees/${seedId}`,
        session_key: "foreman:sdk:claude-sonnet-4-6:seed-abc",
      }),
    ]);

    const results = await doctor.checkOrphanedWorktrees();

    expect(results).toHaveLength(1);
    expect(results[0].status).toBe("pass");
    expect(results[0].message).toContain("SDK-based worker");
    expect(mockRemoveWorkspace).not.toHaveBeenCalled();
  });

  it("returns pass for SDK-based running run with session suffix", async () => {
    const { store, doctor } = makeMocks();
    const seedId = "seed-abc";
    mockListWorkspaces.mockResolvedValue([makeWorktree(seedId)]);
    store.getRunsForSeed.mockReturnValue([
      makeRun({
        seed_id: seedId,
        status: "running",
        worktree_path: `/tmp/worktrees/${seedId}`,
        session_key: "foreman:sdk:claude-opus-4-6:seed-abc:session-xyz",
      }),
    ]);

    const results = await doctor.checkOrphanedWorktrees();

    expect(results[0].status).toBe("pass");
    expect(results[0].message).toContain("SDK-based worker");
    expect(mockRemoveWorkspace).not.toHaveBeenCalled();
  });

  it("never marks SDK-based running run as zombie even when fix=true", async () => {
    const { store, doctor } = makeMocks();
    const seedId = "seed-abc";
    mockListWorkspaces.mockResolvedValue([makeWorktree(seedId)]);
    store.getRunsForSeed.mockReturnValue([
      makeRun({
        seed_id: seedId,
        status: "running",
        worktree_path: `/tmp/worktrees/${seedId}`,
        session_key: "foreman:sdk:claude-sonnet-4-6:seed-abc",
      }),
    ]);

    const results = await doctor.checkOrphanedWorktrees({ fix: true });

    expect(results[0].status).toBe("pass");
    expect(results[0].message).not.toContain("Zombie");
    expect(mockRemoveWorkspace).not.toHaveBeenCalled();
  });

  it("handles mixed worktrees: SDK run (pass), traditional zombie (warn), orphan (fixed)", async () => {
    const { store, doctor } = makeMocks();
    mockListWorkspaces.mockResolvedValue([
      makeWorktree("seed-sdk"),
      makeWorktree("seed-zombie"),
      makeWorktree("seed-orphan"),
    ]);
    mockRemoveWorkspace.mockResolvedValue(undefined);

    store.getRunsForSeed.mockImplementation((seedId: string) => {
      if (seedId === "seed-sdk") {
        return [
          makeRun({
            seed_id: seedId,
            status: "running",
            worktree_path: `/tmp/worktrees/${seedId}`,
            session_key: "foreman:sdk:claude-sonnet-4-6:seed-sdk",
          }),
        ];
      }
      if (seedId === "seed-zombie") {
        // Traditional run with a dead PID (pid 99999999 is unlikely to be alive)
        return [
          makeRun({
            seed_id: seedId,
            status: "running",
            worktree_path: `/tmp/worktrees/${seedId}`,
            session_key: "pid-99999999",
          }),
        ];
      }
      return []; // seed-orphan has no runs
    });

    const results = await doctor.checkOrphanedWorktrees({ fix: true });

    expect(results).toHaveLength(3);

    const sdkResult = results.find((r) => r.name === "worktree: seed-sdk");
    const zombieResult = results.find((r) => r.name === "worktree: seed-zombie");
    const orphanResult = results.find((r) => r.name === "worktree: seed-orphan");

    expect(sdkResult?.status).toBe("pass");
    expect(sdkResult?.message).toContain("SDK-based worker");

    expect(zombieResult?.status).toBe("warn");
    expect(zombieResult?.message).toContain("Zombie");

    expect(orphanResult?.status).toBe("fixed");

    // Only the orphaned worktree should be removed (zombie stays, SDK is alive)
    expect(mockRemoveWorkspace).toHaveBeenCalledTimes(1);
    expect(mockRemoveWorkspace).toHaveBeenCalledWith(
      expect.any(String),
      `/tmp/worktrees/seed-orphan`,
    );
  });

  it("returns warn when listWorktrees throws", async () => {
    const { doctor } = makeMocks();
    mockListWorkspaces.mockRejectedValue(new Error("git error"));

    const results = await doctor.checkOrphanedWorktrees();

    expect(results).toHaveLength(1);
    expect(results[0].status).toBe("warn");
    expect(results[0].message).toContain("Could not list worktrees");
  });

  it("handles multiple worktrees with different statuses", async () => {
    const { store, doctor } = makeMocks();
    mockListWorkspaces.mockResolvedValue([
      makeWorktree("seed-active"),
      makeWorktree("seed-failed"),
      makeWorktree("seed-orphan"),
    ]);
    mockRemoveWorkspace.mockResolvedValue(undefined);

    store.getRunsForSeed.mockImplementation((seedId: string) => {
      if (seedId === "seed-active") {
        return [makeRun({ seed_id: seedId, status: "running", worktree_path: `/tmp/worktrees/${seedId}`, session_key: `pid-${process.pid}` })];
      }
      if (seedId === "seed-failed") {
        return [makeRun({ seed_id: seedId, status: "failed" })];
      }
      return []; // seed-orphan has no runs
    });

    const results = await doctor.checkOrphanedWorktrees({ fix: true });

    expect(results).toHaveLength(3);

    const activeResult = results.find((r) => r.name === "worktree: seed-active");
    const failedResult = results.find((r) => r.name === "worktree: seed-failed");
    const orphanResult = results.find((r) => r.name === "worktree: seed-orphan");

    expect(activeResult?.status).toBe("pass");
    expect(failedResult?.status).toBe("warn");
    expect(failedResult?.message).toContain("failed");
    expect(orphanResult?.status).toBe("fixed");

    // Only the orphaned worktree should be removed
    expect(mockRemoveWorkspace).toHaveBeenCalledTimes(1);
    expect(mockRemoveWorkspace).toHaveBeenCalledWith(
      expect.any(String),
      `/tmp/worktrees/seed-orphan`,
    );
  });
});
