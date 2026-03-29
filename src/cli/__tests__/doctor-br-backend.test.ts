/**
 * Tests for TRD-020: doctor.ts binary checks after sd→br migration.
 *
 * Verifies:
 * - Doctor checks for br binary and bv binary (and git)
 * - Doctor does NOT check for the legacy sd (seeds) binary
 * - checkSystem() returns exactly 5 results (br + bv + git + git-town checks)
 * - Doctor.checkBrRecoveryArtifacts(): detects and optionally removes .br_recovery/ artifacts
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ── Hoisted mocks ──────────────────────────────────────────────────────────
const { mockAccess, mockStat, mockRm } = vi.hoisted(() => {
  const mockAccess = vi.fn().mockResolvedValue(undefined);
  const mockStat = vi.fn().mockResolvedValue({});
  const mockRm = vi.fn().mockResolvedValue(undefined);
  return { mockAccess, mockStat, mockRm };
});

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    access: mockAccess,
    stat: mockStat,
    rm: mockRm,
  };
});

// ── Unit tests: Doctor.checkBrBinary() ────────────────────────────────────

describe("TRD-020: Doctor.checkBrBinary()", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-doctor-br-")));
    tempDirs.push(dir);
    return dir;
  }

  afterEach(() => {
    vi.clearAllMocks();
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("checkBrBinary returns pass when br binary is accessible", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    mockAccess.mockResolvedValueOnce(undefined);

    const result = await doctor.checkBrBinary();

    expect(result.name).toContain("br");
    expect(result.status).toBe("pass");

    store.close();
  });

  it("checkBrBinary returns fail when br binary is not found", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    mockAccess.mockRejectedValueOnce(Object.assign(new Error("ENOENT"), { code: "ENOENT" }));

    const result = await doctor.checkBrBinary();

    expect(result.name).toContain("br");
    expect(result.status).toBe("fail");
    expect(result.message).toContain("cargo install beads_rust");

    store.close();
  });

  it("checkBrBinary result name includes 'br (beads_rust)'", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    mockAccess.mockResolvedValueOnce(undefined);

    const result = await doctor.checkBrBinary();

    expect(result.name).toMatch(/br.*beads_rust|beads_rust.*br/i);

    store.close();
  });

  it("checkBrBinary fail message contains install path ~/.local/bin/br", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    mockAccess.mockRejectedValueOnce(Object.assign(new Error("ENOENT"), { code: "ENOENT" }));

    const result = await doctor.checkBrBinary();

    expect(result.message).toContain(".local/bin/br");

    store.close();
  });
});

// ── Unit tests: Doctor.checkBvBinary() ────────────────────────────────────

describe("TRD-020: Doctor.checkBvBinary()", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-doctor-bv-")));
    tempDirs.push(dir);
    return dir;
  }

  afterEach(() => {
    vi.clearAllMocks();
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("checkBvBinary returns pass when bv binary is accessible", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    mockAccess.mockResolvedValueOnce(undefined);

    const result = await doctor.checkBvBinary();

    expect(result.name).toContain("bv");
    expect(result.status).toBe("pass");

    store.close();
  });

  it("checkBvBinary returns fail when bv binary is not found", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    mockAccess.mockRejectedValueOnce(Object.assign(new Error("ENOENT"), { code: "ENOENT" }));

    const result = await doctor.checkBvBinary();

    expect(result.name).toContain("bv");
    expect(result.status).toBe("fail");
    expect(result.message).toContain("beads_viewer");

    store.close();
  });

  it("checkBvBinary result name includes 'bv (beads_viewer)'", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    mockAccess.mockResolvedValueOnce(undefined);

    const result = await doctor.checkBvBinary();

    expect(result.name).toMatch(/bv.*beads_viewer|beads_viewer.*bv/i);

    store.close();
  });

  it("checkBvBinary fail message contains install path ~/.local/bin/bv", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    mockAccess.mockRejectedValueOnce(Object.assign(new Error("ENOENT"), { code: "ENOENT" }));

    const result = await doctor.checkBvBinary();

    expect(result.message).toContain(".local/bin/bv");

    store.close();
  });
});

// ── Doctor.checkSystem() checks ───────────────────────────────────────────

describe("TRD-020: Doctor.checkSystem() checks (br backend only)", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-doctor-system-")));
    tempDirs.push(dir);
    return dir;
  }

  beforeEach(() => {
    // Allow access calls to succeed by default (binaries "found")
    mockAccess.mockResolvedValue(undefined);
  });

  afterEach(() => {
    vi.clearAllMocks();
    vi.unstubAllEnvs();
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("checkSystem() includes git check", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    const results = await doctor.checkSystem();
    const names = results.map((r) => r.name);

    expect(names.some((n) => n.includes("git"))).toBe(true);
    store.close();
  });

  it("checkSystem() includes br check", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    const results = await doctor.checkSystem();
    const names = results.map((r) => r.name);

    expect(names.some((n) => n.toLowerCase().includes("br"))).toBe(true);
    store.close();
  });

  it("checkSystem() includes bv check", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    const results = await doctor.checkSystem();
    const names = results.map((r) => r.name);

    expect(names.some((n) => n.toLowerCase().includes("bv"))).toBe(true);
    store.close();
  });

  it("checkSystem() does NOT include legacy sd (seeds) check", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    const results = await doctor.checkSystem();
    const names = results.map((r) => r.name);

    expect(names.some((n) => n.toLowerCase().includes("sd (seeds)"))).toBe(false);
    store.close();
  });

  it("checkSystem() returns exactly 8 results (br + bv + git + jj-binary + jj-colocated + git-town-installed + git-town-main-branch + old-logs)", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    const results = await doctor.checkSystem();

    // TRD-028 added checkJujutsuBinary() and checkJujutsuColocated() to checkSystem()
    expect(results).toHaveLength(8);
    store.close();
  });
});

// ── Unit tests: Doctor.checkBrRecoveryArtifacts() ─────────────────────────

describe("Doctor.checkBrRecoveryArtifacts()", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-doctor-recovery-")));
    tempDirs.push(dir);
    return dir;
  }

  afterEach(() => {
    vi.clearAllMocks();
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("returns pass when .br_recovery/ does not exist", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    // stat throws ENOENT — directory does not exist
    mockStat.mockRejectedValueOnce(Object.assign(new Error("ENOENT"), { code: "ENOENT" }));

    const result = await doctor.checkBrRecoveryArtifacts();

    expect(result.status).toBe("pass");
    expect(result.message).toContain("No stale recovery artifacts");

    store.close();
  });

  it("returns warn when .br_recovery/ exists (no flags)", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    // stat resolves — directory exists
    mockStat.mockResolvedValueOnce({});

    const result = await doctor.checkBrRecoveryArtifacts();

    expect(result.status).toBe("warn");
    expect(result.name).toContain(".br_recovery");
    expect(result.message).toContain(".br_recovery/");

    store.close();
  });

  it("returns warn (dry-run) when .br_recovery/ exists with dryRun=true", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    mockStat.mockResolvedValueOnce({});

    const result = await doctor.checkBrRecoveryArtifacts({ dryRun: true });

    expect(result.status).toBe("warn");
    expect(result.message).toContain("dry-run");
    expect(mockRm).not.toHaveBeenCalled();

    store.close();
  });

  it("returns fixed and calls rm when .br_recovery/ exists with fix=true", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    mockStat.mockResolvedValueOnce({});
    mockRm.mockResolvedValueOnce(undefined);

    const result = await doctor.checkBrRecoveryArtifacts({ fix: true });

    expect(result.status).toBe("fixed");
    expect(result.fixApplied).toBeDefined();
    expect(result.fixApplied).toContain(".br_recovery");
    expect(mockRm).toHaveBeenCalledWith(
      expect.stringContaining(".br_recovery"),
      { recursive: true, force: true },
    );

    store.close();
  });

  it("returns warn when fix=true but rm throws an error", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    mockStat.mockResolvedValueOnce({});
    mockRm.mockRejectedValueOnce(new Error("EPERM: operation not permitted"));

    const result = await doctor.checkBrRecoveryArtifacts({ fix: true });

    expect(result.status).toBe("warn");
    expect(result.message).toContain("could not auto-remove");

    store.close();
  });

  it("dryRun takes precedence over fix when both are true (no rm called, returns warn)", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    mockStat.mockResolvedValueOnce({});

    // Both fix and dryRun are true — dryRun must win
    const result = await doctor.checkBrRecoveryArtifacts({ fix: true, dryRun: true });

    expect(result.status).toBe("warn");
    expect(result.message).toContain("dry-run");
    expect(mockRm).not.toHaveBeenCalled();

    store.close();
  });

  it("warn message (no flags) tells user to use --fix or run br doctor --repair", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    mockStat.mockResolvedValueOnce({});

    const result = await doctor.checkBrRecoveryArtifacts();

    expect(result.status).toBe("warn");
    // Message should guide users to either --fix (if recovery succeeded) or br doctor --repair (to retry)
    expect(result.message).toMatch(/--fix/);
    expect(result.message).toMatch(/br doctor --repair/);

    store.close();
  });

  it("checkBrRecoveryArtifacts result name contains '.br_recovery'", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    mockStat.mockResolvedValueOnce({});

    const result = await doctor.checkBrRecoveryArtifacts();

    expect(result.name).toContain(".br_recovery");

    store.close();
  });

  it("checkDataIntegrity() includes br recovery artifacts check", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    store.registerProject("test", tmp);
    const doctor = new Doctor(store, tmp);

    // Allow all stat/access calls to succeed or ENOENT as needed
    mockStat.mockResolvedValue({});
    mockAccess.mockResolvedValue(undefined);

    const results = await doctor.checkDataIntegrity();
    const names = results.map((r) => r.name);

    expect(names.some((n) => n.includes(".br_recovery"))).toBe(true);

    store.close();
  });
});
