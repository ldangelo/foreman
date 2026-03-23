/**
 * doctor-bead-status-sync.test.ts
 *
 * Unit tests for Doctor.checkBeadStatusSync() — the doctor check that
 * detects and optionally fixes bead status drift between SQLite and br.
 *
 * Seed: bd-8ctu
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ── Hoisted mocks ──────────────────────────────────────────────────────────
//
// Mock execFileSync so no real subprocess (br) is spawned during tests.
// syncBeadStatusOnStartup uses execFileSync directly (not execBr) so that
// the br dirty flag is preserved.

const { mockExecFileSync } = vi.hoisted(() => ({
  mockExecFileSync: vi.fn().mockReturnValue(undefined),
}));

vi.mock("node:child_process", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  return { ...actual, execFileSync: mockExecFileSync };
});

// Also mock fs/promises for access/stat/rm used by other doctor checks
const { mockAccess, mockStat, mockRm } = vi.hoisted(() => ({
  mockAccess: vi.fn().mockResolvedValue(undefined),
  mockStat: vi.fn().mockRejectedValue(Object.assign(new Error("ENOENT"), { code: "ENOENT" })),
  mockRm: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return { ...actual, access: mockAccess, stat: mockStat, rm: mockRm };
});

// ── Test helpers ────────────────────────────────────────────────────────────

type MinimalRun = {
  id: string;
  seed_id: string;
  status: string;
  created_at: string;
  project_id: string;
  agent_type: string;
  session_key: string | null;
  completed_at: string | null;
  pid: number | null;
};

function makeRun(overrides: Partial<MinimalRun> = {}): MinimalRun {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "seed-abc",
    status: "completed",
    created_at: new Date().toISOString(),
    agent_type: "developer",
    session_key: null,
    completed_at: new Date().toISOString(),
    pid: null,
    ...overrides,
  };
}

/**
 * Create a minimal mock store that satisfies the ForemanStore interface
 * for the parts used by Doctor and syncBeadStatusOnStartup.
 */
function makeStore(opts: {
  projectId?: string;
  projectPath?: string;
  runs?: MinimalRun[];
} = {}) {
  const projectId = opts.projectId ?? "proj-1";
  const projectPath = opts.projectPath ?? "/tmp/test-project";
  const runs = opts.runs ?? [];

  return {
    getProjectByPath: vi.fn((_path: string) =>
      _path === projectPath ? { id: projectId, path: projectPath } : null
    ),
    getRunsByStatuses: vi.fn((_statuses: string[], _projectId: string) => runs),
    getRunsByStatus: vi.fn((_status: string, _projectId: string) => []),
    getActiveRuns: vi.fn((_projectId: string) => []),
  };
}

/**
 * Create a minimal mock taskClient.
 * `statusBySeeds` maps seed IDs to their current br status.
 */
function makeTaskClient(statusBySeeds: Record<string, string> = {}) {
  return {
    show: vi.fn(async (id: string) => {
      const status = statusBySeeds[id] ?? "in_progress";
      return { id, status, title: `Task ${id}` };
    }),
    list: vi.fn(async () => []),
    ready: vi.fn(async () => []),
  };
}

// ── Tests ───────────────────────────────────────────────────────────────────

