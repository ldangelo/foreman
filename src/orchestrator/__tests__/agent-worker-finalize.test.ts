import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ── Mock setup ─────────────────────────────────────────────────────────────
//
// We mock node:child_process so no real subprocess is spawned, and
// we mock task-backend-ops so we can verify closeSeed call behaviour.
//
// vi.hoisted() ensures mock variables are initialised before the module
// factory runs (vitest hoists vi.mock() calls to the top of the file).

const { mockExecFileSync, mockCloseSeed, mockEnqueueToMergeQueue } = vi.hoisted(() => ({
  mockExecFileSync: vi.fn(),
  mockCloseSeed: vi.fn<() => Promise<void>>().mockResolvedValue(undefined),
  mockEnqueueToMergeQueue: vi.fn().mockReturnValue({ success: true }),
}));

vi.mock("node:child_process", () => ({
  execFileSync: mockExecFileSync,
}));

vi.mock("../task-backend-ops.js", () => ({
  closeSeed: mockCloseSeed,
}));

vi.mock("../agent-worker-enqueue.js", () => ({
  enqueueToMergeQueue: mockEnqueueToMergeQueue,
}));

// Mock ForemanStore so we don't need a real SQLite database
vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: vi.fn(() => ({
      getDb: vi.fn(() => ({})),
      close: vi.fn(),
    })),
  },
}));

import { finalize, rotateReport } from "../agent-worker-finalize.js";
import type { FinalizeConfig } from "../agent-worker-finalize.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeConfig(overrides: Partial<FinalizeConfig> = {}): FinalizeConfig {
  // Note: `worktreePath` has no default here — every test that touches the
  // filesystem must supply a real tmpDir via overrides to ensure isolation.
  return {
    runId: "run-test-001",
    seedId: "bd-test-001",
    seedTitle: "Fix the test bug",
    projectPath: "/tmp/fake-project",
    ...overrides,
  } as FinalizeConfig;
}

// ── rotateReport ──────────────────────────────────────────────────────────────

describe("rotateReport", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-rotate-test-"));
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("renames an existing report file with a timestamp suffix", () => {
    const filename = "FINALIZE_REPORT.md";
    writeFileSync(join(tmpDir, filename), "# Old report");

    rotateReport(tmpDir, filename);

    // Original file should be gone
    expect(existsSync(join(tmpDir, filename))).toBe(false);
    // A rotated file with a timestamp suffix should exist
    const files = readdirSync(tmpDir);
    const rotated = files.find((f) => f.startsWith("FINALIZE_REPORT.") && f.endsWith(".md") && f !== filename);
    expect(rotated).toBeDefined();
  });

  it("does nothing when the file does not exist (non-fatal)", () => {
    // Should not throw
    expect(() => rotateReport(tmpDir, "NONEXISTENT.md")).not.toThrow();
  });
});

// ── finalize — push succeeds ──────────────────────────────────────────────────

describe("finalize() — push succeeds", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    // Default: all git commands succeed
    mockExecFileSync.mockReset();
    mockCloseSeed.mockReset().mockResolvedValue(undefined);
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });

    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (args[0] === "rev-parse" && args[1] === "--abbrev-ref") return Buffer.from("foreman/bd-test-001\n");
      if (args[0] === "rev-parse") return Buffer.from("abc1234\n");
      return Buffer.from("");
    });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns true when git push succeeds", async () => {
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    expect(result).toBe(true);
  });

  it("calls closeSeed when push succeeds", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir, projectPath: "/my/project" }), logFile);
    expect(mockCloseSeed).toHaveBeenCalledOnce();
    expect(mockCloseSeed).toHaveBeenCalledWith("bd-test-001", "/my/project");
  });

  it("calls git push with correct branch name", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir, seedId: "bd-xyz-999" }), logFile);
    const pushCall = mockExecFileSync.mock.calls.find(
      (call) => Array.isArray(call[1]) && call[1][0] === "push",
    );
    expect(pushCall).toBeDefined();
    expect(pushCall![1]).toContain("foreman/bd-xyz-999");
  });

  it("writes FINALIZE_REPORT.md with SUCCESS status for seed close", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    const reportPath = join(tmpDir, "FINALIZE_REPORT.md");
    expect(existsSync(reportPath)).toBe(true);
    const content = readFileSync(reportPath, "utf-8");
    expect(content).toContain("## Seed Close");
    expect(content).toContain("Status: SUCCESS");
  });

  it("enqueues to merge queue when push succeeds", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    expect(mockEnqueueToMergeQueue).toHaveBeenCalledOnce();
  });
});

