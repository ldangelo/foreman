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
  };
});
import { listWorktrees, branchExistsOnOrigin } from "../../lib/git.js";

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
    progress: null,
    tmux_session: null,
    ...overrides,
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

    it("does NOT mark SDK-based run (no tmux_session) as zombie", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      // SDK worker without tmux: session_key starts with "foreman:sdk:", no tmux_session
      const run = makeRun({
        session_key: "foreman:sdk:claude-sonnet-4-6:run-1",
        tmux_session: null,
      });
      store.getRunsByStatus.mockReturnValue([run]);

      const results = await doctor.checkZombieRuns();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("pass");
      expect(results[0].message).toContain("SDK-based worker");
    });

    it("does NOT mark SDK-based run with session suffix (no tmux_session) as zombie", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      // SDK worker with session suffix (after first agent message), still no PID
      const run = makeRun({
        session_key: "foreman:sdk:claude-sonnet-4-6:run-1:session-abc123",
        tmux_session: null,
      });
      store.getRunsByStatus.mockReturnValue([run]);

      const results = await doctor.checkZombieRuns();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("pass");
      expect(results[0].message).toContain("SDK-based worker");
    });

    it("does NOT mark SDK-based run with tmux_session as zombie (deferred to checkGhostRuns)", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      // SDK worker with tmux session: liveness checked by checkGhostRuns(), not here
      const run = makeRun({
        session_key: "foreman:sdk:claude-opus-4-6:run-2",
        tmux_session: "foreman-bd-krew",
      });
      store.getRunsByStatus.mockReturnValue([run]);

      const results = await doctor.checkZombieRuns();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("pass");
      expect(results[0].message).toContain("SDK-based worker");
      // Crucially: updateRun should NOT have been called
      expect(store.updateRun).not.toHaveBeenCalled();
    });

    it("does NOT fix SDK-based runs even when fix=true", async () => {
      const { store, doctor } = makeMocks();
      store.getProjectByPath.mockReturnValue({ id: "proj-1", name: "test", status: "active", path: "/tmp/project", created_at: "", updated_at: "" });
      const run = makeRun({
        session_key: "foreman:sdk:claude-sonnet-4-6:run-3",
        tmux_session: null,
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
        tmux_session: null,
      });
      const zombieRun = makeRun({
        id: "run-zombie",
        seed_id: "bd-zombie",
        session_key: null, // no PID = zombie
        tmux_session: null,
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
      const doctor = new Doctor(store as any, "/tmp/project", undefined, undefined, taskClient as any);

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
      const doctor = new Doctor(store as any, "/tmp/project", undefined, undefined, taskClient as any);

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
      const doctor = new Doctor(store as any, "/tmp/project", undefined, undefined, taskClient as any);

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
      const doctor = new Doctor(store as any, "/tmp/project", undefined, undefined, taskClient as any);

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
      const doctor = new Doctor(store as any, "/tmp/project", undefined, undefined, taskClient as any);

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
      const doctor = new Doctor(store as any, "/tmp/project", undefined, undefined, taskClient as any);

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
  });
});