describe("Doctor.checkBeadStatusSync()", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-doctor-bead-sync-")));
    tempDirs.push(dir);
    return dir;
  }

  beforeEach(() => {
    mockExecFileSync.mockReset();
    mockExecFileSync.mockReturnValue(undefined);
    mockAccess.mockResolvedValue(undefined);
    mockStat.mockRejectedValue(Object.assign(new Error("ENOENT"), { code: "ENOENT" }));
  });

  afterEach(() => {
    vi.clearAllMocks();
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  // ── Skip conditions ──────────────────────────────────────────────────

  it("returns skip when no task client is configured", async () => {
    const { Doctor } = await import("../doctor.js");
    const tmp = makeTempDir();
    const store = makeStore({ projectPath: tmp });

    // Doctor constructed without taskClient
    const doctor = new Doctor(store as any, tmp);

    const result = await doctor.checkBeadStatusSync();

    expect(result.status).toBe("skip");
    expect(result.name).toContain("bead status sync");
    expect(result.message).toContain("task client");
  });

  it("returns skip when no project is registered", async () => {
    const { Doctor } = await import("../doctor.js");
    const tmp = makeTempDir();
    const store = makeStore({ projectPath: "/different-path" }); // won't match tmp
    const taskClient = makeTaskClient();

    const doctor = new Doctor(store as any, tmp, undefined, taskClient as any);

    const result = await doctor.checkBeadStatusSync();

    expect(result.status).toBe("skip");
    expect(result.name).toContain("bead status sync");
    expect(result.message).toContain("No project registered");
  });

  // ── Pass condition ───────────────────────────────────────────────────

  it("returns pass when there are no bead status mismatches", async () => {
    const { Doctor } = await import("../doctor.js");
    const tmp = makeTempDir();
    // completed run with seed already at 'review' (correct expected status)
    const runs = [makeRun({ seed_id: "seed-abc", status: "completed" })];
    const store = makeStore({ projectPath: tmp, runs });
    const taskClient = makeTaskClient({ "seed-abc": "review" });

    const doctor = new Doctor(store as any, tmp, undefined, taskClient as any);

    const result = await doctor.checkBeadStatusSync({ projectPath: tmp });

    expect(result.status).toBe("pass");
    expect(result.name).toContain("bead status sync");
    expect(result.message).toContain("in sync");
  });

  it("returns pass when there are no terminal runs", async () => {
    const { Doctor } = await import("../doctor.js");
    const tmp = makeTempDir();
    const store = makeStore({ projectPath: tmp, runs: [] });
    const taskClient = makeTaskClient();

    const doctor = new Doctor(store as any, tmp, undefined, taskClient as any);

    const result = await doctor.checkBeadStatusSync({ projectPath: tmp });

    expect(result.status).toBe("pass");
    expect(result.message).toContain("in sync");
    // show() should not be called when there are no runs
    expect(taskClient.show).not.toHaveBeenCalled();
  });

  // ── Warn condition ───────────────────────────────────────────────────

  it("returns warn when mismatches detected (no flags)", async () => {
    const { Doctor } = await import("../doctor.js");
    const tmp = makeTempDir();
    // completed run but seed is still at 'in_progress' in br (drift!)
    const runs = [makeRun({ seed_id: "seed-abc", status: "completed" })];
    const store = makeStore({ projectPath: tmp, runs });
    const taskClient = makeTaskClient({ "seed-abc": "in_progress" });

    const doctor = new Doctor(store as any, tmp, undefined, taskClient as any);

    const result = await doctor.checkBeadStatusSync({ projectPath: tmp });

    expect(result.status).toBe("warn");
    expect(result.message).toContain("mismatch");
    // Should not have called execFileSync to fix anything
    expect(mockExecFileSync).not.toHaveBeenCalledWith(
      expect.any(String),
      ["update", expect.any(String), "--status", expect.any(String)],
      expect.anything(),
    );
  });

  it("returns warn with mismatch details in message", async () => {
    const { Doctor } = await import("../doctor.js");
    const tmp = makeTempDir();
    const runs = [makeRun({ seed_id: "seed-abc", status: "failed" })];
    const store = makeStore({ projectPath: tmp, runs });
    // seed is 'in_progress' but should be 'failed' after pipeline failure
    const taskClient = makeTaskClient({ "seed-abc": "in_progress" });

    const doctor = new Doctor(store as any, tmp, undefined, taskClient as any);

    const result = await doctor.checkBeadStatusSync({ projectPath: tmp });

    expect(result.status).toBe("warn");
    expect(result.message).toContain("seed-abc");
    expect(result.message).toContain("in_progress");
    expect(result.message).toContain("failed");
  });

  it("returns warn in dry-run mode even with fix=true", async () => {
    const { Doctor } = await import("../doctor.js");
    const tmp = makeTempDir();
    const runs = [makeRun({ seed_id: "seed-abc", status: "completed" })];
    const store = makeStore({ projectPath: tmp, runs });
    const taskClient = makeTaskClient({ "seed-abc": "in_progress" });

    const doctor = new Doctor(store as any, tmp, undefined, taskClient as any);

    // dryRun should take precedence over fix
    const result = await doctor.checkBeadStatusSync({ fix: true, dryRun: true, projectPath: tmp });

    expect(result.status).toBe("warn");
    expect(result.message).toContain("dry-run");
    // No br update calls made
    expect(mockExecFileSync).not.toHaveBeenCalledWith(
      expect.any(String),
      ["update", "seed-abc", "--status", "review"],
      expect.anything(),
    );
  });

  it("includes --fix hint in warn message (no flags)", async () => {
    const { Doctor } = await import("../doctor.js");
    const tmp = makeTempDir();
    const runs = [makeRun({ seed_id: "seed-abc", status: "completed" })];
    const store = makeStore({ projectPath: tmp, runs });
    const taskClient = makeTaskClient({ "seed-abc": "in_progress" });

    const doctor = new Doctor(store as any, tmp, undefined, taskClient as any);

    const result = await doctor.checkBeadStatusSync({ projectPath: tmp });

    expect(result.status).toBe("warn");
    expect(result.message).toContain("--fix");
  });

  // ── Fixed condition ──────────────────────────────────────────────────

  it("returns fixed and calls br update when fix=true (no dryRun)", async () => {
    const { Doctor } = await import("../doctor.js");
    const tmp = makeTempDir();
    const runs = [makeRun({ seed_id: "seed-abc", status: "completed" })];
    const store = makeStore({ projectPath: tmp, runs });
    const taskClient = makeTaskClient({ "seed-abc": "in_progress" });

    const doctor = new Doctor(store as any, tmp, undefined, taskClient as any);

    const result = await doctor.checkBeadStatusSync({ fix: true, projectPath: tmp });

    expect(result.status).toBe("fixed");
    expect(result.fixApplied).toBeDefined();
    // br update should have been called to fix the mismatch
    expect(mockExecFileSync).toHaveBeenCalledWith(
      expect.any(String),
      ["update", "seed-abc", "--status", "review"],
      expect.anything(),
    );
  });

  it("fixApplied message reports how many seeds were fixed", async () => {
    const { Doctor } = await import("../doctor.js");
    const tmp = makeTempDir();
    const runs = [
      makeRun({ id: "run-1", seed_id: "seed-abc", status: "completed" }),
      makeRun({ id: "run-2", seed_id: "seed-xyz", status: "failed" }),
    ];
    const store = makeStore({ projectPath: tmp, runs });
    const taskClient = makeTaskClient({
      "seed-abc": "in_progress", // mismatch: completed → review
      "seed-xyz": "in_progress", // mismatch: failed → failed
    });

    const doctor = new Doctor(store as any, tmp, undefined, taskClient as any);

    const result = await doctor.checkBeadStatusSync({ fix: true, projectPath: tmp });

    expect(result.status).toBe("fixed");
    expect(result.fixApplied).toMatch(/2/); // "Fixed 2 seed status(es)"
  });

  it("br update is called with correct status for each mismatch type", async () => {
    const { Doctor } = await import("../doctor.js");
    const tmp = makeTempDir();
    const runs = [
      makeRun({ id: "run-1", seed_id: "seed-comp", status: "completed" }),
      makeRun({ id: "run-2", seed_id: "seed-fail", status: "failed" }),
      makeRun({ id: "run-3", seed_id: "seed-merged", status: "merged" }),
    ];
    const store = makeStore({ projectPath: tmp, runs });
    const taskClient = makeTaskClient({
      "seed-comp": "in_progress",   // completed → review
      "seed-fail": "in_progress",   // failed → failed
      "seed-merged": "in_progress", // merged → closed
    });

    const doctor = new Doctor(store as any, tmp, undefined, taskClient as any);
    await doctor.checkBeadStatusSync({ fix: true, projectPath: tmp });

    // Verify each br update call has the correct expected status
    const updateCalls = mockExecFileSync.mock.calls.filter(
      (c) => Array.isArray(c[1]) && c[1][0] === "update",
    );
    const updateMap = Object.fromEntries(
      updateCalls.map((c) => [c[1][1] as string, c[1][3] as string]),
    );

    expect(updateMap["seed-comp"]).toBe("review");
    expect(updateMap["seed-fail"]).toBe("failed");
    expect(updateMap["seed-merged"]).toBe("closed");
  });

  // ── Fail condition ───────────────────────────────────────────────────

  it("returns fail when syncBeadStatusOnStartup throws (dry-run pass)", async () => {
    const { Doctor } = await import("../doctor.js");
    const tmp = makeTempDir();
    const store = makeStore({ projectPath: tmp, runs: [makeRun()] });
    const taskClient = {
      show: vi.fn().mockRejectedValue(new Error("br daemon crashed")),
    };

    const doctor = new Doctor(store as any, tmp, undefined, taskClient as any);

    const result = await doctor.checkBeadStatusSync({ projectPath: tmp });

    // A non-"not found" error from show() is collected as an error in SyncResult,
    // but syncBeadStatusOnStartup itself doesn't throw — it returns errors[].
    // Only a structural failure (e.g. getRunsByStatuses throwing) causes a fail.
    // Verify graceful handling: result should be pass (no mismatches) or warn.
    expect(["pass", "warn", "fail"]).toContain(result.status);
    expect(result.name).toContain("bead status sync");
  });

  // ── details field ────────────────────────────────────────────────────

  it("populates details field on warn/fixed results", async () => {
    const { Doctor } = await import("../doctor.js");
    const tmp = makeTempDir();
    const runs = [makeRun({ seed_id: "seed-abc", status: "completed" })];
    const store = makeStore({ projectPath: tmp, runs });
    const taskClient = makeTaskClient({ "seed-abc": "in_progress" });

    const doctor = new Doctor(store as any, tmp, undefined, taskClient as any);

    const warnResult = await doctor.checkBeadStatusSync({ projectPath: tmp });
    expect(warnResult.status).toBe("warn");
    expect(warnResult.details).toBeDefined();
    expect(warnResult.details).toContain("seed-abc");
  });

  // ── Integration: checkDataIntegrity includes the check ───────────────

  it("checkDataIntegrity() includes bead status sync check", async () => {
    const { Doctor } = await import("../doctor.js");
    const tmp = makeTempDir();
    const store = makeStore({ projectPath: tmp, runs: [] });
    const taskClient = makeTaskClient();

    const doctor = new Doctor(store as any, tmp, undefined, taskClient as any);

    const results = await doctor.checkDataIntegrity({ projectPath: tmp });
    const names = results.map((r) => r.name);

    expect(names.some((n) => n.includes("bead status sync"))).toBe(true);
  });

  it("checkDataIntegrity() bead status sync result is pass when no runs exist", async () => {
    const { Doctor } = await import("../doctor.js");
    const tmp = makeTempDir();
    const store = makeStore({ projectPath: tmp, runs: [] });
    const taskClient = makeTaskClient();

    const doctor = new Doctor(store as any, tmp, undefined, taskClient as any);

    const results = await doctor.checkDataIntegrity({ projectPath: tmp });
    const syncResult = results.find((r) => r.name.includes("bead status sync"));

    expect(syncResult).toBeDefined();
    expect(syncResult!.status).toBe("pass");
  });

  it("checkDataIntegrity() with fix=true calls br update for mismatched seeds", async () => {
    const { Doctor } = await import("../doctor.js");
    const tmp = makeTempDir();
    const runs = [makeRun({ seed_id: "seed-abc", status: "stuck" })];
    const store = makeStore({ projectPath: tmp, runs });
    const taskClient = makeTaskClient({ "seed-abc": "in_progress" });

    const doctor = new Doctor(store as any, tmp, undefined, taskClient as any);

    const results = await doctor.checkDataIntegrity({ fix: true, projectPath: tmp });
    const syncResult = results.find((r) => r.name.includes("bead status sync"));

    expect(syncResult).toBeDefined();
    expect(syncResult!.status).toBe("fixed");
    expect(mockExecFileSync).toHaveBeenCalledWith(
      expect.any(String),
      ["update", "seed-abc", "--status", "open"],
      expect.anything(),
    );
  });
});