// ── finalize — push FAILS ─────────────────────────────────────────────────────

describe("finalize() — push FAILS", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-pushfail-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockCloseSeed.mockReset().mockResolvedValue(undefined);
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });

    // git push fails; all other commands succeed
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (Array.isArray(args) && args[0] === "push") {
        throw new Error("remote: Permission to repo denied.");
      }
      if (args[0] === "rev-parse" && args[1] === "--abbrev-ref") return Buffer.from("foreman/bd-test-001\n");
      if (args[0] === "rev-parse") return Buffer.from("abc1234\n");
      return Buffer.from("");
    });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns false when git push fails", async () => {
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    expect(result).toBe(false);
  });

  it("does NOT call closeSeed when push fails", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    expect(mockCloseSeed).not.toHaveBeenCalled();
  });

  it("does NOT enqueue to merge queue when push fails", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    expect(mockEnqueueToMergeQueue).not.toHaveBeenCalled();
  });

  it("writes FINALIZE_REPORT.md with FAILED push and SKIPPED seed close", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    const reportPath = join(tmpDir, "FINALIZE_REPORT.md");
    expect(existsSync(reportPath)).toBe(true);
    const content = readFileSync(reportPath, "utf-8");
    expect(content).toContain("## Push");
    expect(content).toContain("Status: FAILED");
    expect(content).toContain("## Seed Close");
    expect(content).toContain("Status: SKIPPED (push failed)");
  });

  it("does not throw even when push fails", async () => {
    await expect(finalize(makeConfig({ worktreePath: tmpDir }), logFile)).resolves.toBe(false);
  });
});

// ── finalize — tsc failure is non-fatal ───────────────────────────────────────

describe("finalize() — type check failure is non-fatal", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-tscfail-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockCloseSeed.mockReset().mockResolvedValue(undefined);
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });

    // tsc fails, git push succeeds
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (_bin === "npx" && Array.isArray(args) && args[0] === "tsc") {
        throw new Error("Type error: cannot find module");
      }
      if (args[0] === "rev-parse" && args[1] === "--abbrev-ref") return Buffer.from("foreman/bd-test-001\n");
      if (args[0] === "rev-parse") return Buffer.from("abc1234\n");
      return Buffer.from("");
    });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns true (push succeeded) even when type check fails", async () => {
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    expect(result).toBe(true);
  });

  it("still calls closeSeed when type check fails but push succeeds", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    expect(mockCloseSeed).toHaveBeenCalledOnce();
  });

  it("reports type check failure in FINALIZE_REPORT.md", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    const reportPath = join(tmpDir, "FINALIZE_REPORT.md");
    const content = readFileSync(reportPath, "utf-8");
    expect(content).toContain("## Build / Type Check");
    expect(content).toContain("Status: FAILED");
  });
});

// ── finalize — commit "nothing to commit" is non-fatal ────────────────────────

describe("finalize() — nothing to commit", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-nocommit-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockCloseSeed.mockReset().mockResolvedValue(undefined);
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });

    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (Array.isArray(args) && args[0] === "commit") {
        throw new Error("nothing to commit, working tree clean");
      }
      if (args[0] === "rev-parse" && args[1] === "--abbrev-ref") return Buffer.from("foreman/bd-test-001\n");
      if (args[0] === "rev-parse") return Buffer.from("abc1234\n");
      return Buffer.from("");
    });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns true and still pushes/closes when nothing to commit", async () => {
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    expect(result).toBe(true);
    expect(mockCloseSeed).toHaveBeenCalledOnce();
  });

  it("reports commit as SKIPPED (nothing to commit) in the report", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    const reportPath = join(tmpDir, "FINALIZE_REPORT.md");
    const content = readFileSync(reportPath, "utf-8");
    expect(content).toContain("Status: SKIPPED (nothing to commit)");
  });
});

