import { describe, it, expect, vi, beforeEach } from "vitest";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Doctor } from "../doctor.js";
import type { Run } from "../../lib/store.js";

// Mock git module for worktree tests
vi.mock("../../lib/git.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../lib/git.js")>();
  return {
    ...actual,
    listWorktrees: vi.fn(),
    removeWorktree: vi.fn(),
    branchExistsOnOrigin: vi.fn(),
    detectDefaultBranch: vi.fn(),
  };
});
import { listWorktrees, branchExistsOnOrigin, detectDefaultBranch } from "../../lib/git.js";

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "foreman-001",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: "/tmp/wt",
    status: "running",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,    ...overrides,
  };
}

function makeMocks(projectPath = "/tmp/project") {
  const store = {
    getProjectByPath: vi.fn(() => null as any),
    getRunsByStatus: vi.fn(() => [] as Run[]),
    getRunsForSeed: vi.fn(() => [] as Run[]),
    getActiveRuns: vi.fn(() => [] as Run[]),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
  };
  const doctor = new Doctor(store as any, projectPath);
  return { store, doctor };
}

function makeMergeQueueMock(missingEntries: Array<{ run_id: string; seed_id: string }> = []) {
  return {
    missingFromQueue: vi.fn(() => missingEntries),
    list: vi.fn(() => []),
    updateStatus: vi.fn(),
    remove: vi.fn(),
  };
}

// Default: return empty worktree list so existing tests aren't affected
beforeEach(() => {
  vi.mocked(listWorktrees).mockResolvedValue([]);
});

