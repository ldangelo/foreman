import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Mock setup ──────────────────────────────────────────────────────────────
//
// We mock node:child_process so no real subprocess is spawned.
// vi.hoisted() ensures the mock variable is initialised before the module
// factory runs (vitest hoists vi.mock() calls to the top of the file).

const { mockExecFileSync, mockHomedir, mockExecBr } = vi.hoisted(() => ({
  mockExecFileSync: vi.fn(),
  mockHomedir: vi.fn().mockReturnValue("/test/home"),
  mockExecBr: vi.fn().mockResolvedValue(""),
}));

vi.mock("node:child_process", () => ({
  execFileSync: mockExecFileSync,
}));

vi.mock("node:os", () => ({
  homedir: mockHomedir,
}));

vi.mock("../../lib/beads-rust.js", () => ({
  execBr: mockExecBr,
}));

import { closeSeed, resetSeedToOpen, syncBeadStatusOnStartup } from "../task-backend-ops.js";
import type { Run } from "../../lib/store.js";

// ── Helpers ──────────────────────────────────────────────────────────────────

const HOME = "/test/home";

// ── closeSeed ────────────────────────────────────────────────────────────────

describe("closeSeed — sd backend (default)", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    delete process.env.FOREMAN_TASK_BACKEND;
    process.env.HOME = HOME;
  });

  afterEach(() => {
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  // TRD-023: default changed from 'sd' to 'br'
  it("defaults to br backend when FOREMAN_TASK_BACKEND is not set", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));
    // env var is not set (deleted in beforeEach)

    closeSeed("task-xyz-999");

    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args[0]).toBe("close");
  });

});

describe("closeSeed — br backend", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    process.env.FOREMAN_TASK_BACKEND = "br";
    process.env.HOME = HOME;
  });

  afterEach(() => {
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  it("calls br close with seedId and --reason flag", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    closeSeed("bd-abc-001");

    expect(mockExecFileSync).toHaveBeenCalledOnce();
    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args).toEqual(["close", "bd-abc-001", "--reason", "Completed via pipeline"]);
  });

  it("uses ~/.local/bin/br path for br backend", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    closeSeed("bd-abc-001");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toBe(`${HOME}/.local/bin/br`);
  });

  it("does not call sd when backend is br", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    closeSeed("bd-abc-001");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).not.toContain("sd");
    expect(cmd).not.toContain(".bun");
  });

  it("does not throw when br close fails (error suppressed)", () => {
    mockExecFileSync.mockImplementation(() => { throw new Error("br binary missing"); });

    // Must not throw — errors should be caught and logged
    expect(() => closeSeed("bd-fail-002")).not.toThrow();
  });

  it("passes the correct --reason text", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    closeSeed("bd-reason-test");

    const [, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    const reasonIdx = args.indexOf("--reason");
    expect(reasonIdx).toBeGreaterThanOrEqual(0);
    expect(args[reasonIdx + 1]).toBe("Completed via pipeline");
  });
});

// ── resetSeedToOpen ──────────────────────────────────────────────────────────

describe("resetSeedToOpen — sd backend (default)", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    delete process.env.FOREMAN_TASK_BACKEND;
    process.env.HOME = HOME;
  });

  afterEach(() => {
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  // TRD-023: default changed from 'sd' to 'br'
  it("defaults to br backend when FOREMAN_TASK_BACKEND is not set", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    resetSeedToOpen("task-xyz-999");

    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args[0]).toBe("update");
    expect(args).toContain("open");
  });

});

describe("resetSeedToOpen — br backend", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    process.env.FOREMAN_TASK_BACKEND = "br";
    process.env.HOME = HOME;
  });

  afterEach(() => {
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  it("calls br update with --status open", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    resetSeedToOpen("bd-stuck-001");

    expect(mockExecFileSync).toHaveBeenCalledOnce();
    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args).toEqual(["update", "bd-stuck-001", "--status", "open"]);
  });

  it("uses ~/.local/bin/br path for br backend", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    resetSeedToOpen("bd-stuck-001");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toBe(`${HOME}/.local/bin/br`);
  });

  it("does not call sd when backend is br", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    resetSeedToOpen("bd-stuck-001");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).not.toContain("sd");
    expect(cmd).not.toContain(".bun");
  });

  it("does not throw when br update fails (error suppressed)", () => {
    mockExecFileSync.mockImplementation(() => { throw new Error("br binary missing"); });

    expect(() => resetSeedToOpen("bd-fail-002")).not.toThrow();
  });

  it("passes --status open as the status value", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    resetSeedToOpen("bd-status-test");

    const [, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    const statusIdx = args.indexOf("--status");
    expect(statusIdx).toBeGreaterThanOrEqual(0);
    expect(args[statusIdx + 1]).toBe("open");
  });
});