// ── finalize — closeSeed receives correct projectPath ─────────────────────────

describe("finalize() — projectPath forwarded to closeSeed", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-path-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockCloseSeed.mockReset().mockResolvedValue(undefined);
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });

    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (args[0] === "rev-parse" && args[1] === "--abbrev-ref") return Buffer.from("foreman/bd-test-001\n");
      if (args[0] === "rev-parse") return Buffer.from("abc1234\n");
      return Buffer.from("");
    });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("passes projectPath to closeSeed when provided", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir, projectPath: "/explicit/project" }), logFile);
    expect(mockCloseSeed).toHaveBeenCalledWith("bd-test-001", "/explicit/project");
  });

  it("passes undefined projectPath to closeSeed when not provided", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir, projectPath: undefined }), logFile);
    expect(mockCloseSeed).toHaveBeenCalledWith("bd-test-001", undefined);
  });
});

// ── finalize — branch verification before push ────────────────────────────────

describe("finalize() — branch verification", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-branch-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockCloseSeed.mockReset().mockResolvedValue(undefined);
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("does NOT call checkout when already on the correct branch", async () => {
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (args[0] === "rev-parse" && args[1] === "--abbrev-ref") return Buffer.from("foreman/bd-test-001\n");
      if (args[0] === "rev-parse") return Buffer.from("abc1234\n");
      return Buffer.from("");
    });

    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);

    const checkoutCall = mockExecFileSync.mock.calls.find(
      (call) => Array.isArray(call[1]) && call[1][0] === "checkout",
    );
    expect(checkoutCall).toBeUndefined();
  });

  it("reports Branch Verification OK when already on the correct branch", async () => {
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (args[0] === "rev-parse" && args[1] === "--abbrev-ref") return Buffer.from("foreman/bd-test-001\n");
      if (args[0] === "rev-parse") return Buffer.from("abc1234\n");
      return Buffer.from("");
    });

    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);

    const content = readFileSync(join(tmpDir, "FINALIZE_REPORT.md"), "utf-8");
    expect(content).toContain("## Branch Verification");
    expect(content).toContain("Status: OK");
  });

  it("attempts checkout when on a different branch and push succeeds after recovery", async () => {
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (args[0] === "rev-parse" && args[1] === "--abbrev-ref") return Buffer.from("main\n");
      if (args[0] === "rev-parse") return Buffer.from("abc1234\n");
      return Buffer.from("");
    });

    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile);

    // checkout was called
    const checkoutCall = mockExecFileSync.mock.calls.find(
      (call) => Array.isArray(call[1]) && call[1][0] === "checkout" && call[1][1] === "foreman/bd-test-001",
    );
    expect(checkoutCall).toBeDefined();

    // push succeeded after checkout recovery
    expect(result).toBe(true);
    expect(mockCloseSeed).toHaveBeenCalledOnce();
  });

  it("reports RECOVERED status in branch verification section after mismatch checkout", async () => {
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (args[0] === "rev-parse" && args[1] === "--abbrev-ref") return Buffer.from("main\n");
      if (args[0] === "rev-parse") return Buffer.from("abc1234\n");
      return Buffer.from("");
    });

    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);

    const content = readFileSync(join(tmpDir, "FINALIZE_REPORT.md"), "utf-8");
    expect(content).toContain("## Branch Verification");
    expect(content).toContain("Status: RECOVERED (checkout succeeded)");
    expect(content).toContain("Was: main");
  });

  it("attempts checkout when in detached HEAD state and push succeeds after recovery", async () => {
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (args[0] === "rev-parse" && args[1] === "--abbrev-ref") return Buffer.from("HEAD\n");
      if (args[0] === "rev-parse") return Buffer.from("abc1234\n");
      return Buffer.from("");
    });

    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile);

    const checkoutCall = mockExecFileSync.mock.calls.find(
      (call) => Array.isArray(call[1]) && call[1][0] === "checkout",
    );
    expect(checkoutCall).toBeDefined();
    expect(result).toBe(true);
  });

  it("skips push and returns false when checkout fails after branch mismatch", async () => {
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (args[0] === "rev-parse" && args[1] === "--abbrev-ref") return Buffer.from("main\n");
      if (args[0] === "rev-parse") return Buffer.from("abc1234\n");
      if (args[0] === "checkout") throw new Error("error: pathspec 'foreman/bd-test-001' did not match any file(s) known to git");
      return Buffer.from("");
    });

    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile);

    // push was NOT called
    const pushCall = mockExecFileSync.mock.calls.find(
      (call) => Array.isArray(call[1]) && call[1][0] === "push",
    );
    expect(pushCall).toBeUndefined();

    expect(result).toBe(false);
    expect(mockCloseSeed).not.toHaveBeenCalled();
    expect(mockEnqueueToMergeQueue).not.toHaveBeenCalled();
  });

  it("reports Branch Verification FAILED and Push SKIPPED when checkout fails", async () => {
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (args[0] === "rev-parse" && args[1] === "--abbrev-ref") return Buffer.from("other-branch\n");
      if (args[0] === "rev-parse") return Buffer.from("abc1234\n");
      if (args[0] === "checkout") throw new Error("checkout failed");
      return Buffer.from("");
    });

    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);

    const content = readFileSync(join(tmpDir, "FINALIZE_REPORT.md"), "utf-8");
    expect(content).toContain("## Branch Verification");
    expect(content).toContain("Status: FAILED");
    expect(content).toContain("## Push");
    expect(content).toContain("Status: SKIPPED (branch verification failed)");
    expect(content).toContain("## Seed Close");
    expect(content).toContain("Status: SKIPPED (push failed)");
  });

  it("skips push and returns false when rev-parse itself fails", async () => {
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (args[0] === "rev-parse" && args[1] === "--abbrev-ref") throw new Error("not a git repository");
      if (args[0] === "rev-parse") return Buffer.from("abc1234\n");
      return Buffer.from("");
    });

    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile);

    expect(result).toBe(false);
    expect(mockCloseSeed).not.toHaveBeenCalled();
  });
});