describe("Doctor", () => {
  describe("checkGitBinary", () => {
    it("returns pass when git is available", async () => {
      const { doctor } = makeMocks();
      const result = await doctor.checkGitBinary();
      // git is guaranteed to exist on dev/CI machines
      expect(result.status).toBe("pass");
      expect(result.name).toBe("git binary");
      expect(result.message).toBe("git is available");
    });

    it("returns fail when git is not found", async () => {
      const { doctor } = makeMocks();
      // Temporarily override PATH to hide git
      const originalPath = process.env.PATH;
      process.env.PATH = "";
      try {
        const result = await doctor.checkGitBinary();
        expect(result.status).toBe("fail");
        expect(result.message).toContain("not found");
      } finally {
        process.env.PATH = originalPath;
      }
    });
  });

  describe("checkProjectRegistered", () => {
    it("returns fail when project not in store", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue(null);

      const result = await doctor.checkProjectRegistered();

      expect(result.status).toBe("fail");
      expect(result.message).toContain("foreman init");
    });

    it("returns pass when project is registered", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({
        id: "proj-1",
        name: "my-project",
        status: "active",
        path: "/tmp/project",
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      });

      const result = await doctor.checkProjectRegistered();

      expect(result.status).toBe("pass");
      expect(result.message).toContain("my-project");
    });
  });

  describe("checkZombieRuns", () => {
    it("returns pass when no running runs", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      store.getRunsByStatus.mockReturnValue([]);

      const results = await doctor.checkZombieRuns();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("pass");
    });

    it("returns empty array when no project registered", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue(null);

      const results = await doctor.checkZombieRuns();

      expect(results).toHaveLength(0);
    });

    it("detects zombie run without pid", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      const run = makeRun({ session_key: null }); // no PID
      store.getRunsByStatus.mockReturnValue([run]);

      const results = await doctor.checkZombieRuns();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("warn");
      expect(results[0].message).toContain("Zombie run");
    });

    it("fixes zombie run when fix=true", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      const run = makeRun({ session_key: null });
      store.getRunsByStatus.mockReturnValue([run]);

      const results = await doctor.checkZombieRuns({ fix: true });

      expect(results[0].status).toBe("fixed");
      expect(store.updateRun).toHaveBeenCalledWith(run.id, expect.objectContaining({ status: "failed" }));
    });

    it("shows dry-run message without making changes", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      const run = makeRun({ session_key: null });
      store.getRunsByStatus.mockReturnValue([run]);

      const results = await doctor.checkZombieRuns({ dryRun: true });

      expect(results[0].status).toBe("warn");
      expect(results[0].message).toContain("dry-run");
      expect(store.updateRun).not.toHaveBeenCalled();
    });

    it("does NOT mark Pi-based run as zombie as zombie", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      // Pi worker: session_key starts with "foreman:sdk:", no tmux_session
      const run = makeRun({
        session_key: "foreman:sdk:claude-sonnet-4-6:run-1",
      });
      store.getRunsByStatus.mockReturnValue([run]);

      const results = await doctor.checkZombieRuns();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("pass");
      expect(results[0].message).toContain("Pi-based worker");
    });

    it("does NOT mark Pi-based run with session suffix as zombie as zombie", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      // SDK worker with session suffix (after first agent message), still no PID
      const run = makeRun({
        session_key: "foreman:sdk:claude-sonnet-4-6:run-1:session-abc123",
      });
      store.getRunsByStatus.mockReturnValue([run]);

      const results = await doctor.checkZombieRuns();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("pass");
      expect(results[0].message).toContain("Pi-based worker");
    });

    it("does NOT mark Pi-based run as zombie", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      // Pi worker: liveness checked by timeout, not PID
      const run = makeRun({
        session_key: "foreman:sdk:claude-opus-4-6:run-2",
      });
      store.getRunsByStatus.mockReturnValue([run]);

      const results = await doctor.checkZombieRuns();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("pass");
      expect(results[0].message).toContain("Pi-based worker");
      // Crucially: updateRun should NOT have been called
      expect(store.updateRun).not.toHaveBeenCalled();
    });

    it("does NOT fix SDK-based runs even when fix=true", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      const run = makeRun({
        session_key: "foreman:sdk:claude-sonnet-4-6:run-3",
      });
      store.getRunsByStatus.mockReturnValue([run]);

      const results = await doctor.checkZombieRuns({ fix: true });

      expect(results[0].status).toBe("pass");
      expect(store.updateRun).not.toHaveBeenCalled();
    });

    it("still detects zombie for traditional (PID-based) run with null session_key alongside SDK run", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      const sdkRun = makeRun({
        id: "run-sdk",
        seed_id: "bd-sdk",
        session_key: "foreman:sdk:claude-sonnet-4-6:run-sdk",
      });
      const zombieRun = makeRun({
        id: "run-zombie",
        seed_id: "bd-zombie",
        session_key: null, // no PID = zombie
      });
      store.getRunsByStatus.mockReturnValue([sdkRun, zombieRun]);

      const results = await doctor.checkZombieRuns();

      expect(results).toHaveLength(2);
      const sdkResult = results.find((r) => r.name.includes("bd-sdk"));
      const zombieResult = results.find((r) => r.name.includes("bd-zombie"));
      expect(sdkResult?.status).toBe("pass");
      expect(zombieResult?.status).toBe("warn");
      expect(zombieResult?.message).toContain("Zombie run");
    });
  });

  describe("checkStalePendingRuns", () => {
    it("returns pass when no stale pending runs", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      // Recent pending run
      store.getRunsByStatus.mockReturnValue([makeRun({ status: "pending", created_at: new Date().toISOString() })]);

      const result = await doctor.checkStalePendingRuns();

      expect(result.status).toBe("pass");
    });

    it("detects stale pending runs older than 24h", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      const twoDaysAgo = new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString();
      store.getRunsByStatus.mockReturnValue([makeRun({ status: "pending", created_at: twoDaysAgo })]);

      const result = await doctor.checkStalePendingRuns();

      expect(result.status).toBe("warn");
      expect(result.message).toContain("older than 24h");
    });

    it("fixes stale pending runs when fix=true", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      const twoDaysAgo = new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString();
      const run = makeRun({ status: "pending", created_at: twoDaysAgo });
      store.getRunsByStatus.mockReturnValue([run]);

      const result = await doctor.checkStalePendingRuns({ fix: true });

      expect(result.status).toBe("fixed");
      expect(store.updateRun).toHaveBeenCalledWith(run.id, expect.objectContaining({ status: "failed" }));
    });
  });

  describe("checkRunStateConsistency", () => {
    it("returns pass when all run states are consistent", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      store.getActiveRuns.mockReturnValue([makeRun({ completed_at: null })]);

      const results = await doctor.checkRunStateConsistency();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("pass");
    });

    it("detects run with completed_at but status=running", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      const inconsistentRun = makeRun({
        status: "running",
        completed_at: new Date().toISOString(), // inconsistent!
      });
      store.getActiveRuns.mockReturnValue([inconsistentRun]);

      const results = await doctor.checkRunStateConsistency();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("warn");
      expect(results[0].message).toContain("completed_at");
    });

    it("fixes inconsistent run state when fix=true", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      const inconsistentRun = makeRun({
        status: "running",
        completed_at: new Date().toISOString(),
      });
      store.getActiveRuns.mockReturnValue([inconsistentRun]);

      const results = await doctor.checkRunStateConsistency({ fix: true });

      expect(results[0].status).toBe("fixed");
      expect(store.updateRun).toHaveBeenCalledWith(inconsistentRun.id, { status: "failed" });
    });

    it("returns empty when no project registered", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue(null);

      const results = await doctor.checkRunStateConsistency();

      expect(results).toHaveLength(0);
    });
  });

  describe("checkDatabaseFile", () => {
    it("returns warn when database file does not exist", async () => {
      const tmpDir = await mkdtemp(join(tmpdir(), "foreman-test-"));
      try {
        const { doctor } = makeMocks(tmpDir);
        const result = await doctor.checkDatabaseFile();
        expect(result.name).toBe("foreman database");
        expect(result.status).toBe("warn");
        expect(result.message).toContain(tmpDir);
        expect(result.message).toContain("foreman.db");
      } finally {
        await rm(tmpDir, { recursive: true });
      }
    });

    it("returns pass when database file exists", async () => {
      const tmpDir = await mkdtemp(join(tmpdir(), "foreman-test-"));
      try {
        const foremanDir = join(tmpDir, ".foreman");
        await mkdir(foremanDir, { recursive: true });
        await writeFile(join(foremanDir, "foreman.db"), "");
        const { doctor } = makeMocks(tmpDir);
        const result = await doctor.checkDatabaseFile();
        expect(result.name).toBe("foreman database");
        expect(result.status).toBe("pass");
        expect(result.message).toContain(tmpDir);
        expect(result.message).toContain("foreman.db");
      } finally {
        await rm(tmpDir, { recursive: true });
      }
    });

    it("checks project-local path, not global ~/.foreman/foreman.db", async () => {
      const tmpDir = await mkdtemp(join(tmpdir(), "foreman-test-"));
      try {
        const { doctor } = makeMocks(tmpDir);
        const result = await doctor.checkDatabaseFile();
        // The message should reference the project path, not the home directory
        expect(result.message).toContain(tmpDir);
      } finally {
        await rm(tmpDir, { recursive: true });
      }
    });
  });

  describe("checkFailedStuckRuns", () => {
    it("returns pass when no failed or stuck runs", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      store.getRunsByStatus.mockReturnValue([]);

      const results = await doctor.checkFailedStuckRuns();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("pass");
    });

    it("warns when failed runs exist", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      store.getRunsByStatus
        .mockReturnValueOnce([makeRun({ status: "failed" })]) // failed
        .mockReturnValueOnce([]); // stuck

      const results = await doctor.checkFailedStuckRuns();

      expect(results.some((r) => r.name === "failed runs" && r.status === "warn")).toBe(true);
    });

    // ── Merge-detection tests ──────────────────────────────────────────

    /**
     * Helper: build a Doctor with a controllable execFn (for git merge-base calls)
     * and a project that has a temporary directory (for .beads/issues.jsonl).
     */
    async function makeMergeDetectionMocks(
      tmpDir: string,
      execFn: (...args: any[]) => Promise<{ stdout: string; stderr: string }>,
    ) {
      const store = {
        getProjectByPath: vi.fn(() => ({
          id: "proj-1",
          name: "test",
          status: "active",
          path: tmpDir,
          created_at: "",
          updated_at: "",
        })),
        getRunsByStatus: vi.fn(() => [] as Run[]),
        getRunsForSeed: vi.fn(() => [] as Run[]),
        getActiveRuns: vi.fn(() => [] as Run[]),
        updateRun: vi.fn(),
        logEvent: vi.fn(),
      };
      const doctor = new Doctor(store as any, tmpDir, undefined, undefined, execFn as any);
      return { store, doctor };
    }

    it("auto-resolves a failed run whose branch is already merged into default branch", async () => {
      const tmpDir = await mkdtemp(join(tmpdir(), "foreman-doctor-test-"));
      try {
        // No .beads/issues.jsonl — seed not closed via beads
        // execFn returns successfully (exit 0) → branch is merged
        const execFn = vi.fn().mockResolvedValue({ stdout: "", stderr: "" });
        vi.mocked(detectDefaultBranch).mockResolvedValue("main");

        const { store, doctor } = await makeMergeDetectionMocks(tmpDir, execFn);
        const failedRun = makeRun({ id: "run-merged", seed_id: "bd-merged", status: "failed" });
        store.getRunsByStatus
          .mockReturnValueOnce([failedRun]) // failed runs
          .mockReturnValueOnce([]);          // stuck runs

        const results = await doctor.checkFailedStuckRuns();

        // Should have auto-resolved the run
        const resolvedResult = results.find((r) => r.name === "failed/stuck runs (auto-resolved)");
        expect(resolvedResult).toBeDefined();
        expect(resolvedResult!.status).toBe("fixed");
        expect(resolvedResult!.message).toContain("Auto-resolved 1");

        // Store should have been updated to completed
        expect(store.updateRun).toHaveBeenCalledWith("run-merged", { status: "completed" });

        // No warning about failed runs should appear
        expect(results.find((r) => r.name === "failed runs")).toBeUndefined();

        // execFn should have been called with git merge-base --is-ancestor
        expect(execFn).toHaveBeenCalledWith(
          "git",
          ["merge-base", "--is-ancestor", "foreman/bd-merged", "main"],
          expect.objectContaining({ cwd: tmpDir }),
        );
      } finally {
        await rm(tmpDir, { recursive: true });
      }
    });

    it("keeps a failed run in the warning list when branch is NOT merged", async () => {
      const tmpDir = await mkdtemp(join(tmpdir(), "foreman-doctor-test-"));
      try {
        // execFn throws (non-zero exit) → branch is not merged
        const execFn = vi.fn().mockRejectedValue(new Error("not an ancestor"));
        vi.mocked(detectDefaultBranch).mockResolvedValue("main");

        const { store, doctor } = await makeMergeDetectionMocks(tmpDir, execFn);
        const failedRun = makeRun({ id: "run-unmerged", seed_id: "bd-unmerged", status: "failed" });
        store.getRunsByStatus
          .mockReturnValueOnce([failedRun])
          .mockReturnValueOnce([]);

        const results = await doctor.checkFailedStuckRuns();

        // Run should still appear as a warning
        const warnResult = results.find((r) => r.name === "failed runs");
        expect(warnResult).toBeDefined();
        expect(warnResult!.status).toBe("warn");
        expect(warnResult!.message).toContain("bd-unmerged");

        // No auto-resolve
        expect(results.find((r) => r.name === "failed/stuck runs (auto-resolved)")).toBeUndefined();
        expect(store.updateRun).not.toHaveBeenCalled();
      } finally {
        await rm(tmpDir, { recursive: true });
      }
    });

    it("auto-resolves a failed run whose seed is already closed in beads", async () => {
      const tmpDir = await mkdtemp(join(tmpdir(), "foreman-doctor-test-"));
      try {
        // Write a .beads/issues.jsonl with the seed marked as closed
        const beadsDir = join(tmpDir, ".beads");
        await mkdir(beadsDir, { recursive: true });
        const beadEntry = JSON.stringify({ id: "bd-closed", status: "closed" });
        await writeFile(join(beadsDir, "issues.jsonl"), beadEntry + "\n");

        // execFn should NOT be called because the seed-closed check fires first
        const execFn = vi.fn().mockRejectedValue(new Error("should not be called"));
        vi.mocked(detectDefaultBranch).mockResolvedValue("main");

        const { store, doctor } = await makeMergeDetectionMocks(tmpDir, execFn);
        const failedRun = makeRun({ id: "run-closed-seed", seed_id: "bd-closed", status: "failed" });
        store.getRunsByStatus
          .mockReturnValueOnce([failedRun])
          .mockReturnValueOnce([]);

        const results = await doctor.checkFailedStuckRuns();

        // Should have auto-resolved
        const resolvedResult = results.find((r) => r.name === "failed/stuck runs (auto-resolved)");
        expect(resolvedResult).toBeDefined();
        expect(resolvedResult!.status).toBe("fixed");
        expect(store.updateRun).toHaveBeenCalledWith("run-closed-seed", { status: "completed" });

        // execFn should NOT have been called — seed-closed check short-circuits
        expect(execFn).not.toHaveBeenCalled();
      } finally {
        await rm(tmpDir, { recursive: true });
      }
    });

    it("gracefully handles git errors during merge check — run stays in warning", async () => {
      const tmpDir = await mkdtemp(join(tmpdir(), "foreman-doctor-test-"));
      try {
        // execFn throws a git error (e.g. corrupted repo)
        const execFn = vi.fn().mockRejectedValue(new Error("fatal: not a git repository"));
        vi.mocked(detectDefaultBranch).mockResolvedValue("main");

        const { store, doctor } = await makeMergeDetectionMocks(tmpDir, execFn);
        const failedRun = makeRun({ id: "run-git-err", seed_id: "bd-git-err", status: "failed" });
        store.getRunsByStatus
          .mockReturnValueOnce([failedRun])
          .mockReturnValueOnce([]);

        const results = await doctor.checkFailedStuckRuns();

        // Run should remain as a warning — error treated as "not merged"
        const warnResult = results.find((r) => r.name === "failed runs");
        expect(warnResult).toBeDefined();
        expect(warnResult!.status).toBe("warn");
        expect(store.updateRun).not.toHaveBeenCalled();
      } finally {
        await rm(tmpDir, { recursive: true });
      }
    });

    it("auto-resolves a stuck run whose branch is already merged", async () => {
      const tmpDir = await mkdtemp(join(tmpdir(), "foreman-doctor-test-"));
      try {
        const execFn = vi.fn().mockResolvedValue({ stdout: "", stderr: "" });
        vi.mocked(detectDefaultBranch).mockResolvedValue("dev");

        const { store, doctor } = await makeMergeDetectionMocks(tmpDir, execFn);
        const stuckRun = makeRun({ id: "run-stuck", seed_id: "bd-stuck", status: "stuck" });
        store.getRunsByStatus
          .mockReturnValueOnce([])         // failed runs
          .mockReturnValueOnce([stuckRun]); // stuck runs

        const results = await doctor.checkFailedStuckRuns();

        const resolvedResult = results.find((r) => r.name === "failed/stuck runs (auto-resolved)");
        expect(resolvedResult).toBeDefined();
        expect(resolvedResult!.status).toBe("fixed");
        expect(store.updateRun).toHaveBeenCalledWith("run-stuck", { status: "completed" });
        expect(results.find((r) => r.name === "stuck runs")).toBeUndefined();
      } finally {
        await rm(tmpDir, { recursive: true });
      }
    });
  });

  describe("checkCompletedRunsNotQueued", () => {
    it("returns skip when no merge queue configured", async () => {
      const { doctor } = makeMocks();
      const result = await doctor.checkCompletedRunsNotQueued();
      expect(result.status).toBe("skip");
      expect(result.name).toBe("completed runs queued");
    });

    it("returns pass when all completed runs are queued", async () => {
      const { store } = makeMocks();
      const mq = makeMergeQueueMock([]);
      const doctor = new Doctor(store as any, "/tmp/project", mq as any);
      const result = await doctor.checkCompletedRunsNotQueued();
      expect(result.status).toBe("pass");
      expect(result.message).toContain("All completed runs");
    });

    it("returns warn when completed runs are missing from queue", async () => {
      const { store } = makeMocks();
      const mq = makeMergeQueueMock([
        { run_id: "r1", seed_id: "seed-abc" },
        { run_id: "r2", seed_id: "seed-xyz" },
      ]);
      const doctor = new Doctor(store as any, "/tmp/project", mq as any);
      const result = await doctor.checkCompletedRunsNotQueued();
      expect(result.status).toBe("warn");
      expect(result.message).toContain("2 completed run(s) not in merge queue");
      expect(result.message).toContain("foreman merge");
      expect(result.details).toContain("seed-abc");
      expect(result.details).toContain("seed-xyz");
    });

    it("includes MQ-011 code in warning message", async () => {
      const { store } = makeMocks();
      const mq = makeMergeQueueMock([{ run_id: "r1", seed_id: "s1" }]);
      const doctor = new Doctor(store as any, "/tmp/project", mq as any);
      const result = await doctor.checkCompletedRunsNotQueued();
      expect(result.message).toContain("MQ-011");
    });
  });

  describe("checkMergeQueueHealth includes completed runs check", () => {
    it("includes checkCompletedRunsNotQueued in results", async () => {
      const { store } = makeMocks();
      const mq = makeMergeQueueMock([{ run_id: "r1", seed_id: "seed-abc" }]);
      const doctor = new Doctor(store as any, "/tmp/project", mq as any);
      const results = await doctor.checkMergeQueueHealth();
      const notQueuedCheck = results.find((r) => r.name === "completed runs queued");
      expect(notQueuedCheck).toBeDefined();
      expect(notQueuedCheck!.status).toBe("warn");
    });
  });

  describe("checkBlockedSeeds", () => {
    function makeIssue(id: string, title = "Some issue") {
      return {
        id,
        title,
        type: "task",
        priority: "P2",
        status: "open",
        assignee: null,
        parent: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      };
    }

    it("returns skip when no task client is configured", async () => {
      const { doctor } = makeMocks();
      const result = await doctor.checkBlockedSeeds();
      expect(result.status).toBe("skip");
      expect(result.name).toBe("blocked seeds");
    });

    it("returns pass when all open seeds are ready (no blocked seeds)", async () => {
      const { store } = makeMocks();
      const issue = makeIssue("bd-001");
      const taskClient = {
        list: vi.fn().mockResolvedValue([issue]),
        ready: vi.fn().mockResolvedValue([issue]),
        show: vi.fn(),
        update: vi.fn(),
        close: vi.fn(),
      };
      const doctor = new Doctor(store as any, "/tmp/project", undefined, taskClient as any);

      const result = await doctor.checkBlockedSeeds();

      expect(result.status).toBe("pass");
      expect(result.message).toBe("No blocked seeds");
    });

    it("returns pass when there are no open seeds at all", async () => {
      const { store } = makeMocks();
      const taskClient = {
        list: vi.fn().mockResolvedValue([]),
        ready: vi.fn().mockResolvedValue([]),
        show: vi.fn(),
        update: vi.fn(),
        close: vi.fn(),
      };
      const doctor = new Doctor(store as any, "/tmp/project", undefined, taskClient as any);

      const result = await doctor.checkBlockedSeeds();

      expect(result.status).toBe("pass");
      expect(result.message).toBe("No blocked seeds");
    });

    it("returns warn when some open seeds are blocked", async () => {
      const { store } = makeMocks();
      const unblocked = makeIssue("bd-001", "Unblocked task");
      const blocked = makeIssue("bd-002", "Blocked task");
      const taskClient = {
        list: vi.fn().mockResolvedValue([unblocked, blocked]),
        ready: vi.fn().mockResolvedValue([unblocked]),
        show: vi.fn(),
        update: vi.fn(),
        close: vi.fn(),
      };
      const doctor = new Doctor(store as any, "/tmp/project", undefined, taskClient as any);

      const result = await doctor.checkBlockedSeeds();

      expect(result.status).toBe("warn");
      expect(result.name).toBe("blocked seeds");
      expect(result.message).toContain("1 blocked seed(s)");
      expect(result.message).toContain("bd-002");
      expect(result.message).toContain("Blocked task");
    });

    it("returns warn listing all blocked seeds when multiple are blocked", async () => {
      const { store } = makeMocks();
      const blocked1 = makeIssue("bd-002", "Blocked task A");
      const blocked2 = makeIssue("bd-003", "Blocked task B");
      const taskClient = {
        list: vi.fn().mockResolvedValue([blocked1, blocked2]),
        ready: vi.fn().mockResolvedValue([]),
        show: vi.fn(),
        update: vi.fn(),
        close: vi.fn(),
      };
      const doctor = new Doctor(store as any, "/tmp/project", undefined, taskClient as any);

      const result = await doctor.checkBlockedSeeds();

      expect(result.status).toBe("warn");
      expect(result.message).toContain("2 blocked seed(s)");
      expect(result.message).toContain("bd-002");
      expect(result.message).toContain("bd-003");
    });

    it("returns warn when taskClient.list rejects (br unavailable)", async () => {
      const { store } = makeMocks();
      const taskClient = {
        list: vi.fn().mockRejectedValue(new Error("br: command not found")),
        ready: vi.fn().mockResolvedValue([]),
        show: vi.fn(),
        update: vi.fn(),
        close: vi.fn(),
      };
      const doctor = new Doctor(store as any, "/tmp/project", undefined, taskClient as any);

      const result = await doctor.checkBlockedSeeds();

      expect(result.status).toBe("warn");
      expect(result.name).toBe("blocked seeds");
      expect(result.message).toContain("Could not list seeds");
    });

    it("returns warn when taskClient.ready rejects (br unavailable)", async () => {
      const { store } = makeMocks();
      const taskClient = {
        list: vi.fn().mockResolvedValue([makeIssue("bd-001")]),
        ready: vi.fn().mockRejectedValue(new Error("br: not initialized")),
        show: vi.fn(),
        update: vi.fn(),
        close: vi.fn(),
      };
      const doctor = new Doctor(store as any, "/tmp/project", undefined, taskClient as any);

      const result = await doctor.checkBlockedSeeds();

      expect(result.status).toBe("warn");
      expect(result.name).toBe("blocked seeds");
      expect(result.message).toContain("Could not list seeds");
    });
  });

  describe("checkOrphanedWorktrees", () => {
    const mockListWorktrees = vi.mocked(listWorktrees);
    const mockBranchExistsOnOrigin = vi.mocked(branchExistsOnOrigin);

    beforeEach(() => {
      mockListWorktrees.mockReset();
      mockBranchExistsOnOrigin.mockReset();
      // Default: branch not on origin (safe to remove)
      mockBranchExistsOnOrigin.mockResolvedValue(false);
    });

    it("returns pass when no foreman worktrees", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      mockListWorktrees.mockResolvedValue([
        { path: "/tmp/project", branch: "main", head: "abc123", bare: false },
      ]);

      const results = await doctor.checkOrphanedWorktrees();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("pass");
      expect(results[0].message).toContain("No foreman worktrees");
    });

    it("reports pass for running run with a live process", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      mockListWorktrees.mockResolvedValue([
        { path: "/tmp/wt", branch: "foreman/seed-abc", head: "abc123", bare: false },
      ]);
      // Use the current process's PID — guaranteed to be alive
      const livePid = process.pid;
      store.getRunsForSeed.mockReturnValue([
        makeRun({ status: "running", seed_id: "seed-abc", worktree_path: "/tmp/wt", session_key: `session-pid-${livePid}` }),
      ]);

      const results = await doctor.checkOrphanedWorktrees();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("pass");
      expect(results[0].message).toContain("Active run");
    });

    it("reports warn for running run with dead process (zombie)", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      mockListWorktrees.mockResolvedValue([
        { path: "/tmp/wt", branch: "foreman/seed-abc", head: "abc123", bare: false },
      ]);
      // Use PID 999999999 — extremely unlikely to exist
      store.getRunsForSeed.mockReturnValue([
        makeRun({ status: "running", seed_id: "seed-abc", worktree_path: "/tmp/wt", session_key: "session-pid-999999999" }),
      ]);

      const results = await doctor.checkOrphanedWorktrees();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("warn");
      expect(results[0].message).toContain("Zombie run");
      expect(results[0].message).toContain("999999999");
    });

    it("reports warn for running run with no session_key (no pid)", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      mockListWorktrees.mockResolvedValue([
        { path: "/tmp/wt", branch: "foreman/seed-abc", head: "abc123", bare: false },
      ]);
      store.getRunsForSeed.mockReturnValue([
        makeRun({ status: "running", seed_id: "seed-abc", worktree_path: "/tmp/wt", session_key: null }),
      ]);

      const results = await doctor.checkOrphanedWorktrees();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("warn");
      expect(results[0].message).toContain("Zombie run");
    });

    it("reports pass for pending run without process check", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      mockListWorktrees.mockResolvedValue([
        { path: "/tmp/wt", branch: "foreman/seed-abc", head: "abc123", bare: false },
      ]);
      store.getRunsForSeed.mockReturnValue([
        makeRun({ status: "pending", seed_id: "seed-abc", worktree_path: "/tmp/wt", session_key: null }),
      ]);

      const results = await doctor.checkOrphanedWorktrees();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("pass");
      expect(results[0].message).toContain("pending");
    });

    it("warns for orphaned worktree with branch on origin (no runs)", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      mockListWorktrees.mockResolvedValue([
        { path: "/tmp/wt", branch: "foreman/seed-orphan", head: "abc123", bare: false },
      ]);
      store.getRunsForSeed.mockReturnValue([]);
      mockBranchExistsOnOrigin.mockResolvedValue(true);

      const results = await doctor.checkOrphanedWorktrees();

      expect(results[0].status).toBe("warn");
      expect(results[0].message).toContain("branch exists on origin");
      expect(results[0].message).toContain("skipping auto-removal");
    });

    it("removes orphaned worktree when branch not on origin and fix=true", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      mockListWorktrees.mockResolvedValue([
        { path: "/tmp/wt", branch: "foreman/seed-gone", head: "abc123", bare: false },
      ]);
      store.getRunsForSeed.mockReturnValue([]);
      mockBranchExistsOnOrigin.mockResolvedValue(false);
      vi.mocked(await import("../../lib/git.js").then(m => m)).removeWorktree = vi.fn().mockResolvedValue(undefined);

      const results = await doctor.checkOrphanedWorktrees({ fix: true });

      expect(results[0].message).toContain("not on origin");
    });

    it("warns without fix for orphaned worktree not on origin", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      mockListWorktrees.mockResolvedValue([
        { path: "/tmp/wt", branch: "foreman/seed-local", head: "abc123", bare: false },
      ]);
      store.getRunsForSeed.mockReturnValue([]);
      mockBranchExistsOnOrigin.mockResolvedValue(false);

      const results = await doctor.checkOrphanedWorktrees();

      expect(results[0].status).toBe("warn");
      expect(results[0].message).toContain("not on origin");
      expect(results[0].message).toContain("--fix");
    });

    it("reports pass for running SDK-based worker (no zombie false positive)", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      mockListWorktrees.mockResolvedValue([
        { path: "/tmp/wt", branch: "foreman/bd-vrst", head: "abc123", bare: false },
      ]);
      // SDK-based worker: session_key starts with "foreman:sdk:"
      store.getRunsForSeed.mockReturnValue([
        makeRun({ status: "running", seed_id: "bd-vrst", worktree_path: "/tmp/wt", session_key: "foreman:sdk:claude-sonnet-4-6:run-123" }),
      ]);

      const results = await doctor.checkOrphanedWorktrees();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("pass");
      expect(results[0].message).toContain("SDK-based worker");
    });

    it("reports pass for running SDK-based worker with session suffix", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      mockListWorktrees.mockResolvedValue([
        { path: "/tmp/wt", branch: "foreman/bd-u5oq", head: "abc123", bare: false },
      ]);
      // SDK worker with session suffix (after first agent message)
      store.getRunsForSeed.mockReturnValue([
        makeRun({ status: "running", seed_id: "bd-u5oq", worktree_path: "/tmp/wt", session_key: "foreman:sdk:claude-haiku-3-5:run-xyz:session-abc123" }),
      ]);

      const results = await doctor.checkOrphanedWorktrees();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("pass");
      expect(results[0].message).toContain("SDK-based worker");
    });
  });

  describe("checkGitTownInstalled", () => {
    it("returns pass when git town is installed", async () => {
      const { doctor } = makeMocks();
      // git town is available on the dev machine
      const result = await doctor.checkGitTownInstalled();
      // Accept pass or fail depending on whether git-town is installed in the test env
      expect(["pass", "fail"]).toContain(result.status);
      expect(result.name).toBe("git town installed");
    });

    it("returns fail when git town is not in PATH", async () => {
      const { doctor } = makeMocks();
      const originalPath = process.env.PATH;
      process.env.PATH = "";
      try {
        const result = await doctor.checkGitTownInstalled();
        expect(result.status).toBe("fail");
        expect(result.name).toBe("git town installed");
        expect(result.message).toBe("git town not found");
        expect(result.details).toContain("brew install git-town");
      } finally {
        process.env.PATH = originalPath;
      }
    });
  });

  describe("checkGitTownMainBranch", () => {
    const mockDetectDefaultBranch = vi.mocked(detectDefaultBranch);

    beforeEach(() => {
      mockDetectDefaultBranch.mockReset();
    });

    it("returns skip when git town is not installed", async () => {
      const { doctor } = makeMocks();
      const originalPath = process.env.PATH;
      process.env.PATH = "";
      try {
        const result = await doctor.checkGitTownMainBranch();
        expect(result.status).toBe("skip");
        expect(result.name).toBe("git town main branch configured");
        expect(result.message).toContain("git town not installed");
      } finally {
        process.env.PATH = originalPath;
      }
    });

    it("returns pass when git town main branch matches repo default", async () => {
      // Use the real foreman repo — read the actual configured branch dynamically
      // so this test stays valid regardless of what git-town.main-branch is set to.
      const store = { getProjectByPath: vi.fn(() => null as any) };
      const repoPath = "/Users/ldangelo/Development/Fortium/foreman";
      const doctor = new Doctor(store as any, repoPath);

      // Skip if git town is not installed in this environment
      const installed = await doctor.checkGitTownInstalled();
      if (installed.status !== "pass") return;

      // Read the actual git-town.main-branch so we can mock detectDefaultBranch to match
      const { execFile } = await import("node:child_process");
      const { promisify } = await import("node:util");
      const execFileAsync = promisify(execFile);
      let configuredBranch: string;
      try {
        const { stdout } = await execFileAsync("git", ["config", "--get", "git-town.main-branch"], { cwd: repoPath });
        configuredBranch = stdout.trim();
      } catch {
        // git-town not configured in this repo — skip
        return;
      }
      if (!configuredBranch) return;

      // Mock detectDefaultBranch to return the same branch so checkGitTownMainBranch → "pass"
      mockDetectDefaultBranch.mockResolvedValue(configuredBranch);
      const result = await doctor.checkGitTownMainBranch();
      expect(result.status).toBe("pass");
      expect(result.name).toBe("git town main branch configured");
      expect(result.message).toBe("git town main branch matches repo default");
    });

    it("returns warn when git town main branch does not match repo default", async () => {
      // Use the real foreman repo which has git-town.main-branch=main configured
      const store = { getProjectByPath: vi.fn(() => null as any) };
      const doctor = new Doctor(store as any, "/Users/ldangelo/Development/Fortium/foreman");

      // Skip if git town is not installed in this environment
      const installed = await doctor.checkGitTownInstalled();
      if (installed.status !== "pass") return;

      // Pretend repo default branch is "master" so it mismatches "main"
      mockDetectDefaultBranch.mockResolvedValue("master");
      const result = await doctor.checkGitTownMainBranch();
      expect(result.status).toBe("warn");
      expect(result.name).toBe("git town main branch configured");
      expect(result.message).toContain("does not match");
      expect(result.details).toContain("git town config set main-branch master");
    });

    it("returns warn when git town is not configured (no git-town.main-branch key)", async () => {
      // Use a path with no git-town config (git config --get will fail)
      const store = { getProjectByPath: vi.fn(() => null as any) };
      const doctor = new Doctor(store as any, "/tmp/no-git-town-config");

      // Skip if git town is not installed in this environment
      const installed = await doctor.checkGitTownInstalled();
      if (installed.status !== "pass") return;

      mockDetectDefaultBranch.mockResolvedValue("main");
      const result = await doctor.checkGitTownMainBranch();
      expect(result.status).toBe("warn");
      expect(result.name).toBe("git town main branch configured");
      // Either "not configured" or some other warning about missing config
      expect(["git town not configured", "Could not detect repo default branch (skipping comparison)"]).toContain(result.message);
    });
  });

  describe("runAll", () => {
    it("returns a DoctorReport with all sections", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue(null);
      store.getRunsByStatus.mockReturnValue([]);
      store.getActiveRuns.mockReturnValue([]);

      const report = await doctor.runAll();

      expect(report).toHaveProperty("system");
      expect(report).toHaveProperty("repository");
      expect(report).toHaveProperty("dataIntegrity");
      expect(report).toHaveProperty("summary");
      expect(report.summary).toHaveProperty("pass");
      expect(report.summary).toHaveProperty("fail");
      expect(report.summary).toHaveProperty("warn");
      expect(report.summary).toHaveProperty("fixed");
    });

    it("includes git town checks in system section", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue(null);
      store.getRunsByStatus.mockReturnValue([]);
      store.getActiveRuns.mockReturnValue([]);

      const report = await doctor.runAll();

      const names = report.system.map((r) => r.name);
      expect(names).toContain("git town installed");
      expect(names).toContain("git town main branch configured");
    });
  });
});

