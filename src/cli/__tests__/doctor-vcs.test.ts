/**
 * doctor-vcs.test.ts
 *
 * Unit tests for TRD-028: Doctor.checkJujutsuBinary() and Doctor.checkJujutsuColocated().
 *
 * Verifies:
 * - AC-T-028-1: jj binary missing + backend=jujutsu → status=fail, message contains "ERROR" and GitHub URL
 * - AC-T-028-2: jj binary missing + backend=auto    → status=warn, message contains "WARNING"
 * - AC-T-028-3: backend=jujutsu + .jj/repo/store/git missing → status=fail, message contains "colocated"
 *
 * Seed: bd-g43l
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, realpathSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ── Hoisted mocks ──────────────────────────────────────────────────────────
//
// Mock execFile so no real jj or git subprocess is spawned.
// Mock stat so no real filesystem checks are needed.

const { mockExecFile, mockStat } = vi.hoisted(() => {
  return {
    mockExecFile: vi.fn(),
    mockStat: vi.fn(),
  };
});

vi.mock("node:child_process", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  return {
    ...actual,
    execFile: mockExecFile,
  };
});

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    stat: mockStat,
  };
});

// ── Test helpers ────────────────────────────────────────────────────────────

/**
 * Extract the callback from execFile-style arguments.
 *
 * `util.promisify(mockExecFile)` appends the callback as the last argument,
 * so the number of args varies:
 *   - No opts: mockExecFile(cmd, args, callback)         — 3 args
 *   - With opts: mockExecFile(cmd, args, opts, callback) — 4 args
 *
 * This helper retrieves the last argument as the callback.
 */
function extractCallback(
  allArgs: unknown[],
): (err: Error | null, result?: unknown) => void {
  return allArgs[allArgs.length - 1] as (err: Error | null, result?: unknown) => void;
}

/**
 * Configure mockExecFile to simulate jj being found in PATH.
 * Returns "jj 0.21.0" as the version string.
 *
 * Note: util.promisify wraps the execFile callback as (err, value) — NOT (err, stdout, stderr).
 * For the promisified result to be { stdout, stderr }, we pass the object as the single value arg.
 */
function mockJjFound(): void {
  mockExecFile.mockImplementation((...allArgs: unknown[]) => {
    const cmd = allArgs[0] as string;
    const args = allArgs[1] as string[];
    const callback = extractCallback(allArgs);
    if (cmd === "jj" && args[0] === "--version") {
      callback(null, { stdout: "jj 0.21.0\n", stderr: "" });
    } else {
      callback(null, { stdout: "", stderr: "" });
    }
  });
}

/**
 * Configure mockExecFile to simulate jj NOT found in PATH (ENOENT error).
 */
function mockJjNotFound(): void {
  mockExecFile.mockImplementation((...allArgs: unknown[]) => {
    const cmd = allArgs[0] as string;
    const args = allArgs[1] as string[];
    const callback = extractCallback(allArgs);
    if (cmd === "jj" && args[0] === "--version") {
      const err = Object.assign(new Error("jj: command not found"), {
        code: "ENOENT",
      });
      callback(err);
    } else {
      callback(null, { stdout: "", stderr: "" });
    }
  });
}

/**
 * Configure mockStat to simulate .jj/repo/store/git existing (colocated mode).
 */
function mockColocatedMode(): void {
  mockStat.mockResolvedValue({} as ReturnType<typeof import("node:fs/promises").stat>);
}

/**
 * Configure mockStat to simulate .jj/repo/store/git NOT existing (non-colocated mode).
 */
function mockNonColocatedMode(): void {
  mockStat.mockRejectedValue(
    Object.assign(new Error("ENOENT: no such file or directory"), { code: "ENOENT" }),
  );
}

/**
 * Write a minimal .foreman/config.yaml to a temp directory, specifying a VCS backend.
 */
function writeVcsConfig(projectPath: string, backend: "git" | "jujutsu" | "auto"): void {
  const foremanDir = join(projectPath, ".foreman");
  mkdirSync(foremanDir, { recursive: true });
  writeFileSync(join(foremanDir, "config.yaml"), `vcs:\n  backend: ${backend}\n`, "utf-8");
}

// ── Tests ───────────────────────────────────────────────────────────────────