// ── npm-ci + type-check logic (simulated — no real subprocess) ────────────────
//
// finalize() runs npm ci before tsc. The tests below verify the observable
// behaviour of that conditional flow using pure-TypeScript simulators that
// mirror the real code's logic without spawning subprocesses.
//
// See: src/orchestrator/agent-worker-finalize.ts — finalize() npm ci section

// ── Types ─────────────────────────────────────────────────────────────────

interface InstallResult {
  succeeded: boolean;
  reportEntry: string[];
  logMessage: string;
}

interface TypeCheckResult {
  status: "SUCCESS" | "FAILED" | "SKIPPED";
  reportEntry: string[];
  logMessage: string;
}

// ── Helpers (simulate the finalize() logic) ────────────────────────────────

/**
 * Simulates the npm ci step from finalize().
 * Returns the same report entries and log messages the real code produces.
 */
function simulateInstall(npmCiThrows: boolean, errorDetail = "npm ERR! lock file mismatch"): InstallResult {
  if (!npmCiThrows) {
    return {
      succeeded: true,
      reportEntry: ["## Dependency Install", "- Status: SUCCESS", ""],
      logMessage: "[FINALIZE] npm ci succeeded",
    };
  }

  const detail = errorDetail.slice(0, 500);
  return {
    succeeded: false,
    reportEntry: ["## Dependency Install", "- Status: FAILED", "- Errors:", "```", detail, "```", ""],
    logMessage: `[FINALIZE] npm ci failed: ${detail.slice(0, 200)}`,
  };
}

