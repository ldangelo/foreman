import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore, type Run, type RunProgress } from "../../lib/store.js";

// ── Mock child_process ─────────────────────────────────────────────────
const mockSpawnSync = vi.fn();

vi.mock("node:child_process", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  return {
    ...actual,
    spawn: vi.fn(),
    spawnSync: (...args: unknown[]) => mockSpawnSync(...args),
  };
});

// ── Helpers ────────────────────────────────────────────────────────────

function createTestRun(
  store: ForemanStore,
  projectId: string,
  overrides: Partial<{
    seedId: string;
    status: Run["status"];
    sessionKey: string | null;
    tmuxSession: string | null;
    worktreePath: string | null;
    agentType: string;
  }> = {},
): Run {
  const seedId = overrides.seedId ?? "test-seed";
  const agentType = overrides.agentType ?? "claude-sonnet-4-6";
  const run = store.createRun(projectId, seedId, agentType, overrides.worktreePath ?? "/tmp/wt");
  const updates: Partial<Pick<Run, "status" | "session_key" | "tmux_session" | "started_at">> = {};
  if (overrides.status) updates.status = overrides.status;
  if (overrides.sessionKey !== undefined) updates.session_key = overrides.sessionKey;
  if (overrides.tmuxSession !== undefined) updates.tmux_session = overrides.tmuxSession;
  if (Object.keys(updates).length > 0) store.updateRun(run.id, updates);
  return store.getRun(run.id)!;
}

// ── Test suite ─────────────────────────────────────────────────────────

