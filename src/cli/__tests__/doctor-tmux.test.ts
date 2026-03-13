import { describe, it, expect, vi } from "vitest";
import { Doctor } from "../../orchestrator/doctor.js";
import type { Run } from "../../lib/store.js";
import type { TmuxClient, TmuxSessionInfo } from "../../lib/tmux.js";

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "seeds-001",
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

function makeProject() {
  return {
    id: "proj-1",
    name: "test",
    status: "active" as const,
    path: "/tmp/project",
    created_at: "",
    updated_at: "",
  };
}

function makeMocks() {
  const store = {
    getProjectByPath: vi.fn(() => makeProject()),
    getRunsByStatus: vi.fn((): Run[] => []),
    getRunsForSeed: vi.fn((): Run[] => []),
    getActiveRuns: vi.fn((): Run[] => []),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    getRun: vi.fn((): Run | null => null),
  };
  const tmux: {
    isAvailable: ReturnType<typeof vi.fn>;
    getTmuxVersion: ReturnType<typeof vi.fn>;
    listForemanSessions: ReturnType<typeof vi.fn>;
    hasSession: ReturnType<typeof vi.fn>;
    killSession: ReturnType<typeof vi.fn>;
  } = {
    isAvailable: vi.fn(async () => true),
    getTmuxVersion: vi.fn(async () => "3.4"),
    listForemanSessions: vi.fn(async (): Promise<TmuxSessionInfo[]> => []),
    hasSession: vi.fn(async () => true),
    killSession: vi.fn(async () => true),
  };
  const doctor = new Doctor(
    store as any,
    "/tmp/project",
    undefined, // no merge queue
    tmux as unknown as TmuxClient,
  );
  return { store, tmux, doctor };
}

