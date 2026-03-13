import { describe, it, expect, vi, beforeEach } from "vitest";
import { Doctor } from "../doctor.js";
import type { Run } from "../../lib/store.js";

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