// ── projectPath (cwd) — the core bug fix ─────────────────────────────────────
//
// br reads .beads/ from the CWD. Worker processes run from the worktree
// directory, which has no .beads/ directory.  Without an explicit cwd the
// br subprocess silently fails (error is caught), so beads are never closed.
// Fix: closeSeed / resetSeedToOpen must accept a projectPath and forward it
// as the cwd in execFileSync options.

describe("closeSeed — projectPath forwarded as cwd", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    mockExecFileSync.mockReturnValue(Buffer.from(""));
    process.env.HOME = HOME;
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  it("passes projectPath as cwd to execFileSync", () => {
    closeSeed("bd-cwd-001", "/my/project/root");

    const [, , opts] = mockExecFileSync.mock.calls[0] as [string, string[], Record<string, unknown>];
    expect(opts.cwd).toBe("/my/project/root");
  });

  it("omits cwd when projectPath is not provided", () => {
    closeSeed("bd-cwd-002");

    const [, , opts] = mockExecFileSync.mock.calls[0] as [string, string[], Record<string, unknown>];
    expect(opts.cwd).toBeUndefined();
  });
});

describe("resetSeedToOpen — projectPath forwarded as cwd", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    mockExecFileSync.mockReturnValue(Buffer.from(""));
    process.env.HOME = HOME;
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  it("passes projectPath as cwd to execFileSync", () => {
    resetSeedToOpen("bd-reset-cwd-001", "/my/project/root");

    const [, , opts] = mockExecFileSync.mock.calls[0] as [string, string[], Record<string, unknown>];
    expect(opts.cwd).toBe("/my/project/root");
  });

  it("omits cwd when projectPath is not provided", () => {
    resetSeedToOpen("bd-reset-cwd-002");

    const [, , opts] = mockExecFileSync.mock.calls[0] as [string, string[], Record<string, unknown>];
    expect(opts.cwd).toBeUndefined();
  });
});

// ── HOME fallback ────────────────────────────────────────────────────────────

describe("closeSeed / resetSeedToOpen — homedir() path resolution", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    mockExecFileSync.mockReturnValue(Buffer.from(""));
    mockHomedir.mockReturnValue("/fallback/home");
  });

  afterEach(() => {
    delete process.env.FOREMAN_TASK_BACKEND;
    mockHomedir.mockReturnValue("/test/home");
  });

  it("closeSeed uses os.homedir() for br path", () => {
    process.env.FOREMAN_TASK_BACKEND = "br";

    closeSeed("bd-no-home");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toBe("/fallback/home/.local/bin/br");
  });

  it("resetSeedToOpen uses os.homedir() for br path", () => {
    process.env.FOREMAN_TASK_BACKEND = "br";

    resetSeedToOpen("bd-no-home");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toBe("/fallback/home/.local/bin/br");
  });
});

// ── syncBeadStatusOnStartup ──────────────────────────────────────────────────

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "seed-abc",
    agent_type: "claude-sonnet-4-6",
    session_key: null,
    worktree_path: "/tmp/wt",
    status: "completed",
    started_at: new Date().toISOString(),
    completed_at: new Date().toISOString(),
    created_at: new Date().toISOString(),
    progress: null,
    tmux_session: null,
    ...overrides,
  };
}

function makeSyncMocks() {
  const store = {
    getRunsByStatuses: vi.fn((): Run[] => []),
  };
  const taskClient = {
    show: vi.fn(async () => ({ status: "in_progress" })),
    update: vi.fn(async () => {}),
  };
  return { store, taskClient };
}