describe("foreman run --attach / --no-attach (Sprint 4: Smart Dispatch)", () => {
  let store: ForemanStore;
  let tmpDir: string;
  let projectId: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-run-attach-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
    const project = store.registerProject("test-project", tmpDir);
    projectId = project.id;
    mockSpawnSync.mockReset();
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  // ── AT-T028: TTY-aware auto-attach ──────────────────────────────────

  describe("AT-T028: single seed dispatch from TTY auto-attaches", () => {
    it("auto-attaches when isTTY, single seed, and tmux_session available", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const { autoAttach } = await import("../commands/run.js");

      // Simulate: single dispatched run with tmux session
      const run = createTestRun(store, projectId, {
        seedId: "seed-1",
        status: "running",
        tmuxSession: "foreman-seed-1",
      });

      mockSpawnSync.mockReturnValue({ status: 0 });

      const result = await autoAttach({
        dispatched: [{ seedId: "seed-1", runId: run.id, title: "Test task", runtime: "claude-code" as const, model: "claude-sonnet-4-6" as const, worktreePath: "/tmp/wt", branchName: "foreman/seed-1" }],
        store,
        isTTY: true,
        forceAttach: false,
        noAttach: false,
        seedFilter: "seed-1",
      });

      expect(result).toBe(true);
      expect(mockSpawnSync).toHaveBeenCalledWith(
        "tmux",
        ["attach-session", "-t", "foreman-seed-1"],
        expect.objectContaining({ stdio: "inherit" }),
      );
      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining("Auto-attaching"),
      );

      consoleSpy.mockRestore();
    });
  });

  // ── AT-T027/AT-T028: --no-attach skips auto-attach ─────────────────

  describe("AT-T028: --no-attach skips auto-attach", () => {
    it("does not auto-attach when --no-attach is set", async () => {
      const { autoAttach } = await import("../commands/run.js");

      const run = createTestRun(store, projectId, {
        seedId: "seed-2",
        status: "running",
        tmuxSession: "foreman-seed-2",
      });

      const result = await autoAttach({
        dispatched: [{ seedId: "seed-2", runId: run.id, title: "Test task", runtime: "claude-code" as const, model: "claude-sonnet-4-6" as const, worktreePath: "/tmp/wt", branchName: "foreman/seed-2" }],
        store,
        isTTY: true,
        forceAttach: false,
        noAttach: true,
        seedFilter: "seed-2",
      });

      expect(result).toBe(false);
      expect(mockSpawnSync).not.toHaveBeenCalled();
    });
  });

  // ── AT-T027/AT-T028: --attach forces auto-attach ───────────────────

  describe("AT-T028: --attach forces auto-attach even without TTY", () => {
    it("force attaches when --attach is set even without isTTY", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const { autoAttach } = await import("../commands/run.js");

      const run = createTestRun(store, projectId, {
        seedId: "seed-3",
        status: "running",
        tmuxSession: "foreman-seed-3",
      });

      mockSpawnSync.mockReturnValue({ status: 0 });

      const result = await autoAttach({
        dispatched: [{ seedId: "seed-3", runId: run.id, title: "Test task", runtime: "claude-code" as const, model: "claude-sonnet-4-6" as const, worktreePath: "/tmp/wt", branchName: "foreman/seed-3" }],
        store,
        isTTY: false,
        forceAttach: true,
        noAttach: false,
        seedFilter: "seed-3",
      });

      expect(result).toBe(true);
      expect(mockSpawnSync).toHaveBeenCalledWith(
        "tmux",
        ["attach-session", "-t", "foreman-seed-3"],
        expect.objectContaining({ stdio: "inherit" }),
      );

      consoleSpy.mockRestore();
    });
  });

  // ── AT-T028: multi-agent dispatch without --seed does not auto-attach ──

  describe("AT-T028: multi-agent dispatch does not auto-attach", () => {
    it("skips auto-attach when multiple agents dispatched and no --seed", async () => {
      const { autoAttach } = await import("../commands/run.js");

      const run1 = createTestRun(store, projectId, {
        seedId: "seed-a",
        status: "running",
        tmuxSession: "foreman-seed-a",
      });
      const run2 = createTestRun(store, projectId, {
        seedId: "seed-b",
        status: "running",
        tmuxSession: "foreman-seed-b",
      });

      const result = await autoAttach({
        dispatched: [
          { seedId: "seed-a", runId: run1.id, title: "Task A", runtime: "claude-code" as const, model: "claude-sonnet-4-6" as const, worktreePath: "/tmp/wt-a", branchName: "foreman/seed-a" },
          { seedId: "seed-b", runId: run2.id, title: "Task B", runtime: "claude-code" as const, model: "claude-sonnet-4-6" as const, worktreePath: "/tmp/wt-b", branchName: "foreman/seed-b" },
        ],
        store,
        isTTY: true,
        forceAttach: false,
        noAttach: false,
        seedFilter: undefined,
      });

      expect(result).toBe(false);
      expect(mockSpawnSync).not.toHaveBeenCalled();
    });
  });

  // ── AT-T028: non-TTY stdout skips auto-attach ──────────────────────

  describe("AT-T028: non-TTY stdout skips auto-attach", () => {
    it("does not auto-attach when stdout is not a TTY", async () => {
      const { autoAttach } = await import("../commands/run.js");

      const run = createTestRun(store, projectId, {
        seedId: "seed-pipe",
        status: "running",
        tmuxSession: "foreman-seed-pipe",
      });

      const result = await autoAttach({
        dispatched: [{ seedId: "seed-pipe", runId: run.id, title: "Test task", runtime: "claude-code" as const, model: "claude-sonnet-4-6" as const, worktreePath: "/tmp/wt", branchName: "foreman/seed-pipe" }],
        store,
        isTTY: false,
        forceAttach: false,
        noAttach: false,
        seedFilter: "seed-pipe",
      });

      expect(result).toBe(false);
      expect(mockSpawnSync).not.toHaveBeenCalled();
    });
  });

  // ── AT-T029: tmux unavailable skips auto-attach silently ────────────

  describe("AT-T029: tmux unavailable skips auto-attach silently", () => {
    it("skips auto-attach when run has no tmux_session", async () => {
      const consoleErrSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      const { autoAttach } = await import("../commands/run.js");

      const run = createTestRun(store, projectId, {
        seedId: "seed-notmux",
        status: "running",
        tmuxSession: null,
      });

      const result = await autoAttach({
        dispatched: [{ seedId: "seed-notmux", runId: run.id, title: "Test task", runtime: "claude-code" as const, model: "claude-sonnet-4-6" as const, worktreePath: "/tmp/wt", branchName: "foreman/seed-notmux" }],
        store,
        isTTY: true,
        forceAttach: false,
        noAttach: false,
        seedFilter: "seed-notmux",
      });

      expect(result).toBe(false);
      expect(mockSpawnSync).not.toHaveBeenCalled();
      // Should NOT print an error — it just silently skips
      expect(consoleErrSpy).not.toHaveBeenCalled();

      consoleErrSpy.mockRestore();
    });
  });

  // ── AT-T029: --attach with multi-agent attaches to first agent ──────

  describe("AT-T029: --attach with multi-agent attaches to first agent", () => {
    it("attaches to first dispatched agent when --attach forced with multiple agents", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const { autoAttach } = await import("../commands/run.js");

      const run1 = createTestRun(store, projectId, {
        seedId: "multi-a",
        status: "running",
        tmuxSession: "foreman-multi-a",
      });
      const run2 = createTestRun(store, projectId, {
        seedId: "multi-b",
        status: "running",
        tmuxSession: "foreman-multi-b",
      });

      mockSpawnSync.mockReturnValue({ status: 0 });

      const result = await autoAttach({
        dispatched: [
          { seedId: "multi-a", runId: run1.id, title: "Task A", runtime: "claude-code" as const, model: "claude-sonnet-4-6" as const, worktreePath: "/tmp/wt-a", branchName: "foreman/multi-a" },
          { seedId: "multi-b", runId: run2.id, title: "Task B", runtime: "claude-code" as const, model: "claude-sonnet-4-6" as const, worktreePath: "/tmp/wt-b", branchName: "foreman/multi-b" },
        ],
        store,
        isTTY: true,
        forceAttach: true,
        noAttach: false,
        seedFilter: undefined,
      });

      expect(result).toBe(true);
      // Should attach to first agent only
      expect(mockSpawnSync).toHaveBeenCalledTimes(1);
      expect(mockSpawnSync).toHaveBeenCalledWith(
        "tmux",
        ["attach-session", "-t", "foreman-multi-a"],
        expect.objectContaining({ stdio: "inherit" }),
      );

      consoleSpy.mockRestore();
    });
  });

  // ── AT-T029: retry on race condition ────────────────────────────────

  describe("AT-T029: retry when tmux_session not yet available", () => {
    it("retries up to 3 times with delay when tmux_session is not yet on the run record", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const { autoAttach } = await import("../commands/run.js");

      // Create run without tmux_session initially
      const run = createTestRun(store, projectId, {
        seedId: "seed-race",
        status: "running",
        tmuxSession: null,
      });

      // After a "delay", update the run to have a tmux_session
      // We'll simulate this by updating the store before the retry reads it
      setTimeout(() => {
        store.updateRun(run.id, { tmux_session: "foreman-seed-race" });
      }, 100);

      mockSpawnSync.mockReturnValue({ status: 0 });

      const result = await autoAttach({
        dispatched: [{ seedId: "seed-race", runId: run.id, title: "Test task", runtime: "claude-code" as const, model: "claude-sonnet-4-6" as const, worktreePath: "/tmp/wt", branchName: "foreman/seed-race" }],
        store,
        isTTY: true,
        forceAttach: true,
        noAttach: false,
        seedFilter: "seed-race",
        retryDelayMs: 150,
      });

      expect(result).toBe(true);
      expect(mockSpawnSync).toHaveBeenCalledWith(
        "tmux",
        ["attach-session", "-t", "foreman-seed-race"],
        expect.objectContaining({ stdio: "inherit" }),
      );

      consoleSpy.mockRestore();
    });

    it("gives up after 3 retries and skips silently", async () => {
      const { autoAttach } = await import("../commands/run.js");

      const run = createTestRun(store, projectId, {
        seedId: "seed-noretry",
        status: "running",
        tmuxSession: null,
      });

      const result = await autoAttach({
        dispatched: [{ seedId: "seed-noretry", runId: run.id, title: "Test task", runtime: "claude-code" as const, model: "claude-sonnet-4-6" as const, worktreePath: "/tmp/wt", branchName: "foreman/seed-noretry" }],
        store,
        isTTY: true,
        forceAttach: true,
        noAttach: false,
        seedFilter: "seed-noretry",
        retryDelayMs: 50,
      });

      expect(result).toBe(false);
      expect(mockSpawnSync).not.toHaveBeenCalled();
    });
  });

  // ── AT-T028: empty dispatch does not auto-attach ────────────────────

  describe("AT-T028: empty dispatch does not auto-attach", () => {
    it("returns false when no tasks were dispatched", async () => {
      const { autoAttach } = await import("../commands/run.js");

      const result = await autoAttach({
        dispatched: [],
        store,
        isTTY: true,
        forceAttach: false,
        noAttach: false,
        seedFilter: "whatever",
      });

      expect(result).toBe(false);
      expect(mockSpawnSync).not.toHaveBeenCalled();
    });
  });
});