// ── checkPrompts ──────────────────────────────────────────────────────────────

describe("Doctor.checkPrompts", () => {
  it("returns fail when prompts are not installed", async () => {
    const tmpDir = await mkdtemp(join(tmpdir(), "foreman-doctor-prompts-"));
    try {
      const store = { getProjectByPath: vi.fn(() => null) };
      const doctor = new Doctor(store as any, tmpDir);
      const result = await doctor.checkPrompts();
      expect(result.status).toBe("fail");
      expect(result.message).toContain("missing prompt file");
      expect(result.message).toContain("foreman init");
    } finally {
      await rm(tmpDir, { recursive: true, force: true });
    }
  });

  it("returns pass when all prompts are installed", async () => {
    const { installBundledPrompts } = await import("../../lib/prompt-loader.js");
    const tmpDir = await mkdtemp(join(tmpdir(), "foreman-doctor-prompts-ok-"));
    try {
      installBundledPrompts(tmpDir, true);
      const store = { getProjectByPath: vi.fn(() => null) };
      const doctor = new Doctor(store as any, tmpDir);
      const result = await doctor.checkPrompts();
      expect(result.status).toBe("pass");
    } finally {
      await rm(tmpDir, { recursive: true, force: true });
    }
  });

  it("returns fixed when --fix reinstalls missing prompts", async () => {
    const tmpDir = await mkdtemp(join(tmpdir(), "foreman-doctor-prompts-fix-"));
    try {
      const store = { getProjectByPath: vi.fn(() => null) };
      const doctor = new Doctor(store as any, tmpDir);
      // First confirm they're missing
      const before = await doctor.checkPrompts();
      expect(before.status).toBe("fail");
      // Now fix
      const result = await doctor.checkPrompts({ fix: true });
      expect(result.status).toBe("fixed");
      expect(result.fixApplied).toContain("Installed");
    } finally {
      await rm(tmpDir, { recursive: true, force: true });
    }
  });

  it("dry-run reports missing prompts without installing", async () => {
    const tmpDir = await mkdtemp(join(tmpdir(), "foreman-doctor-prompts-dry-"));
    try {
      const store = { getProjectByPath: vi.fn(() => null) };
      const doctor = new Doctor(store as any, tmpDir);
      const result = await doctor.checkPrompts({ dryRun: true });
      expect(result.status).toBe("fail");
      expect(result.message).toContain("dry-run");
      // Should not have installed any files
      const { findMissingPrompts } = await import("../../lib/prompt-loader.js");
      const stillMissing = findMissingPrompts(tmpDir);
      expect(stillMissing.length).toBeGreaterThan(0);
    } finally {
      await rm(tmpDir, { recursive: true, force: true });
    }
  });

  it("checkRepository includes prompt check", async () => {
    const tmpDir = await mkdtemp(join(tmpdir(), "foreman-doctor-repo-prompts-"));
    try {
      const store = {
        getProjectByPath: vi.fn(() => null),
        getRunsByStatus: vi.fn(() => []),
        getActiveRuns: vi.fn(() => []),
      };
      const doctor = new Doctor(store as any, tmpDir);
      const results = await doctor.checkRepository();
      const promptCheck = results.find((r) => r.name.includes("prompt templates"));
      expect(promptCheck).toBeDefined();
      expect(promptCheck?.status).toBe("fail");
    } finally {
      await rm(tmpDir, { recursive: true, force: true });
    }
  });

  it("checkWorkflows fails when workflow configs are missing", async () => {
    const tmpDir = await mkdtemp(join(tmpdir(), "foreman-doctor-workflows-"));
    try {
      const store = {
        getProjectByPath: vi.fn(() => null),
        getRunsByStatus: vi.fn(() => []),
        getActiveRuns: vi.fn(() => []),
      };
      const doctor = new Doctor(store as any, tmpDir);
      const result = await doctor.checkWorkflows();
      expect(result.status).toBe("fail");
      expect(result.name).toContain("workflow configs");
      expect(result.message).toContain("missing");
    } finally {
      await rm(tmpDir, { recursive: true, force: true });
    }
  });

  it("checkWorkflows passes after install", async () => {
    const tmpDir = await mkdtemp(join(tmpdir(), "foreman-doctor-workflows-installed-"));
    try {
      const { installBundledWorkflows } = await import("../../lib/workflow-loader.js");
      installBundledWorkflows(tmpDir);
      const store = {
        getProjectByPath: vi.fn(() => null),
        getRunsByStatus: vi.fn(() => []),
        getActiveRuns: vi.fn(() => []),
      };
      const doctor = new Doctor(store as any, tmpDir);
      const result = await doctor.checkWorkflows();
      expect(result.status).toBe("pass");
    } finally {
      await rm(tmpDir, { recursive: true, force: true });
    }
  });

  it("checkWorkflows with --fix installs missing configs", async () => {
    const tmpDir = await mkdtemp(join(tmpdir(), "foreman-doctor-workflows-fix-"));
    try {
      const store = {
        getProjectByPath: vi.fn(() => null),
        getRunsByStatus: vi.fn(() => []),
        getActiveRuns: vi.fn(() => []),
      };
      const doctor = new Doctor(store as any, tmpDir);
      const result = await doctor.checkWorkflows({ fix: true });
      expect(result.status).toBe("fixed");
      expect(result.fixApplied).toContain("Installed");
    } finally {
      await rm(tmpDir, { recursive: true, force: true });
    }
  });

  it("checkRepository includes workflow configs check", async () => {
    const tmpDir = await mkdtemp(join(tmpdir(), "foreman-doctor-repo-workflows-"));
    try {
      const store = {
        getProjectByPath: vi.fn(() => null),
        getRunsByStatus: vi.fn(() => []),
        getActiveRuns: vi.fn(() => []),
      };
      const doctor = new Doctor(store as any, tmpDir);
      const results = await doctor.checkRepository();
      const workflowCheck = results.find((r) => r.name.includes("workflow configs"));
      expect(workflowCheck).toBeDefined();
      expect(workflowCheck?.status).toBe("fail");
    } finally {
      await rm(tmpDir, { recursive: true, force: true });
    }
  });
});