describe("syncBeadStatusOnStartup", () => {
  beforeEach(() => {
    mockExecBr.mockReset();
    mockExecBr.mockResolvedValue("");
  });

  it("returns empty result when no terminal runs exist", async () => {
    const { store, taskClient } = makeSyncMocks();
    store.getRunsByStatuses.mockReturnValue([]);

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.synced).toBe(0);
    expect(result.mismatches).toHaveLength(0);
    expect(result.errors).toHaveLength(0);
    expect(taskClient.show).not.toHaveBeenCalled();
    expect(mockExecBr).not.toHaveBeenCalled();
  });

  it("detects mismatch when completed run has seed still in_progress", async () => {
    const { store, taskClient } = makeSyncMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.mismatches).toHaveLength(1);
    expect(result.mismatches[0]).toMatchObject({
      seedId: "seed-abc",
      runId: "run-1",
      runStatus: "completed",
      actualSeedStatus: "in_progress",
      expectedSeedStatus: "closed",
    });
  });

  it("fixes mismatch by calling taskClient.update and counts synced", async () => {
    const { store, taskClient } = makeSyncMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(taskClient.update).toHaveBeenCalledWith("seed-abc", { status: "closed" });
    expect(result.synced).toBe(1);
  });

  it("calls br sync --flush-only after updates when synced > 0", async () => {
    const { store, taskClient } = makeSyncMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });

    await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(mockExecBr).toHaveBeenCalledWith(["sync", "--flush-only"], undefined);
  });

  it("passes projectPath to br sync --flush-only", async () => {
    const { store, taskClient } = makeSyncMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });

    await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1", {
      projectPath: "/my/project",
    });

    expect(mockExecBr).toHaveBeenCalledWith(["sync", "--flush-only"], "/my/project");
  });

  it("does not call br sync --flush-only when nothing was synced", async () => {
    const { store, taskClient } = makeSyncMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    // Seed already has correct status — no mismatch
    taskClient.show.mockResolvedValue({ status: "closed" });

    await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(mockExecBr).not.toHaveBeenCalled();
  });

  it("does not update seeds in dry-run mode", async () => {
    const { store, taskClient } = makeSyncMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1", {
      dryRun: true,
    });

    expect(taskClient.update).not.toHaveBeenCalled();
    expect(result.synced).toBe(0);
    expect(result.mismatches).toHaveLength(1);
    expect(mockExecBr).not.toHaveBeenCalled();
  });

  it("silently skips seeds that no longer exist in br (not found error)", async () => {
    const { store, taskClient } = makeSyncMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockRejectedValue(new Error("Issue not found: seed-abc"));

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.mismatches).toHaveLength(0);
    expect(result.errors).toHaveLength(0);
  });

  it("records error when show fails with unexpected error", async () => {
    const { store, taskClient } = makeSyncMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockRejectedValue(new Error("Connection refused"));

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toContain("seed-abc");
  });

  it("records error when update fails, does not count as synced", async () => {
    const { store, taskClient } = makeSyncMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });
    taskClient.update.mockRejectedValue(new Error("Update failed"));

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.mismatches).toHaveLength(1);
    expect(result.synced).toBe(0);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toContain("seed-abc");
  });

  it("deduplicates by seed_id, using the most recent run", async () => {
    const { store, taskClient } = makeSyncMocks();
    const olderRun = makeRun({
      id: "run-old",
      seed_id: "seed-shared",
      status: "completed",
      created_at: "2026-01-01T00:00:00.000Z",
    });
    const newerRun = makeRun({
      id: "run-new",
      seed_id: "seed-shared",
      status: "failed",
      created_at: "2026-01-02T00:00:00.000Z",
    });
    store.getRunsByStatuses.mockReturnValue([olderRun, newerRun]);
    taskClient.show.mockResolvedValue({ status: "closed" });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    // Should only call show once (deduplicated)
    expect(taskClient.show).toHaveBeenCalledTimes(1);
    // Should use the newer run's status (failed → open)
    expect(result.mismatches[0]).toMatchObject({
      runStatus: "failed",
      expectedSeedStatus: "open",
    });
  });

  it("handles multiple seeds with different statuses", async () => {
    const { store, taskClient } = makeSyncMocks();
    const run1 = makeRun({ id: "run-1", seed_id: "seed-a", status: "completed" });
    const run2 = makeRun({ id: "run-2", seed_id: "seed-b", status: "failed" });
    store.getRunsByStatuses.mockReturnValue([run1, run2]);
    taskClient.show.mockImplementation(async (id: string) => {
      if (id === "seed-a") return { status: "in_progress" };
      if (id === "seed-b") return { status: "in_progress" };
      return { status: "open" };
    });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.mismatches).toHaveLength(2);
    expect(result.synced).toBe(2);
  });

  it("covers failed/stuck/conflict/test-failed → open mapping", async () => {
    const { store, taskClient } = makeSyncMocks();
    for (const status of ["failed", "stuck", "conflict", "test-failed"] as const) {
      const run = makeRun({ seed_id: `seed-${status}`, status });
      store.getRunsByStatuses.mockReturnValue([run]);
      taskClient.show.mockResolvedValue({ status: "closed" }); // mismatch: expected open

      const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

      expect(result.mismatches[0]?.expectedSeedStatus).toBe("open");
    }
  });

  it("covers merged/pr-created → closed mapping", async () => {
    const { store, taskClient } = makeSyncMocks();
    for (const status of ["merged", "pr-created"] as const) {
      const run = makeRun({ seed_id: `seed-${status}`, status });
      store.getRunsByStatuses.mockReturnValue([run]);
      taskClient.show.mockResolvedValue({ status: "in_progress" }); // mismatch: expected closed

      const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

      expect(result.mismatches[0]?.expectedSeedStatus).toBe("closed");
    }
  });

  it("records error when br sync --flush-only fails, still returns results", async () => {
    const { store, taskClient } = makeSyncMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });
    mockExecBr.mockRejectedValue(new Error("br sync failed"));

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.synced).toBe(1); // update succeeded
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toContain("br sync --flush-only failed");
  });
});