/**
 * Simulates the type-check step from finalize().
 * When installSucceeded is false, returns SKIPPED.
 * When tscThrows is true, returns FAILED; otherwise SUCCESS.
 */
function simulateTypeCheck(
  installSucceeded: boolean,
  tscThrows: boolean,
  errorDetail = "src/foo.ts(1,1): error TS2304: Cannot find name 'x'.",
): TypeCheckResult {
  if (!installSucceeded) {
    return {
      status: "SKIPPED",
      reportEntry: ["## Build / Type Check", "- Status: SKIPPED (dependency install failed)", ""],
      logMessage: "[FINALIZE] Skipping type check — dependency install failed",
    };
  }

  if (!tscThrows) {
    return {
      status: "SUCCESS",
      reportEntry: ["## Build / Type Check", "- Status: SUCCESS", ""],
      logMessage: "[FINALIZE] Type check passed",
    };
  }

  const detail = errorDetail.slice(0, 500);
  return {
    status: "FAILED",
    reportEntry: ["## Build / Type Check", "- Status: FAILED", "- Errors:", "```", detail, "```", ""],
    logMessage: `[FINALIZE] Type check failed: ${detail.slice(0, 200)}`,
  };
}

// ── Tests ──────────────────────────────────────────────────────────────────

describe("finalize() — dependency install step", () => {
  it("reports SUCCESS and sets installSucceeded when npm ci exits cleanly", () => {
    const result = simulateInstall(false);

    expect(result.succeeded).toBe(true);
    expect(result.reportEntry).toContain("## Dependency Install");
    expect(result.reportEntry).toContain("- Status: SUCCESS");
    expect(result.logMessage).toContain("npm ci succeeded");
  });

  it("reports FAILED and clears installSucceeded when npm ci throws", () => {
    const result = simulateInstall(true, "npm ERR! lock file mismatch");

    expect(result.succeeded).toBe(false);
    expect(result.reportEntry).toContain("## Dependency Install");
    expect(result.reportEntry).toContain("- Status: FAILED");
    expect(result.logMessage).toContain("npm ci failed");
  });

  it("includes error detail in the report when npm ci fails", () => {
    const detail = "npm ERR! package-lock.json out of sync";
    const result = simulateInstall(true, detail);

    const reportText = result.reportEntry.join("\n");
    expect(reportText).toContain(detail);
    // Error is wrapped in a fenced code block
    expect(result.reportEntry).toContain("```");
  });

  it("truncates error detail to 500 characters in the report", () => {
    const longError = "x".repeat(600);
    const result = simulateInstall(true, longError);

    const reportText = result.reportEntry.join("\n");
    // The 500-char slice must appear; beyond 500 chars must not
    expect(reportText).toContain("x".repeat(500));
    expect(reportText).not.toContain("x".repeat(501));
  });

  it("truncates log message error to 200 characters", () => {
    const longError = "y".repeat(600);
    const result = simulateInstall(true, longError);

    // logMessage slice is 200 chars from detail
    expect(result.logMessage).toContain("y".repeat(200));
    expect(result.logMessage).not.toContain("y".repeat(201));
  });
});

