/**
 * Tests for TRD-020: doctor.ts binary checks after sd→br migration.
 *
 * Verifies:
 * - Doctor checks for br binary and bv binary (and git)
 * - Doctor does NOT check for the legacy sd (seeds) binary
 * - checkSystem() returns exactly 3 results (br + bv + git)
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ── Hoisted mocks ──────────────────────────────────────────────────────────
const { mockAccess, mockStat } = vi.hoisted(() => {
  const mockAccess = vi.fn().mockResolvedValue(undefined);
  const mockStat = vi.fn().mockResolvedValue({});
  return { mockAccess, mockStat };
});

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    access: mockAccess,
    stat: mockStat,
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

  it("checkSystem() returns exactly 3 results (br + bv + git)", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const tmpDb = join(tmp, "test.db");
    const store = new ForemanStore(tmpDb);
    const doctor = new Doctor(store, tmp);

    const results = await doctor.checkSystem();

    expect(results).toHaveLength(3);
    store.close();
  });
});