describe("Doctor — Session Management (AT-T033 / AT-T034 / AT-T035)", () => {
  describe("checkTmuxAvailability", () => {
    it("returns pass when tmux is available with version >= 3.0", async () => {
      const { tmux, doctor } = makeMocks();
      tmux.isAvailable.mockResolvedValue(true);
      tmux.getTmuxVersion.mockResolvedValue("3.4");

      const result = await doctor.checkTmuxAvailability();

      expect(result.status).toBe("pass");
      expect(result.message).toContain("3.4");
    });

    it("returns warn when tmux version < 3.0", async () => {
      const { tmux, doctor } = makeMocks();
      tmux.isAvailable.mockResolvedValue(true);
      tmux.getTmuxVersion.mockResolvedValue("2.9a");

      const result = await doctor.checkTmuxAvailability();

      expect(result.status).toBe("warn");
      expect(result.message).toContain("2.9a");
    });

    it("returns warn when tmux is not available", async () => {
      const { tmux, doctor } = makeMocks();
      tmux.isAvailable.mockResolvedValue(false);

      const result = await doctor.checkTmuxAvailability();

      expect(result.status).toBe("warn");
      expect(result.message).toContain("not available");
    });
  });

  describe("checkOrphanedTmuxSessions", () => {
    it("returns pass when no foreman sessions exist", async () => {
      const { tmux, doctor } = makeMocks();
      tmux.listForemanSessions.mockResolvedValue([]);

      const results = await doctor.checkOrphanedTmuxSessions();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("pass");
    });

    it("detects orphaned sessions (no matching active run)", async () => {
      const { store, tmux, doctor } = makeMocks();
      tmux.listForemanSessions.mockResolvedValue([
        { sessionName: "foreman-seeds-001", created: "1234", attached: false, windowCount: 1 },
      ]);
      // No active runs reference this session
      store.getActiveRuns.mockReturnValue([]);

      const results = await doctor.checkOrphanedTmuxSessions();

      expect(results.some((r) => r.status === "warn" && r.message.includes("Orphaned"))).toBe(true);
    });

    it("passes for sessions that match active runs", async () => {
      const { store, tmux, doctor } = makeMocks();
      tmux.listForemanSessions.mockResolvedValue([
        { sessionName: "foreman-seeds-001", created: "1234", attached: false, windowCount: 1 },
      ]);
      store.getActiveRuns.mockReturnValue([
        makeRun({ tmux_session: "foreman-seeds-001" }),
      ]);

      const results = await doctor.checkOrphanedTmuxSessions();

      // Should be pass — session matches an active run
      const orphanResults = results.filter((r) => r.message.includes("Orphaned"));
      expect(orphanResults).toHaveLength(0);
    });

    it("fixes orphaned sessions with --fix", async () => {
      const { store, tmux, doctor } = makeMocks();
      tmux.listForemanSessions.mockResolvedValue([
        { sessionName: "foreman-orphan-1", created: "1234", attached: false, windowCount: 1 },
      ]);
      store.getActiveRuns.mockReturnValue([]);

      const results = await doctor.checkOrphanedTmuxSessions({ fix: true });

      expect(tmux.killSession).toHaveBeenCalledWith("foreman-orphan-1");
      expect(results.some((r) => r.status === "fixed")).toBe(true);
    });
  });

  describe("checkGhostRuns", () => {
    it("returns pass when no ghost runs exist", async () => {
      const { store, tmux, doctor } = makeMocks();
      store.getActiveRuns.mockReturnValue([]);

      const results = await doctor.checkGhostRuns();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("pass");
    });

    it("detects ghost runs (active run with dead tmux session)", async () => {
      const { store, tmux, doctor } = makeMocks();
      const run = makeRun({ tmux_session: "foreman-seeds-001" });
      store.getActiveRuns.mockReturnValue([run]);
      tmux.hasSession.mockResolvedValue(false);

      const results = await doctor.checkGhostRuns();

      expect(results.some((r) => r.status === "warn" && r.message.includes("Ghost"))).toBe(true);
    });

    it("fixes ghost runs with --fix by marking as stuck", async () => {
      const { store, tmux, doctor } = makeMocks();
      const run = makeRun({ tmux_session: "foreman-seeds-001" });
      store.getActiveRuns.mockReturnValue([run]);
      tmux.hasSession.mockResolvedValue(false);

      const results = await doctor.checkGhostRuns({ fix: true });

      expect(store.updateRun).toHaveBeenCalledWith(run.id, { status: "stuck" });
      expect(results.some((r) => r.status === "fixed" && r.fixApplied?.includes("stuck"))).toBe(true);
    });

    it("skips runs without tmux_session", async () => {
      const { store, tmux, doctor } = makeMocks();
      const run = makeRun({ tmux_session: null });
      store.getActiveRuns.mockReturnValue([run]);

      const results = await doctor.checkGhostRuns();

      expect(tmux.hasSession).not.toHaveBeenCalled();
      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("pass");
    });
  });

  describe("checkSessionManagement (all three together)", () => {
    it("runs all session management checks via checkSessionManagement", async () => {
      const { tmux, doctor } = makeMocks();
      tmux.isAvailable.mockResolvedValue(true);
      tmux.getTmuxVersion.mockResolvedValue("3.4");
      tmux.listForemanSessions.mockResolvedValue([]);

      const results = await doctor.checkSessionManagement();

      // Should include availability check + orphaned check + ghost check
      expect(results.length).toBeGreaterThanOrEqual(3);
    });

    it("skips session checks when no tmux client is provided", async () => {
      const store = {
        getProjectByPath: vi.fn(() => makeProject()),
        getRunsByStatus: vi.fn((): Run[] => []),
        getRunsForSeed: vi.fn((): Run[] => []),
        getActiveRuns: vi.fn((): Run[] => []),
        updateRun: vi.fn(),
        logEvent: vi.fn(),
        getRun: vi.fn((): Run | null => null),
      };
      // No tmux client
      const doctor = new Doctor(store as any, "/tmp/project");

      const results = await doctor.checkSessionManagement();

      expect(results).toHaveLength(1);
      expect(results[0].status).toBe("skip");
    });
  });
});