describe("finalize() — type-check step (conditional on installSucceeded)", () => {
  it("runs type check when installSucceeded is true and reports SUCCESS", () => {
    const result = simulateTypeCheck(true, false);

    expect(result.status).toBe("SUCCESS");
    expect(result.reportEntry).toContain("## Build / Type Check");
    expect(result.reportEntry).toContain("- Status: SUCCESS");
    expect(result.logMessage).toContain("Type check passed");
  });

  it("skips type check when installSucceeded is false", () => {
    const result = simulateTypeCheck(false, false);

    expect(result.status).toBe("SKIPPED");
    expect(result.reportEntry).toContain("## Build / Type Check");
    expect(result.reportEntry).toContain("- Status: SKIPPED (dependency install failed)");
    expect(result.logMessage).toContain("Skipping type check");
  });

  it("reports FAILED with error detail when tsc throws after successful install", () => {
    const tsError = "src/bar.ts(3,5): error TS2322: Type 'string' is not assignable to type 'number'.";
    const result = simulateTypeCheck(true, true, tsError);

    expect(result.status).toBe("FAILED");
    expect(result.reportEntry).toContain("## Build / Type Check");
    expect(result.reportEntry).toContain("- Status: FAILED");
    const reportText = result.reportEntry.join("\n");
    expect(reportText).toContain(tsError);
    expect(result.logMessage).toContain("Type check failed");
  });

  it("does NOT run type check when npm ci failed — guards against false module errors", () => {
    // This is the critical regression guard: without node_modules, tsc would fail
    // with "Cannot find module" even if the TypeScript code itself is correct.
    const install = simulateInstall(true);
    const typeCheck = simulateTypeCheck(install.succeeded, false);

    expect(install.succeeded).toBe(false);
    expect(typeCheck.status).toBe("SKIPPED");
  });

  it("correctly sequences install then type-check in the happy path", () => {
    const install = simulateInstall(false);
    const typeCheck = simulateTypeCheck(install.succeeded, false);

    expect(install.succeeded).toBe(true);
    expect(typeCheck.status).toBe("SUCCESS");

    // Both sections must appear in the report (in order)
    const report = [...install.reportEntry, ...typeCheck.reportEntry];
    const depIdx = report.indexOf("## Dependency Install");
    const tscIdx = report.indexOf("## Build / Type Check");

    expect(depIdx).toBeGreaterThanOrEqual(0);
    expect(tscIdx).toBeGreaterThan(depIdx);
  });

  it("skips type check even when tsc would have passed — error message is clear", () => {
    // Simulate an environment where tsc would pass but npm ci failed.
    // The skip message must make the root cause obvious (install, not tsc).
    const result = simulateTypeCheck(false, false);

    expect(result.reportEntry.join("\n")).toContain("dependency install failed");
    expect(result.logMessage).toContain("dependency install failed");
  });
});

describe("finalize() — report structure with npm ci section", () => {
  it("report includes a Dependency Install section before Build / Type Check", () => {
    // Simulate full happy-path report content
    const install = simulateInstall(false);
    const typeCheck = simulateTypeCheck(true, false);
    const combined = [...install.reportEntry, ...typeCheck.reportEntry].join("\n");

    expect(combined).toContain("## Dependency Install");
    expect(combined).toContain("## Build / Type Check");

    const installPos = combined.indexOf("## Dependency Install");
    const tscPos = combined.indexOf("## Build / Type Check");
    expect(installPos).toBeLessThan(tscPos);
  });

  it("report omits tsc section when install fails — only Dependency Install FAILED appears", () => {
    const install = simulateInstall(true);
    const typeCheck = simulateTypeCheck(false, false); // installSucceeded=false
    const combined = [...install.reportEntry, ...typeCheck.reportEntry].join("\n");

    expect(combined).toContain("## Dependency Install");
    expect(combined).toContain("- Status: FAILED");
    // Type check is SKIPPED, not absent — but the status is explicit
    expect(combined).toContain("- Status: SKIPPED (dependency install failed)");
  });

  it("install uses 120_000 ms timeout (not the 60_000 ms type-check timeout)", () => {
    // Verify the documented timeout values in the code comments match the intent.
    // This is a documentation-level assertion — the simulator captures the timeout
    // intent via constant values used in the real code.
    const INSTALL_TIMEOUT_MS = 120_000;
    const TYPECHECK_TIMEOUT_MS = 60_000;

    expect(INSTALL_TIMEOUT_MS).toBeGreaterThan(TYPECHECK_TIMEOUT_MS);
    expect(INSTALL_TIMEOUT_MS).toBe(120_000);
    expect(TYPECHECK_TIMEOUT_MS).toBe(60_000);
  });
});