describe("TRD-028: Doctor VCS Checks", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-doctor-vcs-")));
    tempDirs.push(dir);
    return dir;
  }

  beforeEach(() => {
    vi.resetAllMocks();
    // Default: stat fails (non-colocated) and execFile succeeds with empty output
    mockStat.mockRejectedValue(
      Object.assign(new Error("ENOENT"), { code: "ENOENT" }),
    );
    mockExecFile.mockImplementation((...allArgs: unknown[]) => {
      const callback = extractCallback(allArgs);
      callback(null, { stdout: "", stderr: "" });
    });
  });

  afterEach(() => {
    vi.clearAllMocks();
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  // ── AC-T-028-1: jj missing with backend=jujutsu ──────────────────────────

  describe("AC-T-028-1: jj binary missing with backend=jujutsu", () => {
    it("returns status=fail when jj binary is not found and backend=jujutsu", async () => {
      const { Doctor } = await import("../../orchestrator/doctor.js");
      const { ForemanStore } = await import("../../lib/store.js");

      const tmp = makeTempDir();
      writeVcsConfig(tmp, "jujutsu");
      mockJjNotFound();

      const store = new ForemanStore(join(tmp, "test.db"));
      const doctor = new Doctor(store, tmp);

      const result = await doctor.checkJujutsuBinary();

      expect(result.status).toBe("fail");
      store.close();
    });

    it("error message contains 'ERROR' when jj not found and backend=jujutsu", async () => {
      const { Doctor } = await import("../../orchestrator/doctor.js");
      const { ForemanStore } = await import("../../lib/store.js");

      const tmp = makeTempDir();
      writeVcsConfig(tmp, "jujutsu");
      mockJjNotFound();

      const store = new ForemanStore(join(tmp, "test.db"));
      const doctor = new Doctor(store, tmp);

      const result = await doctor.checkJujutsuBinary();

      expect(result.message).toContain("ERROR");
      store.close();
    });

    it("error message contains GitHub install URL when jj not found and backend=jujutsu", async () => {
      const { Doctor } = await import("../../orchestrator/doctor.js");
      const { ForemanStore } = await import("../../lib/store.js");

      const tmp = makeTempDir();
      writeVcsConfig(tmp, "jujutsu");
      mockJjNotFound();

      const store = new ForemanStore(join(tmp, "test.db"));
      const doctor = new Doctor(store, tmp);

      const result = await doctor.checkJujutsuBinary();

      expect(result.message).toContain("https://github.com/jj-vcs/jj");
      store.close();
    });

    it("returns status=pass when jj binary is found with backend=jujutsu", async () => {
      const { Doctor } = await import("../../orchestrator/doctor.js");
      const { ForemanStore } = await import("../../lib/store.js");

      const tmp = makeTempDir();
      writeVcsConfig(tmp, "jujutsu");
      mockJjFound();

      const store = new ForemanStore(join(tmp, "test.db"));
      const doctor = new Doctor(store, tmp);

      const result = await doctor.checkJujutsuBinary();

      expect(result.status).toBe("pass");
      store.close();
    });
  });

  // ── AC-T-028-2: jj missing with backend=auto ─────────────────────────────

  describe("AC-T-028-2: jj binary missing with backend=auto", () => {
    it("returns status=warn (not fail) when jj not found and backend=auto", async () => {
      const { Doctor } = await import("../../orchestrator/doctor.js");
      const { ForemanStore } = await import("../../lib/store.js");

      const tmp = makeTempDir();
      writeVcsConfig(tmp, "auto");
      mockJjNotFound();

      const store = new ForemanStore(join(tmp, "test.db"));
      const doctor = new Doctor(store, tmp);

      const result = await doctor.checkJujutsuBinary();

      expect(result.status).toBe("warn");
      expect(result.status).not.toBe("fail");
      store.close();
    });

    it("warning message contains 'WARNING' when jj not found and backend=auto", async () => {
      const { Doctor } = await import("../../orchestrator/doctor.js");
      const { ForemanStore } = await import("../../lib/store.js");

      const tmp = makeTempDir();
      writeVcsConfig(tmp, "auto");
      mockJjNotFound();

      const store = new ForemanStore(join(tmp, "test.db"));
      const doctor = new Doctor(store, tmp);

      const result = await doctor.checkJujutsuBinary();

      expect(result.message).toContain("WARNING");
      store.close();
    });

    it("warning message does NOT contain 'ERROR' when backend=auto", async () => {
      const { Doctor } = await import("../../orchestrator/doctor.js");
      const { ForemanStore } = await import("../../lib/store.js");

      const tmp = makeTempDir();
      writeVcsConfig(tmp, "auto");
      mockJjNotFound();

      const store = new ForemanStore(join(tmp, "test.db"));
      const doctor = new Doctor(store, tmp);

      const result = await doctor.checkJujutsuBinary();

      expect(result.message).not.toContain("ERROR");
      store.close();
    });

    it("returns status=skip when backend=git", async () => {
      const { Doctor } = await import("../../orchestrator/doctor.js");
      const { ForemanStore } = await import("../../lib/store.js");

      const tmp = makeTempDir();
      writeVcsConfig(tmp, "git");
      mockJjNotFound();

      const store = new ForemanStore(join(tmp, "test.db"));
      const doctor = new Doctor(store, tmp);

      const result = await doctor.checkJujutsuBinary();

      expect(result.status).toBe("skip");
      store.close();
    });

    it("uses auto backend when no config file exists", async () => {
      const { Doctor } = await import("../../orchestrator/doctor.js");
      const { ForemanStore } = await import("../../lib/store.js");

      const tmp = makeTempDir();
      // No config file written — defaults to auto
      mockJjNotFound();

      const store = new ForemanStore(join(tmp, "test.db"));
      const doctor = new Doctor(store, tmp);

      const result = await doctor.checkJujutsuBinary();

      // Should be warn (auto) not fail (jujutsu)
      expect(result.status).toBe("warn");
      store.close();
    });
  });

  // ── AC-T-028-3: Non-colocated Jujutsu repository ─────────────────────────

  describe("AC-T-028-3: non-colocated Jujutsu repository", () => {
    it("returns status=fail when .jj/repo/store/git is missing with backend=jujutsu", async () => {
      const { Doctor } = await import("../../orchestrator/doctor.js");
      const { ForemanStore } = await import("../../lib/store.js");

      const tmp = makeTempDir();
      writeVcsConfig(tmp, "jujutsu");
      mockNonColocatedMode();

      const store = new ForemanStore(join(tmp, "test.db"));
      const doctor = new Doctor(store, tmp);

      const result = await doctor.checkJujutsuColocated();

      expect(result.status).toBe("fail");
      store.close();
    });

    it("error message mentions 'colocated' when .jj/repo/store/git is missing", async () => {
      const { Doctor } = await import("../../orchestrator/doctor.js");
      const { ForemanStore } = await import("../../lib/store.js");

      const tmp = makeTempDir();
      writeVcsConfig(tmp, "jujutsu");
      mockNonColocatedMode();

      const store = new ForemanStore(join(tmp, "test.db"));
      const doctor = new Doctor(store, tmp);

      const result = await doctor.checkJujutsuColocated();

      expect(result.message).toContain("colocated");
      store.close();
    });

    it("returns status=pass when .jj/repo/store/git exists", async () => {
      const { Doctor } = await import("../../orchestrator/doctor.js");
      const { ForemanStore } = await import("../../lib/store.js");

      const tmp = makeTempDir();
      writeVcsConfig(tmp, "jujutsu");
      mockColocatedMode();

      const store = new ForemanStore(join(tmp, "test.db"));
      const doctor = new Doctor(store, tmp);

      const result = await doctor.checkJujutsuColocated();

      expect(result.status).toBe("pass");
      store.close();
    });

    it("returns status=skip when backend=auto", async () => {
      const { Doctor } = await import("../../orchestrator/doctor.js");
      const { ForemanStore } = await import("../../lib/store.js");

      const tmp = makeTempDir();
      writeVcsConfig(tmp, "auto");

      const store = new ForemanStore(join(tmp, "test.db"));
      const doctor = new Doctor(store, tmp);

      const result = await doctor.checkJujutsuColocated();

      expect(result.status).toBe("skip");
      store.close();
    });

    it("returns status=skip when backend=git", async () => {
      const { Doctor } = await import("../../orchestrator/doctor.js");
      const { ForemanStore } = await import("../../lib/store.js");

      const tmp = makeTempDir();
      writeVcsConfig(tmp, "git");

      const store = new ForemanStore(join(tmp, "test.db"));
      const doctor = new Doctor(store, tmp);

      const result = await doctor.checkJujutsuColocated();

      expect(result.status).toBe("skip");
      store.close();
    });

    it("returns status=skip when no config file exists (defaults to auto)", async () => {
      const { Doctor } = await import("../../orchestrator/doctor.js");
      const { ForemanStore } = await import("../../lib/store.js");

      const tmp = makeTempDir();
      // No config — defaults to auto

      const store = new ForemanStore(join(tmp, "test.db"));
      const doctor = new Doctor(store, tmp);

      const result = await doctor.checkJujutsuColocated();

      expect(result.status).toBe("skip");
      store.close();
    });
  });

  // ── checkSystem() integration ─────────────────────────────────────────────

  describe("checkSystem() includes VCS checks", () => {
    it("checkSystem() includes jj binary check result", async () => {
      const { Doctor } = await import("../../orchestrator/doctor.js");
      const { ForemanStore } = await import("../../lib/store.js");

      const tmp = makeTempDir();
      writeVcsConfig(tmp, "jujutsu");
      mockJjFound();
      mockColocatedMode();

      const store = new ForemanStore(join(tmp, "test.db"));
      const doctor = new Doctor(store, tmp);

      const results = await doctor.checkSystem();
      const jjCheck = results.find((r) => r.name.toLowerCase().includes("jj"));

      expect(jjCheck).toBeDefined();
      store.close();
    });
  });
});
